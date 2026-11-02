package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testHook(t *testing.T, settings string) agentHook {
	t.Helper()
	t.Setenv("KERO_HOME", filepath.Join(t.TempDir(), "kero home"))
	h := agentHook{"claude", filepath.Join(t.TempDir(), "settings.json")}
	if settings != "" {
		if err := os.WriteFile(h.file, []byte(settings), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return h
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Installing keeps the rest of the settings, in their order, and the
// other hooks; installing again changes nothing; removing takes only
// kero's out.
func TestHookInstallKeepsSettings(t *testing.T) {
	h := testHook(t, `{
  "model": "opus",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "echo hi"}]}]
  },
  "env": {"A": "1"}
}
`)
	if st := h.state(); st != "missing" {
		t.Fatalf("state %s before install", st)
	}
	if err := h.install(); err != nil {
		t.Fatal(err)
	}
	got := read(t, h.file)
	if h.state() != "current" {
		t.Fatalf("state %s after install:\n%s", h.state(), got)
	}
	if i, j, k := strings.Index(got, `"model"`), strings.Index(got, `"hooks"`), strings.Index(got, `"env"`); !(i < j && j < k) {
		t.Fatalf("keys out of order:\n%s", got)
	}
	for _, want := range []string{`"say done"`, `"echo hi"`, `"matcher": "startup"`, `"timeout": 10`, "kero home/bin/kero' hook claude"} {
		if !strings.Contains(got, want) {
			t.Fatalf("no %s in:\n%s", want, got)
		}
	}
	if err := h.install(); err != nil {
		t.Fatal(err)
	}
	if again := read(t, h.file); again != got {
		t.Fatalf("installing again changed it:\n%s", again)
	}
	if err := h.remove(); err != nil {
		t.Fatal(err)
	}
	removed := read(t, h.file)
	if strings.Contains(removed, "kero") || !strings.Contains(removed, `"echo hi"`) || !strings.Contains(removed, `"say done"`) {
		t.Fatalf("after remove:\n%s", removed)
	}
	if h.state() != "missing" {
		t.Fatalf("state %s after remove", h.state())
	}
}

// Another kero's hook, as of a moved KERO_HOME, is outdated, and setup
// replaces it.
func TestHookReplacesOutdated(t *testing.T) {
	h := testHook(t, `{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "'/old/kero/bin/kero' hook claude", "timeout": 10}]}]}}`)
	if st := h.state(); st != "outdated" {
		t.Fatalf("state %s, want outdated", st)
	}
	if err := h.install(); err != nil {
		t.Fatal(err)
	}
	got := read(t, h.file)
	if strings.Contains(got, "/old/kero") || strings.Count(got, "hook claude") != 1 {
		t.Fatalf("after install:\n%s", got)
	}
}

// Without a settings file, install makes one, and remove takes away what
// it made.
func TestHookNewFile(t *testing.T) {
	h := testHook(t, "")
	if err := h.install(); err != nil {
		t.Fatal(err)
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(read(t, h.file)), &v); err != nil {
		t.Fatal(err)
	}
	if err := h.remove(); err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(read(t, h.file)); got != "{}" {
		t.Fatalf("after remove: %s", got)
	}
}

// Settings that aren't JSON are left alone.
func TestHookRefusesBadSettings(t *testing.T) {
	h := testHook(t, "{ // a comment\n}")
	if err := h.install(); err == nil {
		t.Fatal("installed into settings it can't read")
	}
	if got := read(t, h.file); got != "{ // a comment\n}" {
		t.Fatalf("changed: %s", got)
	}
}

// Pi's and OpenCode's plugins go in when the agent is installed, run
// Kero's own kero command, and come out whole.
func TestAgentPlugins(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("KERO_HOME", filepath.Join(home, "kero"))
	for _, env := range []string{"CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME"} {
		t.Setenv(env, "")
	}
	names := func() (out []string) {
		for _, it := range agentHooks("") {
			out = append(out, it.name())
		}
		return
	}
	if got := strings.Join(names(), ","); got != "claude" {
		t.Fatalf("with no agents installed: %s", got)
	}
	os.MkdirAll(filepath.Join(home, ".pi", "agent"), 0o755)
	os.MkdirAll(filepath.Join(home, ".config", "opencode"), 0o755)
	if got := strings.Join(names(), ","); got != "claude,pi,opencode" {
		t.Fatalf("with Pi and OpenCode: %s", got)
	}
	for _, it := range agentHooks("agents") {
		if it.state() != "missing" {
			t.Fatalf("%s: %s before install", it.name(), it.state())
		}
		if err := it.install(); err != nil {
			t.Fatal(err)
		}
		if it.state() != "current" {
			t.Fatalf("%s: %s after install", it.name(), it.state())
		}
		p := it.(agentPlugin)
		for name := range p.files {
			b := read(t, filepath.Join(p.dir, name))
			if strings.Contains(b, "__KERO__") || name != "package.json" && !strings.Contains(b, filepath.Join(home, "kero", "bin", "kero")) {
				t.Fatalf("%s/%s runs no kero:\n%s", it.name(), name, b)
			}
		}
		if err := it.remove(); err != nil {
			t.Fatal(err)
		}
		if it.state() != "missing" {
			t.Fatalf("%s: %s after remove", it.name(), it.state())
		}
	}
	if _, err := os.Stat(filepath.Join(home, ".config", "opencode", "plugins", "kero")); !os.IsNotExist(err) {
		t.Fatal("OpenCode's plugin directory stayed")
	}
	if _, err := os.Stat(filepath.Join(home, ".pi", "agent", "extensions")); err != nil {
		t.Fatal("Pi's extensions directory went with Kero's extension")
	}
}

func TestMain(m *testing.M) {
	// The kero command of TestCodexHookRunsInEveryShell: this test binary.
	if os.Getenv("KERO_TEST_HOOK") == "1" {
		fmt.Println("hook ran:", strings.Join(os.Args[1:], " "))
		os.Exit(0)
	}
	os.Exit(m.Run())
}
