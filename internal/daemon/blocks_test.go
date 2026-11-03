package daemon

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

const (
	markA = "\x1b]133;A\x07"
	markB = "\x1b]133;B\x07"
	markC = "\x1b]133;C\x07"
)

func markD(code int) string { return fmt.Sprintf("\x1b]133;D;%d\x07", code) }

// run has the pane show what a shell does for a command.
func run(s *pane, command, output string, code int) {
	s.output([]byte(markA + "❯ " + markB + command + "\r\n" + markC + output + markD(code)))
}

func blockLines(s *pane) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for _, b := range s.blocks.list {
		out = append(out, b.Line)
	}
	return out
}

func TestParseMark(t *testing.T) {
	zero, three := 0, 3
	cases := []struct {
		body string
		kind byte
		exit *int
		ok   bool
	}{
		{"A", 'A', nil, true},
		{"A;click_events=1", 'A', nil, true},
		{"B", 'B', nil, true},
		{"C", 'C', nil, true},
		{"C;cmdline_url=ls%20-la", 'C', nil, true},
		{"D", 'D', nil, true},
		{"D;0", 'D', &zero, true},
		{"D;3", 'D', &three, true},
		{"D;3;aid=1", 'D', &three, true},
		// A status that makes no sense is none; the mark stands.
		{"D;abc", 'D', nil, true},
		{"D;-1", 'D', nil, true},
		{"D;99999999999999999999", 'D', nil, true},
		{"D;", 'D', nil, true},
		// Not marks.
		{"", 0, nil, false},
		{"Z", 0, nil, false},
		{"AB", 0, nil, false},
		{"a", 0, nil, false},
		{"Done", 0, nil, false},
		{"\x00", 0, nil, false},
	}
	for _, c := range cases {
		kind, exit, ok := parseMark(c.body)
		if ok != c.ok || kind != c.kind || (exit == nil) != (c.exit == nil) || exit != nil && *exit != *c.exit {
			t.Errorf("parseMark(%q) = %c, %v, %v", c.body, kind, exit, ok)
		}
	}
}

func TestBlocksTrackCommands(t *testing.T) {
	s := testPane(t)
	run(s, "ls", "a\r\nb\r\n", 0)
	run(s, "false", "", 1)
	got := s.blocksFrom(0).Blocks
	if len(got) != 2 {
		t.Fatalf("got %d blocks: %+v", len(got), got)
	}
	ls, f := got[0], got[1]
	if ls.Line != "❯ ls" || ls.Output != 2 || ls.Failed() || ls.Ms < 0 {
		t.Errorf("ls: %+v", ls)
	}
	if f.Line != "❯ false" || f.Output != 0 || !f.Failed() || *f.Exit != 1 {
		t.Errorf("false: %+v", f)
	}
	c := s.info.Commands
	if c == nil || c.Last != f.Seq || !c.ExitKnown || c.Exit != 1 || c.Quiet {
		t.Errorf("Commands = %+v", c)
	}
	// Asked from the last on, it alone comes.
	if r := s.blocksFrom(f.Seq); len(r.Blocks) != 1 || r.First != ls.Seq {
		t.Errorf("blocksFrom(%d) = %+v", f.Seq, r)
	}
}

// A prompt that spans rows starts its block where it starts.
func TestBlocksPromptAbove(t *testing.T) {
	s := testPane(t)
	s.output([]byte(markA + "~/dev via go\r\n❯ " + markB + "make\r\n" + markC + "ok\r\n" + markD(0)))
	if got := s.blocksFrom(0).Blocks; len(got) != 1 || got[0].Up != 1 || got[0].Line != "❯ make" {
		t.Errorf("got %+v", got)
	}
}

// Marks in pieces, across reads and split inside an escape, count the same.
func TestBlocksAcrossReads(t *testing.T) {
	s := testPane(t)
	stream := []byte(markA + "❯ " + markB + "ls\r\n" + markC + "out\r\n" + markD(0))
	for _, b := range stream {
		s.output([]byte{b})
	}
	if got := s.blocksFrom(0).Blocks; len(got) != 1 || got[0].Line != "❯ ls" || got[0].Output != 1 {
		t.Errorf("got %+v", got)
	}
}

