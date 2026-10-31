package cli

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
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

func TestVibeSkillCustomHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("KERO_HOME", filepath.Join(home, "kero's home"))
	vibe := filepath.Join(home, "custom vibe home")
	t.Setenv("VIBE_HOME", vibe)
	runSkill(t, "remove", "--agent", "vibe")
	if _, err := os.Stat(vibe); !os.IsNotExist(err) {
		t.Fatalf("remove created a Vibe home: %v", err)
	}
	runSkill(t, "setup", "--agent", "vibe")
	if out := runSkill(t, "status", "--agent", "vibe"); strings.Count(out, "current") != 2 {
		t.Fatal(out)
	}
	if _, err := os.Stat(filepath.Join(home, ".vibe")); !os.IsNotExist(err) {
		t.Fatalf("ignored VIBE_HOME: %v", err)
	}
	runSkill(t, "remove", "--agent", "vibe")
	if got := strings.TrimSpace(read(t, filepath.Join(vibe, "hooks.toml"))); got != "" {
		t.Fatalf("Kero's hooks remain: %s", got)
	}
}

func TestVibeSkillUpdatesHooks(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("KERO_HOME", filepath.Join(home, "kero"))
	t.Setenv("VIBE_HOME", home)
	path := filepath.Join(home, "hooks.toml")
	for name, input := range map[string]string{
		"empty inline array": "hooks = []\n",
		"user inline array":  "hooks = [{name='audit', type='pre_tool', command='echo audit', strict=true, match='bash'}]\n",
		"outdated and duplicate hooks": `[[hooks]]
name = 'kero-pre-tool'
type = 'post_agent'
command = "'/old/kero' hook vibe"
timeout = 3
[[hooks]]
name = 'kero-pre-tool'
type = 'pre_tool'
command = "'/old/kero' hook vibe"
[[hooks]]
name = 'kero-post-agent'
type = 'post_agent'
command = "'/old/kero' hook vibe"
match = 'bash'
`,
	} {
		t.Run(name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
				t.Fatal(err)
			}
			before := runSkill(t, "status", "--agent", "vibe")
			if name == "outdated and duplicate hooks" && !strings.Contains(before, "outdated") {
				t.Fatal(before)
			}
			runSkill(t, "setup", "--agent", "vibe")
			got := read(t, path)
			if strings.Count(got, "hook vibe") != 2 || strings.Contains(got, "/old/kero") {
				t.Fatalf("incorrect replacement: %s", got)
			}
			if out := runSkill(t, "status", "--agent", "vibe"); strings.Count(out, "current") != 2 {
				t.Fatal(out)
			}
			runSkill(t, "setup", "--agent", "vibe")
			if again := read(t, path); got != again {
				t.Fatal("setup is not idempotent")
			}
			runSkill(t, "remove", "--agent", "vibe")
			if name == "user inline array" {
				var got, want struct{ Hooks []map[string]any }
				if _, err := toml.Decode(read(t, path), &got); err != nil {
					t.Fatal(err)
				}
				if _, err := toml.Decode(input, &want); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("changed the user's hook: %#v", got)
				}
			}
		})
	}
}

