package cli

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kero/internal/proto"
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

// Native Vibe hooks register only root conversations, silently: their stdout
// must not contain Claude's hookSpecificOutput or reset the session's name.
func TestVibeHook(t *testing.T) {
	for _, c := range []struct {
		name, input string
		outside     bool
		register    bool
	}{
		{"before tool", `{"hook_event_name":"pre_tool","session_id":"root-id","parent_session_id":null,"cwd":"/repo"}`, false, true},
		{"after turn", `{"hook_event_name":"post_agent","session_id":"root-id","cwd":"/repo"}`, false, true},
		{"child before tool", `{"hook_event_name":"pre_tool","session_id":"child-id","parent_session_id":"root-id"}`, false, false},
		{"child after turn", `{"hook_event_name":"post_agent","session_id":"child-id","parent_session_id":"root-id"}`, false, false},
		{"agent id", `{"hook_event_name":"post_agent","session_id":"child-id","agent_id":"child"}`, false, false},
		{"no session", `{"hook_event_name":"post_agent"}`, false, false},
		{"wrong event", `{"hook_event_name":"SessionStart","session_id":"root-id"}`, false, false},
		{"malformed", `{"hook_event_name":"post_agent","session_id":"root-id","cwd":`, false, false},
		{"outside Kero", `{"hook_event_name":"post_agent","session_id":"root-id"}`, true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("KERO_HOME", t.TempDir())
			t.Setenv("KERO_SOCKET", "")
			t.Setenv("KERO_PANE", "stale-pane")
			t.Setenv("KERO_SESSION", "stale-session")
			t.Setenv("CODEX_THREAD_ID", "unrelated-parent")
			if c.outside {
				t.Setenv("KERO_PANE", "")
			}
			listener, err := net.Listen("unix", proto.SocketPath())
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			calls := make(chan proto.Request, 16)
			go func() {
				defer close(calls)
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				dec, enc := json.NewDecoder(conn), json.NewEncoder(conn)
				var hello proto.Hello
				if err := dec.Decode(&hello); err != nil {
					t.Error(err)
					return
				}
				enc.Encode(proto.Welcome{Version: proto.Version})
				for {
					var req proto.Request
					if err := dec.Decode(&req); err != nil {
						if err != io.EOF {
							t.Error(err)
						}
						return
					}
					calls <- req
					enc.Encode(proto.Message{ID: req.ID, Result: proto.AgentSessionResult{Pane: "actual-pane", Session: "actual-session"}})
				}
			}()
			input := filepath.Join(t.TempDir(), "input.json")
			if err := os.WriteFile(input, []byte(c.input), 0o600); err != nil {
				t.Fatal(err)
			}
			in, err := os.Open(input)
			if err != nil {
				t.Fatal(err)
			}
			defer in.Close()
			out, err := os.CreateTemp(t.TempDir(), "output")
			if err != nil {
				t.Fatal(err)
			}
			defer out.Close()
			stdin, stdout := os.Stdin, os.Stdout
			os.Stdin, os.Stdout = in, out
			defer func() { os.Stdin, os.Stdout = stdin, stdout }()
			if err := hookCmd([]string{"vibe"}); err != nil {
				t.Error(err)
			}
			listener.Close()
			var got []proto.Request
			for req := range calls {
				got = append(got, req)
			}
			if b := read(t, out.Name()); strings.TrimSpace(b) != "" {
				t.Errorf("native hook output: %s", b)
			}
			if !c.register {
				if len(got) != 0 {
					t.Errorf("registered a non-root event: %+v", got)
				}
				return
			}
			if len(got) != 1 || got[0].Method != "pane.agentSession" {
				t.Fatalf("calls: %+v", got)
			}
			params := got[0].Params.(map[string]any)
			if params["agent"] != "vibe" || params["session"] != "root-id" || params["dir"] != "/repo" || params["pid"] != float64(os.Getpid()) {
				t.Errorf("registration: %+v", params)
			}
		})
	}
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

// Agent integrations go in when installed, run Kero's own kero command,
// and remove only their own files or handlers.
func TestAgentPlugins(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("KERO_HOME", filepath.Join(home, "kero"))
	for _, env := range []string{"CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME", "VIBE_HOME"} {
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
	os.MkdirAll(filepath.Join(home, ".vibe"), 0o755)
	if got := strings.Join(names(), ","); got != "claude,pi,opencode,vibe" {
		t.Fatalf("with Pi, OpenCode and Vibe: %s", got)
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
		if p, ok := it.(agentPlugin); ok {
			for name := range p.files {
				b := read(t, filepath.Join(p.dir, name))
				if strings.Contains(b, "__KERO__") || name != "package.json" && !strings.Contains(b, filepath.Join(home, "kero", "bin", "kero")) {
					t.Fatalf("%s/%s runs no kero:\n%s", it.name(), name, b)
				}
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
	if _, err := os.Stat(filepath.Join(home, ".vibe", "plugins", "kero")); !os.IsNotExist(err) {
		t.Fatal("Vibe unexpectedly installed a plugin")
	}
	if _, err := os.Stat(filepath.Join(home, ".pi", "agent", "extensions")); err != nil {
		t.Fatal("Pi's extensions directory went with Kero's extension")
	}
}