// A pane whose shell marks nothing has no blocks, and no state of them.
func TestBlocksNoMarks(t *testing.T) {
	s := testPane(t)
	s.output([]byte("$ ls\r\na\r\nb\r\n$ false\r\n$ "))
	if got := s.blocksFrom(0); len(got.Blocks) != 0 {
		t.Errorf("got %+v", got)
	}
	if s.info.Commands != nil {
		t.Errorf("Commands = %+v", s.info.Commands)
	}
}

// Marks out of order, as a program may send, or a shell that lost track.
func TestBlocksStrayMarks(t *testing.T) {
	s := testPane(t)
	// C with no prompt before it, D with no command before it.
	s.output([]byte("out\r\n" + markC + "more\r\n" + markD(1) + markD(2) + markC))
	if got := s.blocksFrom(0).Blocks; len(got) != 0 {
		t.Fatalf("stray marks made blocks: %+v", got)
	}
	// Prompts again and again, as a redraw sends: one command.
	s.output([]byte(markA + markA + markA + "❯ " + markB + "ls\r\n" + markC + markC + "x\r\n" + markD(0) + markD(9)))
	got := s.blocksFrom(0).Blocks
	if len(got) != 1 || got[0].Failed() {
		t.Fatalf("got %+v", got)
	}
	// A prompt with no D ends the command, with no status.
	s.output([]byte(markA + "❯ " + "sleep\r\n" + markC + markA + "❯ "))
	got = s.blocksFrom(0).Blocks
	if len(got) != 2 || got[1].Ms < 0 || got[1].Exit != nil {
		t.Fatalf("no D: %+v", got[len(got)-1])
	}
}

// What is no mark is ignored, as is a status that makes no sense.
func TestBlocksMalformed(t *testing.T) {
	s := testPane(t)
	for _, seq := range []string{
		"\x1b]133;\x07", "\x1b]133;Z\x07", "\x1b]133;AAA\x07", "\x1b]133\x07", "\x1b]133;\x1b\\",
		"\x1b]133;" + strings.Repeat("x", 8000) + "\x07", "\x1b]133;C", // unterminated, up to the next
	} {
		s.output([]byte(seq))
	}
	s.output([]byte("\x07"))
	if got := s.blocksFrom(0).Blocks; len(got) != 0 {
		t.Fatalf("malformed marks made blocks: %+v", got)
	}
	s.output([]byte(markA + "❯ ls\r\n" + markC + "\x1b]133;D;nonsense\x07"))
	got := s.blocksFrom(0).Blocks
	if len(got) != 1 || got[0].Exit != nil || got[0].Failed() {
		t.Fatalf("a nonsense status: %+v", got)
	}
}

// Blocks go with the lines they are of: a clear, or a full reset.
func TestBlocksFallAway(t *testing.T) {
	cases := []struct {
		name string
		do   func(s *pane)
	}{
		{"RIS", func(s *pane) { s.output([]byte("\x1bc")) }},
		{"clear", func(s *pane) { s.output([]byte("\x1b[H\x1b[2J\x1b[3J")) }},
		{"⌘K", func(s *pane) { s.clear(proto.ClearScreen) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := testPane(t)
			run(s, "one", "out\r\n", 0)
			run(s, "two", "out\r\n", 0)
			c.do(s)
			run(s, "three", "out\r\n", 0)
			if got := blockLines(s); strings.Join(got, ",") != "❯ three" {
				t.Errorf("after %s: %q", c.name, got)
			}
		})
	}
	// The clear command itself leaves no block of its own, as its line is
	// gone once it ended.
	s := testPane(t)
	run(s, "ls", "a\r\n", 0)
	run(s, "clear", "\x1b[H\x1b[2J\x1b[3J", 0)
	if got := blockLines(s); len(got) != 0 {
		t.Errorf("after clear: %q", got)
	}
}

// Blocks go as the scrollback lets their lines go, and never pass the limit.
func TestBlocksBounded(t *testing.T) {
	s := testPane(t)
	s.term.Resize(80, 10)
	s.info.Cols, s.info.Rows = 80, 10
	for i := range maxBlocks + 20 {
		s.blocks.reading = 0
		run(s, fmt.Sprintf("cmd %d", i), "x\r\n", 0)
	}
	if n := len(s.blocksFrom(0).Blocks); n > maxBlocks {
		t.Errorf("%d blocks, past the limit of %d", n, maxBlocks)
	}
	if got := s.blocksFrom(0).Blocks; got[len(got)-1].Line != fmt.Sprintf("❯ cmd %d", maxBlocks+19) {
		t.Errorf("the last block is %q", got[len(got)-1].Line)
	}
	// A line's length is bounded too.
	s = testPane(t)
	run(s, strings.Repeat("y", 5000), "", 0)
	if got := s.blocksFrom(0).Blocks; len(got) != 1 || len(got[0].Line) > proto.MaxBlockLine {
		t.Fatalf("a long line: %d", len(got[0].Line))
	}
}

