package cli

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSkillLinks(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("links need Developer Mode on Windows: a copy then")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("KERO_HOME", filepath.Join(home, "kero"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, ".claude"))
	adopt := adoptCopies
	adoptCopies = func() bool { return true }
	defer func() { adoptCopies = adopt }()
	claude := skillDirs("claude")["claude"]
	agents := skillDirs("agents")["agents"]

	// An older kero's install: a copy, of another skill.
	os.MkdirAll(claude, 0o755)
	os.WriteFile(filepath.Join(claude, "SKILL.md"), []byte("old"), 0o644)
	SyncSkill()
	if t1, err := os.Readlink(filepath.Join(claude, "SKILL.md")); err != nil || t1 != skillFile() {
		t.Fatalf("the copy is no link to Kero's own: %q %v", t1, err)
	}
	if skillState(claude) != "current" {
		t.Errorf("state %s", skillState(claude))
	}
	// SyncSkill installs nothing that isn't.
	if _, err := os.Stat(agents); err == nil {
		t.Errorf("SyncSkill installed %s", agents)
	}

	// Kero updates: its own copy follows, and the install with it.
	os.WriteFile(skillFile(), []byte("of an older Kero"), 0o644)
	if skillState(claude) != "outdated" {
		t.Errorf("state %s", skillState(claude))
	}
	SyncSkill()
	if b, _ := os.ReadFile(filepath.Join(claude, "SKILL.md")); string(b) != skillGuide {
		t.Errorf("the install reads %q", b)
	}

	if err := InstallSkill("agents"); err != nil {
		t.Fatal(err)
	}
	if t1, _ := os.Readlink(filepath.Join(agents, "SKILL.md")); t1 != skillFile() {
		t.Errorf("installed as %q", t1)
	}
	if err := RemoveSkill("agents"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(skillFile()); err != nil {
		t.Errorf("removing an install took Kero's own copy: %v", err)
	}

	// Another Kero's link, as the installed Kero's to a development
	// build: SyncSkill leaves it, and so does a build that takes no copies.
	other := filepath.Join(home, "other", "SKILL.md")
	os.MkdirAll(filepath.Dir(other), 0o755)
	os.WriteFile(other, []byte("another Kero's"), 0o644)
	os.Remove(filepath.Join(claude, "SKILL.md"))
	os.Symlink(other, filepath.Join(claude, "SKILL.md"))
	os.MkdirAll(agents, 0o755)
	os.WriteFile(filepath.Join(agents, "SKILL.md"), []byte("a copy"), 0o644)
	adoptCopies = func() bool { return false }
	SyncSkill()
	if t1, _ := os.Readlink(filepath.Join(claude, "SKILL.md")); t1 != other {
		t.Errorf("another Kero's link taken: %q", t1)
	}
	if b, _ := os.ReadFile(filepath.Join(agents, "SKILL.md")); string(b) != "a copy" {
		t.Errorf("a build that takes no copies took one: %q", b)
	}

	// A plugin of an older kero is made current; another Kero's, or one
	// not there, stays as it is.
	pi := filepath.Join(home, ".pi", "agent")
	t.Setenv("PI_CODING_AGENT_DIR", pi)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	ts := filepath.Join(pi, "extensions", "kero.ts")
	os.MkdirAll(filepath.Dir(ts), 0o755)
	os.WriteFile(ts, []byte(`run("/elsewhere/kero-dev/bin/kero")`), 0o644)
	SyncSkill()
	if b, _ := os.ReadFile(ts); string(b) != `run("/elsewhere/kero-dev/bin/kero")` {
		t.Errorf("another Kero's plugin taken: %q", b)
	}
	os.WriteFile(ts, append([]byte("// older\nrun("), append(marshal(kero()), ')')...), 0o644)
	SyncSkill()
	for _, it := range agentHooks("pi") {
		if it.state() != "current" {
			t.Errorf("%s: %s", it.name(), it.state())
		}
	}
	if _, err := os.Stat(filepath.Join(home, ".config", "opencode")); err == nil {
		t.Error("SyncSkill installed OpenCode's plugin")
	}
}
