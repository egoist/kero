package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runSkill(t *testing.T, args ...string) string {
	t.Helper()
	out, err := os.CreateTemp(t.TempDir(), "skill-output")
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	stdout := os.Stdout
	os.Stdout = out
	defer func() { os.Stdout = stdout }()
	if err := skillCmd(args); err != nil {
		t.Fatal(err)
	}
	return read(t, out.Name())
}

func TestVibeSkill(t *testing.T) {
	home := t.TempDir()
	for env, dir := range map[string]string{
		"HOME": home, "USERPROFILE": home,
		"KERO_HOME":           filepath.Join(home, ".kero"),
		"CLAUDE_CONFIG_DIR":   filepath.Join(home, ".claude"),
		"CODEX_HOME":          filepath.Join(home, ".codex"),
		"PI_CODING_AGENT_DIR": filepath.Join(home, ".pi", "agent"),
		"XDG_CONFIG_HOME":     filepath.Join(home, ".config"),
		"VIBE_HOME":           filepath.Join(home, ".vibe"),
	} {
		t.Setenv(env, dir)
	}
	files := map[string]string{
		".claude/skills/kero/SKILL.md":  "Existing Claude skill\n",
		".claude/settings.json":         "{\"model\": \"sonnet\"}\n",
		".agents/skills/other/SKILL.md": "Another skill\n",
		".vibe/config.toml":             "# User settings\nexperimental_enable_tab_status = true\n",
		".vibe/hooks.toml":              "# User hooks\n[[hooks]]\nname = 'audit'\ntype = 'post_agent'\ncommand = 'echo'\n",
	}
	for rel, content := range files {
		path := filepath.Join(home, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	shared := filepath.Join(home, ".agents", "skills", "kero", "SKILL.md")
	checkOutput := func(out, want string) {
		t.Helper()
		if !strings.Contains(out, want) || strings.Contains(out, "claude") || strings.Contains(out, "hook") {
			t.Fatalf("output %q, want only the shared skill (%s)", out, want)
		}
	}
	checkOutput(runSkill(t, "status", "--agent", "vibe"), "missing")
	checkOutput(runSkill(t, "setup", "--agent", "vibe", "--dry-run"), "would setup")
	if _, err := os.Stat(shared); !os.IsNotExist(err) {
		t.Fatalf("dry-run wrote the skill: %v", err)
	}
	for range 2 {
		checkOutput(runSkill(t, "setup", "--agent", "vibe"), "installed")
		if got := read(t, shared); got != skillGuide {
			t.Fatalf("installed skill: %q", got)
		}
	}
	checkOutput(runSkill(t, "status", "--agent", "VIBE"), "current")
	checkOutput(runSkill(t, "remove", "--agent", "vibe", "--dry-run"), "would remove")
	if got := read(t, shared); got != skillGuide {
		t.Fatal("dry-run changed the skill")
	}
	for range 2 {
		checkOutput(runSkill(t, "remove", "--agent", "vibe"), "removed")
	}
	if _, err := os.Stat(shared); !os.IsNotExist(err) {
		t.Fatalf("skill remains after removal: %v", err)
	}
	checkOutput(runSkill(t, "status", "--agent", "vibe"), "missing")

	for rel, content := range files {
		if got := read(t, filepath.Join(home, filepath.FromSlash(rel))); got != content {
			t.Errorf("changed %s: %q", rel, got)
		}
	}
	if err := filepath.WalkDir(home, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() {
			rel, err := filepath.Rel(home, path)
			if err != nil {
				return err
			}
			if _, ok := files[filepath.ToSlash(rel)]; !ok {
				t.Errorf("unexpected file: %s", rel)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}
