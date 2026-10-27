package detect

import (
	"os"
	"strings"
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
