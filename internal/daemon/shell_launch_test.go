package daemon

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
	"kero/internal/settings"
	"kero/internal/shell"
)

func TestPaneShell(t *testing.T) {
	set := settings.Default()
	set.Shell, set.ShellArgs = shell.Login(), `-c "echo hi"`
	program, args, err := paneShell("", nil, set)
	if err != nil || program == "" || !reflect.DeepEqual(args, []string{"-c", "echo hi"}) {
		t.Fatalf("default shell = %q, %q, %v", program, args, err)
	}
	program, args, err = paneShell(shell.Login(), nil, set)
	if err != nil || program == "" || len(args) != 0 {
		t.Fatalf("one-off shell inherited unrelated arguments: %q, %q, %v", program, args, err)
	}
	if _, _, err := paneShell(filepath.Join(t.TempDir(), "missing-shell"), nil, set); err == nil {
		t.Fatal("missing shell silently fell back to another shell")
	}
	for _, name := range []string{"bash", "pwsh", "cmd"} {
		if got := shellLaunchArgs(name, "", nil, []string{"-c", "echo hi"}); !reflect.DeepEqual(got, []string{name, "-c", "echo hi"}) {
			t.Errorf("explicit args changed for %s: %q", name, got)
		}
	}
	args = shellLaunchArgs("pwsh", "", nil, []string{"-NoProfile"})
	if args[1] != "-NoProfile" || !strings.Contains(strings.Join(args, " "), powershellPrompt) {
		t.Fatalf("PowerShell integration lost with custom flags: %q", args)
	}
}

func TestShellLaunchCommandOverridesConfiguredCommand(t *testing.T) {
	command := []string{"claude", "--resume", "saved-session"}
	for _, tt := range []struct {
		name, program string
		extra, flags  []string
	}{
		{"bash", "bash", []string{"--noprofile", "--norc", "-c", "echo configured"}, []string{"--noprofile", "--norc"}},
		{"bash combined flags", "bash", []string{"-lic", "echo configured"}, []string{"-li"}},
		{"fish", "fish", []string{"--private", "--command", "echo configured"}, []string{"--private"}},
		{"PowerShell file", "pwsh", []string{"-NoProfile", "-FiLe", "init.ps1", "script-arg"}, []string{"-NoProfile"}},
		{"PowerShell encoded command", "powershell", []string{"-NoProfile", "-EC", "encoded"}, []string{"-NoProfile"}},
		{"cmd", "cmd", []string{"/D", "/k", "echo configured"}, []string{"/D"}},
		{"ordinary flags", "bash", []string{"--noprofile"}, []string{"--noprofile"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			before := append([]string(nil), tt.extra...)
			want := append([]string{tt.program}, tt.flags...)
			want = append(want, shellArgs(tt.program, "", command)[1:]...)
			if got := shellLaunchArgs(tt.program, "", command, tt.extra); !reflect.DeepEqual(got, want) {
				t.Fatalf("launch arguments = %q; want %q", got, want)
			}
			if !reflect.DeepEqual(tt.extra, before) {
				t.Fatal("launch changed the saved arguments")
			}
			if got := shellLaunchArgs(tt.program, "", nil, tt.extra); len(tt.extra) > 1 && !reflect.DeepEqual(got[1:], tt.extra) {
				t.Fatalf("plain shell changed configured arguments: %q", got)
			}
		})
	}
}

func TestShellLaunchRunsRequestedCommand(t *testing.T) {
	for _, name := range []string{"bash", "pwsh", "powershell"} {
		t.Run(name, func(t *testing.T) {
			program, err := exec.LookPath(name)
			if err != nil {
				t.Skip(name, "not installed")
			}
			extra := []string{"--noprofile", "--norc", "-c", "echo CONFIGURED"}
			command := "echo REQUESTED; exit"
			if name != "bash" {
				extra = []string{"-NoProfile", "-Command", "Write-Output CONFIGURED"}
				command = "Write-Output REQUESTED; exit"
			}
			args := shellLaunchArgs(program, "", []string{command}, extra)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			out, err := exec.CommandContext(ctx, program, args[1:]...).Output()
			if err != nil || strings.TrimSpace(string(out)) != "REQUESTED" {
				t.Fatalf("requested command did not run alone: output %q, error %v", out, err)
			}
		})
	}
}