// Marks in a flood read the text only as often as it takes little time.
func TestBlocksFlood(t *testing.T) {
	s := testPane(t)
	for i := range 2000 {
		s.output(fmt.Appendf(nil, "%d\r\n", i))
	}
	s.blocks.reading, s.blocks.read = time.Hour, time.Now()
	run(s, "ls", "x\r\n", 0)
	if got := s.blocksFrom(0).Blocks; len(got) != 0 {
		t.Errorf("a mark in a flood read the text: %+v", got)
	}
	// And then the next is a command as any.
	s.blocks.reading = 0
	run(s, "ls", "x\r\n", 0)
	if got := s.blocksFrom(0).Blocks; len(got) != 1 {
		t.Errorf("after the flood: %+v", got)
	}
}

// A full-screen program's screen makes no block, and takes none away.
func TestBlocksFullScreen(t *testing.T) {
	s := testPane(t)
	run(s, "ls", "a\r\n", 0)
	s.output([]byte(markA + "❯ vim\r\n" + markC + "\x1b[?1049h\x1b[Hediting\x1b]133;A\x07\x1b]133;C\x07\x1b]133;D;1\x07"))
	if got := blockLines(s); strings.Join(got, ",") != "❯ ls,❯ vim" {
		t.Errorf("on the alternate screen: %q", got)
	}
	s.output([]byte("\x1b[?1049l" + markD(0)))
	got := s.blocksFrom(0).Blocks
	if len(got) != 2 || got[1].Failed() {
		t.Errorf("after: %+v", got)
	}
}

// Reflow moves rows, not lines: a block's line is found the same at any
// width, and a program's output between marks stays out of its count.
func TestBlocksSurviveResize(t *testing.T) {
	s := testPane(t)
	long := strings.Repeat("z", 150)
	run(s, long, "a\r\nb\r\n", 0)
	s.resize(40, 20, 0, 0)
	run(s, "next", "", 0)
	got := s.blocksFrom(0).Blocks
	if len(got) != 2 || got[0].Line != "❯ "+long {
		t.Fatalf("after a resize: %+v", got)
	}
	found := proto.MatchBlocks(s.term.Text(), []string{got[0].Line, got[1].Line})
	if found[0] < 0 || found[1] < found[0] {
		t.Errorf("after a resize, found at %v", found)
	}
}

// A command the pane knows is an agent's tells of itself.
func TestBlocksQuietForAgents(t *testing.T) {
	s := testPane(t)
	s.output([]byte(markA + "❯ claude\r\n" + markC))
	s.mu.Lock()
	s.noteBlock("claude", "claude")
	s.mu.Unlock()
	s.output([]byte("bye\r\n" + markD(0)))
	if c := s.info.Commands; c == nil || !c.Quiet || c.Name != "claude" {
		t.Errorf("Commands = %+v", c)
	}
	// One that reports with OSC 7501 too.
	s = testPane(t)
	s.output([]byte(markA + "❯ brew\r\n" + markC + "\x1b]7501;state=working:app=brew\x07" + markD(0)))
	if c := s.info.Commands; c == nil || !c.Quiet {
		t.Errorf("Commands = %+v", c)
	}
	// A plain one isn't.
	s = testPane(t)
	run(s, "make", "", 0)
	if c := s.info.Commands; c == nil || c.Quiet {
		t.Errorf("Commands = %+v", c)
	}
}

