package cli

import (
	"os"
	"path/filepath"
	"testing"
)

// A file that is there and cannot be read is not a missing one: the hook
// may be in it, and `kero skill status` said the agent had none. A
// directory named as the file is there and cannot be read on every
// platform, root or not.
func TestStatesSayAFileTheyCannotRead(t *testing.T) {
	home := t.TempDir()
	settings := filepath.Join(home, "settings.json")
	if err := os.MkdirAll(settings, 0o755); err != nil {
		t.Fatal(err)
	}
	h := agentHook{agent: "claude", file: settings}
	if st := h.state(); st != "unreadable" {
		t.Errorf("a settings file that cannot be read: state %s, want unreadable", st)
	}
	h.file = filepath.Join(home, "gone.json")
	if st := h.state(); st != "missing" {
		t.Errorf("a settings file that is not there: state %s, want missing", st)
	}

	dir := t.TempDir()
	if st := skillState(dir); st != "missing" {
		t.Errorf("no skill file: state %s, want missing", st)
	}
	if err := os.MkdirAll(filepath.Join(dir, "SKILL.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	if st := skillState(dir); st != "unreadable" {
		t.Errorf("a skill file that cannot be read: state %s, want unreadable", st)
	}
}

// A row of the Settings window says an agent's skill cannot be read, not
// that it is of an older Kero.
func TestSkillStatesSayAFileTheyCannotRead(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("KERO_HOME", filepath.Join(home, "kero"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, ".claude"))
	dir := filepath.Join(home, ".claude", "skills", "kero")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "SKILL.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, ".claude", "settings.json"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, st := range SkillStates() {
		if st.Agent != "claude" {
			continue
		}
		if st.State != "unreadable" {
			t.Errorf("the claude row says %s, want unreadable", st.State)
		}
		return
	}
	t.Fatal("no row for Claude Code")
}
