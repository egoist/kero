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

func TestUserAgents(t *testing.T) {
	file := filepath.Join(t.TempDir(), "agents.toml")
	if err := os.WriteFile(file, []byte(`
# A new agent, its program of its name and another.
[[agents]]
id = "frog"
executables = ["frog", "frog-cli"]

[[agents.rules]]
id = "working"
state = "working"
priority = 100
region = "bottom_non_empty_lines(3)"
visible_working = true
any = [{ contains = ["hopping…"] }, { line_regex = ['^[⠋⠙] Hopping$'] }]

[[agents.rules]]
id = "asking"
state = "blocked"
priority = 200
visible_blocker = true
line_regex = ['^Allow .+\? \[y/n\]$']

# kero's Copilot, by its daemon's name, replaced.
[[agents]]
id = "copilot"
executables = ["ghc"]
rules = [{ id = "busy", state = "working", contains = ["thinking hard"] }]

[[agents]]
id = "bad-state"
rules = [{ id = "x", state = "sleeping" }]

[[agents]]
id = "bad-region"
rules = [{ id = "x", state = "idle", region = "middle" }]

[[agents]]
id = "bad-key"
rules = [{ id = "x", state = "idle", contain = ["a"] }]

[[agents]]
id = "bad-regex"
rules = [{ id = "x", state = "idle", regex = ["("] }]

[[agents]]
id = "empty"

[[agents]]
id = "frog"
rules = [{ id = "x", state = "idle" }]

[[agents]]
rules = [{ id = "x", state = "idle" }]

[[agents]]
id = "newer"
min_engine_version = 9
rules = [{ id = "x", state = "idle" }]
`), 0o600); err != nil {
		t.Fatal(err)
	}

	agents, problems := Check(file)
	if !slices.Equal(agents, []string{"copilot", "frog"}) {
		t.Errorf("agents %v", agents)
	}
	if len(problems) != 8 {
		t.Errorf("%d problems, want 8:\n%s", len(problems), strings.Join(problems, "\n"))
	}
	for _, p := range problems {
		if !strings.HasPrefix(p, file+": ") {
			t.Errorf("problem names no file: %s", p)
		}
	}
	if !slices.ContainsFunc(problems, func(p string) bool { return strings.Contains(p, "bad-key: unknown key") }) {
		t.Errorf("no problem names bad-key's unknown key:\n%s", strings.Join(problems, "\n"))
	}

	ms, exes, _ := readUser(file)
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
		{"frog", "> fix it\n⠙ Hopping\n", Working},
		{"frog", "Allow rm -rf build? [y/n]\n", Blocked},
		{"frog", "> \n", Idle},
		{"copilot", "thinking hard\n", Working},
	} {
		if got := Detect(c.agent, Input{Screen: c.screen}); got.State != c.want {
			t.Errorf("%s %q: %s, want %s", c.agent, c.screen, got.State, c.want)
		}
	}

	// No file, no agents and nothing wrong; a file that isn't TOML, one
	// problem.
	if a, p := Check(filepath.Join(t.TempDir(), "agents.toml")); a != nil || p != nil {
		t.Errorf("no file: %v %v", a, p)
	}
	bad := filepath.Join(t.TempDir(), "agents.toml")
	os.WriteFile(bad, []byte("[[agents]\n"), 0o600)
	if _, p := Check(bad); len(p) != 1 {
		t.Errorf("not TOML: %v", p)
	}
}