// oscSeen starts a shell in a pseudo-terminal with Kero's integration, runs
// what the test types, and returns the marks it sent.
func oscSeen(t *testing.T, shell string, env []string, command []string, typed ...string) []string {
	t.Helper()
	dir := t.TempDir()
	if err := writeShellFiles(dir, ""); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	// zsh asks a new user to set it up, without one.
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	base := []string{"HOME=" + home, "TERM=xterm-256color", "PATH=" + os.Getenv("PATH")}
	if runtime.GOOS == "windows" {
		// Programs there don't start without the likes of SystemRoot.
		base = append(os.Environ(), "HOME="+home)
	}
	base = append(base, integrationEnv(shell, "", dir, command)...)
	proc, err := startPTY(ptyOptions{
		Path: shell, Args: shellArgs(shell, "", dir, command),
		Dir: home, Env: append(base, env...), Cols: 80, Rows: 24,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer proc.Kill()
	marks := make(chan string, 64)
	go func() {
		var o oscScanner
		buf := make([]byte, 4096)
		for {
			n, err := proc.Read(buf)
			o.scan(buf[:n], func(b []byte) { marks <- string(b) }, func() {})
			// fish waits for the terminal to tell what it is.
			if strings.Contains(string(buf[:n]), "\x1b[0c") || strings.Contains(string(buf[:n]), "\x1b[c") {
				proc.Write([]byte("\x1b[?62;22c"))
			}
			// PowerShell's line editor asks where the cursor is.
			if strings.Contains(string(buf[:n]), "\x1b[6n") {
				proc.Write([]byte("\x1b[1;1R"))
			}
			if err != nil {
				close(marks)
				return
			}
		}
	}()
	var got []string
	drain := func(d time.Duration, until func() bool) {
		for timeout := time.After(d); ; {
			if until != nil && until() {
				return
			}
			select {
			case m, ok := <-marks:
				if !ok {
					return
				}
				got = append(got, m)
			case <-timeout:
				return
			}
		}
	}
	hasA := func() bool {
		for _, m := range got {
			if strings.HasPrefix(m, "133;A") {
				return true
			}
		}
		return false
	}
	drain(8*time.Second, hasA)
	if !hasA() {
		t.Fatalf("no prompt mark: %q", got)
	}
	for _, line := range typed {
		proc.Write([]byte(line + "\r"))
		drain(700*time.Millisecond, nil)
	}
	return got
}

// marksOf keeps the marks of what oscSeen saw, without a mark's options.
func marksOf(got []string) string {
	var out []string
	for _, m := range got {
		if strings.HasPrefix(m, "133;") {
			m = strings.TrimPrefix(m, "133;")
			if m[0] != 'D' {
				m = m[:1]
			} else if i := strings.Index(m[2:], ";"); i >= 0 {
				m = m[:2+i]
			}
			out = append(out, m)
		}
	}
	return strings.Join(out, " ")
}

// markingShells are the shells Kero has mark their prompts on this system:
// PowerShell alone on Windows.
func markingShells() []string {
	if runtime.GOOS == "windows" {
		return []string{"pwsh", "powershell"}
	}
	return []string{"zsh", "bash", "fish", "pwsh"}
}

// exitCommand is a command line of a program that exits with status n.
func exitCommand(n int) string {
	if runtime.GOOS == "windows" {
		return fmt.Sprintf("cmd /c exit %d", n)
	}
	return fmt.Sprintf("sh -c 'exit %d'", n)
}

// The shells this machine has mark each prompt and command, with its status.
func TestShellIntegration(t *testing.T) {
	want := regexp.MustCompile(`(^|.* )A( B)? C D;0 (D;0 )?A( B)? C D;3 (D;3 )?A( B)?( .*)?$`)
	for _, name := range markingShells() {
		t.Run(name, func(t *testing.T) {
			shell, err := exec.LookPath(name)
			if err != nil {
				t.Skip(name, "not installed")
			}
			got := marksOf(oscSeen(t, shell, nil, nil, "echo hi", exitCommand(3), ""))
			if !want.MatchString(got) {
				t.Errorf("marks: %s", got)
			}
		})
	}
	// macOS's own, older than the rest.
	if _, err := os.Stat("/bin/bash"); err == nil {
		t.Run("system bash", func(t *testing.T) {
			got := marksOf(oscSeen(t, "/bin/bash", nil, nil, "echo hi", "sh -c 'exit 3'", ""))
			if !want.MatchString(got) {
				t.Errorf("marks: %s", got)
			}
		})
	}
}

// A session's command, then the shell it goes on with, marks its prompts too.
func TestShellIntegrationAfterCommand(t *testing.T) {
	for _, name := range markingShells() {
		t.Run(name, func(t *testing.T) {
			shell, err := exec.LookPath(name)
			if err != nil {
				t.Skip(name, "not installed")
			}
			command := []string{"sh", "-c", "exit 4"}
			if runtime.GOOS == "windows" {
				command = []string{"cmd", "/c", "exit 4"}
			}
			got := marksOf(oscSeen(t, shell, nil, command, exitCommand(5)))
			if !strings.Contains(got, "D;4") || !regexp.MustCompile(`A( B)? C D;5`).MatchString(got) {
				t.Errorf("marks: %s", got)
			}
		})
	}
}

// The user's own startup files run, in the order their shell reads them, and
// what they set stands, as without Kero.
func TestShellIntegrationKeepsConfig(t *testing.T) {
	cases := map[string]map[string]string{
		"zsh": {
			".zshenv":   "export FROM_ZSHENV=1\n",
			".zprofile": "export FROM_ZPROFILE=1\n",
			".zshrc":    "export FROM_RC=1\nprecmd_functions+=(my_hook)\nmy_hook() { export HOOK_STATUS=$? }\nPS1='mine> '\n",
		},
		"bash": {
			".bash_profile": "export FROM_PROFILE=1\n. ~/.bashrc\n",
			".bashrc":       "export FROM_RC=1\nmy_hook() { export HOOK_STATUS=$?; }\nPROMPT_COMMAND=my_hook\nPS1='mine> '\n",
		},
	}
	names := []string{"zsh", "bash"}
	if _, err := os.Stat("/bin/bash"); err == nil {
		names = append(names, "/bin/bash")
	}
	for _, name := range names {
		files := cases[shellName(name)]
		t.Run(name, func(t *testing.T) {
			shell, err := exec.LookPath(name)
			if err != nil {
				t.Skip(name, "not installed")
			}
			dir, home := t.TempDir(), t.TempDir()
			if err := writeShellFiles(dir, ""); err != nil {
				t.Fatal(err)
			}
			for f, text := range files {
				if err := os.WriteFile(filepath.Join(home, f), []byte(text), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			env := append([]string{"HOME=" + home, "TERM=xterm-256color", "PATH=" + os.Getenv("PATH")}, integrationEnv(shell, "", dir, nil)...)
			proc, err := startPTY(ptyOptions{Path: shell, Args: shellArgs(shell, "", dir, nil), Dir: home, Env: env, Cols: 80, Rows: 24})
			if err != nil {
				t.Fatal(err)
			}
			defer proc.Kill()
			out := make(chan []byte, 256)
			go func() {
				buf := make([]byte, 4096)
				for {
					n, err := proc.Read(buf)
					if n > 0 {
						out <- append([]byte(nil), buf[:n]...)
					}
					if err != nil {
						close(out)
						return
					}
				}
			}()
			var seen strings.Builder
			wait := func(what string) {
				for timeout := time.After(8 * time.Second); !strings.Contains(seen.String(), what); {
					select {
					case b, ok := <-out:
						if !ok {
							t.Fatalf("the shell ended, waiting for %q: %q", what, seen.String())
						}
						seen.Write(b)
					case <-timeout:
						t.Fatalf("no %q in %q", what, seen.String())
					}
				}
			}
			wait("mine> ")
			proc.Write([]byte("(exit 7)\r"))
			time.Sleep(300 * time.Millisecond)
			proc.Write([]byte(`echo "got:rc=${FROM_RC}:hook=${HOOK_STATUS}:env=[${ENV}]:zdot=[${ZDOTDIR}]:posix=$(set -o | grep -c 'posix.*on'):kero=[${KERO_SHELL_INTEGRATION}${KERO_BASH_INJECT}]:end"` + "\r"))
			want := "got:rc=1:hook=7:env=[]:zdot=[]:posix=0:kero=[]:end"
			wait(want)
		})
	}
}

// shell-integration = false starts every shell as it was.
func TestShellIntegrationOff(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("what it looks at are the shells of Unix")
	}
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	if err := os.WriteFile(os.Getenv("KERO_CONFIG"), []byte("shell-integration = false\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := writeShellFiles(dir, ""); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{dir: dir}
	if got := d.integrationDir(); got != "" {
		t.Errorf("integrationDir = %q", got)
	}
	for _, shell := range []string{"/bin/zsh", "/bin/bash", "/usr/bin/fish"} {
		if got := shellArgs(shell, "", "", nil); len(got) != 1 {
			t.Errorf("%s starts with %q", shell, got)
		}
		if got := integrationEnv(shell, "", "", nil); got != nil {
			t.Errorf("%s has env %q", shell, got)
		}
	}
	if err := os.WriteFile(os.Getenv("KERO_CONFIG"), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := d.integrationDir(); got != dir {
		t.Errorf("on by default: integrationDir = %q", got)
	}
}