func TestShellStartupDirectory(t *testing.T) {
	d := testDaemon(t)
	d.projects = nil
	dir := t.TempDir()
	set := settings.Default()
	set.ShellDir = dir
	if err := settings.Save(set); err != nil {
		t.Fatal(err)
	}
	s, err := d.create(proto.CreateParams{URL: "localhost:3000"})
	if err != nil || s.Dir != dir {
		t.Fatalf("fallback directory = %q, %v; want %q", s.Dir, err, dir)
	}
	explicit := t.TempDir()
	s, err = d.create(proto.CreateParams{Dir: explicit, URL: "localhost:3000"})
	if err != nil || s.Dir != explicit {
		t.Fatalf("explicit directory overwritten: %q, %v", s.Dir, err)
	}
	s, err = d.create(proto.CreateParams{Project: s.Project, URL: "localhost:3000"})
	if err != nil || s.Dir != explicit {
		t.Fatalf("project directory overwritten: %q, %v", s.Dir, err)
	}
	s, err = d.create(proto.CreateParams{Split: s.ID, URL: "localhost:3000"})
	if err != nil || s.FocusPane().Dir != explicit {
		t.Fatalf("split did not inherit: %+v, %v", s, err)
	}
	set.ShellDir = filepath.Join(t.TempDir(), "missing")
	if err := settings.Save(set); err != nil {
		t.Fatal(err)
	}
	d.projects = nil
	if _, err := d.create(proto.CreateParams{URL: "localhost:3000"}); err == nil {
		t.Fatal("invalid startup directory silently ignored")
	}
}

func TestOneOffShellSurvivesRestore(t *testing.T) {
	d := testDaemon(t)
	program, err := exec.LookPath("cmd")
	args := []string{"/Q"}
	if err != nil {
		program, err = exec.LookPath("bash")
		args = []string{"--noprofile", "--norc"}
	}
	if err != nil {
		t.Skip("no test shell installed")
	}
	s, err := d.create(proto.CreateParams{Shell: program, ShellArgs: args})
	if err != nil {
		t.Fatal(err)
	}
	defer d.findPane(s.Panes[0].ID).close()
	d.saveState()
	data, err := os.ReadFile(d.statePath())
	if err != nil {
		t.Fatal(err)
	}
	var saved savedState
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	sp := saved.Sessions[0].Panes[0]
	if sp.Shell != program || !reflect.DeepEqual(sp.ShellArgs, args) {
		t.Fatalf("shell choice not saved: %+v", sp)
	}
	// An invalid new default cannot replace the pane's explicit choice.
	set := settings.Default()
	set.Shell = "missing-default-shell"
	if err := settings.Save(set); err != nil {
		t.Fatal(err)
	}
	restored := d.restorePane("restored", sp, "now", false)
	if restored == nil {
		t.Fatal("explicit shell was not restored")
	}
	defer restored.close()
	if !strings.EqualFold(restored.info.Shell, shellName(program)) || restored.program != program || !reflect.DeepEqual(restored.args, args) {
		t.Fatalf("restored wrong shell: %q, %q, %q", restored.info.Shell, restored.program, restored.args)
	}
}

func TestFailedShellPaneSurvivesPartialRestore(t *testing.T) {
	d := testDaemon(t)
	sp := savedPane{
		ID: "terminal", Dir: d.projects[0].Dir,
		Shell: filepath.Join(t.TempDir(), "missing-shell"), ShellArgs: []string{"-l"},
		Command: []string{"claude"}, Agent: &proto.AgentSession{Agent: "claude", ID: "saved-session"},
	}
	layout := (&proto.Layout{Pane: "browser"}).Split("browser", sp.ID, "down", 0.4)
	original := savedState{Version: 2, Projects: d.projects, Sessions: []savedSession{{
		ID: "mixed", Project: "pr", Focus: sp.ID, Layout: layout,
		Panes: []savedPane{{ID: "browser", Dir: sp.Dir, URL: "http://localhost:3000"}, sp},
	}}}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(d.statePath(), data, 0o600); err != nil {
		t.Fatal(err)
	}
	d.restore()
	for _, p := range d.panes {
		defer p.close()
	}
	p := d.panes[sp.ID]
	if p == nil || p.term == nil || p.proc != nil || p.info.Status != proto.Exited || p.info.ExitCode == 0 {
		t.Fatalf("failed shell was not kept as an exited pane: %+v", p)
	}
	if !strings.Contains(p.readText(true, 0), "Could not start shell") {
		t.Fatal("failed pane does not show its startup error")
	}
	if err := p.restart(); err == nil || p.info.Status != proto.Exited {
		t.Fatalf("failed retry left pane in status %q: %v", p.info.Status, err)
	}
	d.saveState()
	data, err = os.ReadFile(d.statePath())
	if err != nil {
		t.Fatal(err)
	}
	var saved savedState
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	if len(saved.Sessions) != 1 || len(saved.Sessions[0].Panes) != 2 {
		t.Fatalf("partial restore lost a pane: %+v", saved.Sessions)
	}
	ss := saved.Sessions[0]
	got := ss.Panes[1]
	if ss.Focus != sp.ID || !reflect.DeepEqual(ss.Layout, layout) || got.ID != sp.ID || got.Dir != sp.Dir ||
		got.Shell != sp.Shell || !reflect.DeepEqual(got.ShellArgs, sp.ShellArgs) ||
		!reflect.DeepEqual(got.Command, sp.Command) || !reflect.DeepEqual(got.Agent, sp.Agent) {
		t.Fatalf("failed pane's state changed: %+v", ss)
	}
}