func TestVibeSkillRefusesBadHooks(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("KERO_HOME", filepath.Join(home, "kero"))
	t.Setenv("VIBE_HOME", home)
	path := filepath.Join(home, "hooks.toml")
	for _, input := range []string{
		"[[hooks]\n",
		"hooks = 'not a list'\n",
		"hooks = [1]\n",
		"[hooks]\nname='not an array'\n",
		"hooks = [{name='kero-pre-tool', type='pre_tool', command='echo mine'}]\n",
	} {
		for _, action := range []string{"setup", "remove"} {
			t.Run(action+"/"+input, func(t *testing.T) {
				if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
					t.Fatal(err)
				}
				if err := skillCmd([]string{action, "--agent", "vibe"}); err == nil {
					t.Fatal("changed hooks it cannot safely edit")
				}
				if got := read(t, path); got != input {
					t.Fatalf("changed the user's file: %s", got)
				}
			})
		}
	}
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
		".vibe/hooks.toml": `# User hooks
custom_setting = "keep"
[[hooks]]
name = 'audit'
type = 'post_agent'
command = 'echo audit'
timeout = 7.5
description = 'User hook'
[hooks.metadata]
label = 'keep this too'
`,
		".vibe/plugins/other/keep.txt": "Another Vibe plugin\n",
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
	hooksFile := filepath.Join(home, ".vibe", "hooks.toml")
	checkOutput := func(out, want string) {
		t.Helper()
		if !strings.Contains(out, want) || strings.Contains(out, "claude") || !strings.Contains(out, "hook") || !strings.Contains(out, "hooks.toml") {
			t.Fatalf("output %q, want the shared skill and standalone Vibe hooks (%s)", out, want)
		}
	}
	checkOutput(runSkill(t, "status", "--agent", "vibe"), "missing")
	checkOutput(runSkill(t, "setup", "--agent", "vibe", "--dry-run"), "would setup")
	if _, err := os.Stat(shared); !os.IsNotExist(err) {
		t.Fatalf("dry-run wrote the skill: %v", err)
	}
	if got := read(t, hooksFile); got != files[".vibe/hooks.toml"] {
		t.Fatal("dry-run changed the user's hooks")
	}
	var hooks string
	for i := range 2 {
		checkOutput(runSkill(t, "setup", "--agent", "vibe"), "installed")
		if got := read(t, shared); got != skillGuide {
			t.Fatalf("installed skill: %q", got)
		}
		got := read(t, hooksFile)
		if i > 0 && got != hooks {
			t.Fatal("repeated setup changed the hooks")
		}
		hooks = got
	}
	var config struct {
		Hooks []struct {
			Name, Type, Command string
			Timeout             float64
		}
	}
	if _, err := toml.Decode(hooks, &config); err != nil {
		t.Fatal(err)
	}
	if len(config.Hooks) != 3 || config.Hooks[0].Name != "audit" {
		t.Fatalf("lost or duplicated hooks: %+v", config.Hooks)
	}
	for i, typ := range []string{"pre_tool", "post_agent"} {
		h := config.Hooks[i+1]
		if h.Type != typ || h.Timeout != 10 || h.Command != (agentHook{agent: "vibe"}).command() {
			t.Errorf("incorrect Vibe hook: %+v", h)
		}
	}
	if st, err := os.Stat(hooksFile); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("changed the user's permissions: %v, %v", st, err)
	}
	checkOutput(runSkill(t, "status", "--agent", "VIBE"), "current")
	checkOutput(runSkill(t, "remove", "--agent", "vibe", "--dry-run"), "would remove")
	if got := read(t, shared); got != skillGuide {
		t.Fatal("dry-run changed the skill")
	}
	if got := read(t, hooksFile); got != hooks {
		t.Fatal("dry-run changed the hooks")
	}
	for range 2 {
		checkOutput(runSkill(t, "remove", "--agent", "vibe"), "removed")
	}
	if _, err := os.Stat(shared); !os.IsNotExist(err) {
		t.Fatalf("skill remains after removal: %v", err)
	}
	checkOutput(runSkill(t, "status", "--agent", "vibe"), "missing")
	if _, err := os.Stat(filepath.Join(home, ".vibe", "plugins", "kero")); !os.IsNotExist(err) {
		t.Fatalf("unexpected Kero plugin: %v", err)
	}
	for rel, content := range files {
		got := read(t, filepath.Join(home, filepath.FromSlash(rel)))
		if rel == ".vibe/hooks.toml" {
			var before, after map[string]any
			if _, err := toml.Decode(content, &before); err != nil {
				t.Fatal(err)
			}
			if _, err := toml.Decode(got, &after); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(before, after) {
				t.Errorf("changed the user's hooks or settings:\n%s", got)
			}
		} else if got != content {
			t.Errorf("changed %s: %q", rel, got)
		}
	}
	if err := filepath.WalkDir(home, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == filepath.Join(home, ".kero", "bin") {
			return filepath.SkipDir // the stable CLI is shared with other agent hooks
		}
		if !entry.IsDir() {
			rel, err := filepath.Rel(home, path)
			if err != nil {
				return err
			}
			if _, ok := files[filepath.ToSlash(rel)]; !ok {
				t.Errorf("unexpected file after removal: %s", rel)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}
