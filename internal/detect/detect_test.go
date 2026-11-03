package detect

import (
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
)

func TestManifestsCompile(t *testing.T) {
	if err := Load(); err != nil {
		t.Fatal(err)
	}
	for _, a := range []string{"claude", "codex", "gemini", "opencode", "amp", "cursor-agent", "droid", "qwen", "copilot", "kiro-cli", "cline", "kimi", "pi"} {
		if !Known(a) {
			t.Errorf("no rules for %s", a)
		}
	}
	if Known("bash") {
		t.Error("rules for bash")
	}
}

func screen(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Claude Code's screens, as kero read printed them.
func TestClaude(t *testing.T) {
	cases := []struct {
		name  string
		in    Input
		state State
	}{
		{"at its prompt", Input{Screen: screen(t, "claude-idle.txt"), Title: "✳ Claude Code"}, Idle},
		{"thinking", Input{Screen: screen(t, "claude-working.txt"), Title: "⠂ Probe"}, Working},
		{"thinking, the title not yet turning", Input{Screen: screen(t, "claude-working.txt")}, Working},
		{"asking to run a command", Input{Screen: screen(t, "claude-blocked.txt"), Title: "✳ Probe"}, Blocked},
		// The prompt shows, but the title turns: a turn that started.
		{"title turning", Input{Screen: screen(t, "claude-idle.txt"), Title: "⠐ Probe"}, Working},
		// A redraw at another width shows the same: still idle.
		{"rewrapped", Input{Screen: strings.ReplaceAll(screen(t, "claude-idle.txt"), "────", "──"), Title: "✳ Claude Code"}, Idle},
	}
	for _, c := range cases {
		if got := Detect("claude", c.in); got.State != c.state {
			t.Errorf("%s: %s (rule %q), want %s", c.name, got.State, got.Rule, c.state)
		}
	}
}

func TestRegions(t *testing.T) {
	s := "a\n\nb\n───\nbox\n───\nfoot\n"
	for spec, want := range map[string]string{
		"bottom_non_empty_lines(2)":  "───\nfoot\n",
		"bottom_lines(1)":            "foot\n",
		"top_non_empty_lines(2)":     "a\n\nb\n",
		"after_last_horizontal_rule": "foot\n",
		"prompt_box_body":            "box\n",
		"above_prompt_box":           "a\n\nb\n",
		"osc_title":                  "T",
		"osc_progress":               "4;3",
	} {
		if got := region(Input{Screen: s, Title: "T", Progress: "4;3"}, spec); got != want {
			t.Errorf("%s: %q, want %q", spec, got, want)
		}
	}
}

// Kiro's progress turns while it works.
func TestProgress(t *testing.T) {
	if got := Detect("kiro-cli", Input{Progress: "4;3"}); got.State != Working {
		t.Errorf("progress 4;3: %s (rule %q), want working", got.State, got.Rule)
	}
	if got := Detect("kiro-cli", Input{Progress: "4;0"}); got.State != Idle {
		t.Errorf("progress 4;0: %s (rule %q), want idle", got.State, got.Rule)
	}
}

// kero's manifests hold to what the user's must.
func TestManifestsStrict(t *testing.T) {
	entries, _ := manifestFS.ReadDir("manifests")
	for _, e := range entries {
		data, _ := manifestFS.ReadFile("manifests/" + e.Name())
		if _, err := parse(data, true); err != nil {
			t.Errorf("%s: %v", e.Name(), err)
		}
	}
}

func TestUserManifests(t *testing.T) {
	dir := t.TempDir()
	write := func(name, s string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// A new agent, its program of its name and another.
	write("frog.toml", `
id = "frog"
executables = ["frog", "frog-cli"]

[[rules]]
id = "working"
state = "working"
priority = 100
region = "bottom_non_empty_lines(3)"
visible_working = true
contains = ["hopping…"]

[[rules]]
id = "asking"
state = "blocked"
priority = 200
visible_blocker = true
line_regex = ['^Allow .+\? \[y/n\]$']
`)
	// kero's Copilot, by its daemon's name, replaced.
	write("my-copilot.toml", `
id = "copilot"
executables = ["ghc"]

[[rules]]
id = "busy"
state = "working"
contains = ["thinking hard"]
`)
	write("bad-state.toml", "[[rules]]\nid = \"x\"\nstate = \"sleeping\"\n")
	write("bad-region.toml", "[[rules]]\nid = \"x\"\nstate = \"idle\"\nregion = \"middle\"\n")
	write("bad-key.toml", "[[rules]]\nid = \"x\"\nstate = \"idle\"\ncontain = [\"a\"]\n")
	write("bad-regex.toml", "[[rules]]\nid = \"x\"\nstate = \"idle\"\nregex = [\"(\"]\n")
	write("no-rules.toml", "id = \"empty\"\n")
	write("twice.toml", "id = \"frog\"\n[[rules]]\nid = \"x\"\nstate = \"idle\"\n")
	write("newer.toml", "min_engine_version = 9\n[[rules]]\nid = \"x\"\nstate = \"idle\"\n")

	agents, problems := Check(dir)
	if !slices.Equal(agents, []string{"copilot", "frog"}) {
		t.Errorf("agents %v", agents)
	}
	if len(problems) != 7 {
		t.Errorf("%d problems, want 7:\n%s", len(problems), strings.Join(problems, "\n"))
	}
	for _, p := range problems {
		if !strings.HasPrefix(p, dir) {
			t.Errorf("problem names no file: %s", p)
		}
	}

	ms, exes, _ := readUser(dir)
	if exes["frog-cli"] != "frog" || exes["ghc"] != "copilot" {
		t.Errorf("executables %v", exes)
	}
	if ms["github-copilot"] == nil {
		t.Error("copilot's manifest not replaced")
	}
	// What the engine reads of them.
	loaded = map[string]*manifest{}
	maps.Copy(loaded, ms)
	defer func() { loadOnce = sync.Once{}; loaded = nil }()
	loadOnce.Do(func() {})
	for _, c := range []struct {
		agent, screen string
		want          State
	}{
		{"frog", "> fix it\nhopping…\n", Working},
		{"frog", "Allow rm -rf build? [y/n]\n", Blocked},
		{"frog", "> \n", Idle},
		{"copilot", "thinking hard\n", Working},
	} {
		if got := Detect(c.agent, Input{Screen: c.screen}); got.State != c.want {
			t.Errorf("%s %q: %s, want %s", c.agent, c.screen, got.State, c.want)
		}
	}
}
