//go:build darwin || linux

package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"kero/internal/proto"
)

// Restore diagnostics must describe the actual shell fallback without exposing
// command arguments, environment values, or the agent's conversation ID.
func TestRestoreDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		name    string
		agent   *proto.AgentSession
		disable bool
		browser bool
		plain   bool
		reason  string
		command string
	}{
		{name: "unrecorded", reason: "no agent session recorded"},
		{name: "ordinary shell", plain: true, reason: "no agent session recorded"},
		{name: "ordinary shell with resumption disabled", plain: true, disable: true, reason: "no agent session recorded"},
		{name: "unsupported", agent: &proto.AgentSession{Agent: "private-agent", ID: "private-session-42"}, reason: "unsupported agent"},
		{name: "invalid ID", agent: &proto.AgentSession{Agent: "codex", ID: "private-session;42"}, reason: "invalid agent session ID"},
		{name: "disabled", agent: &proto.AgentSession{Agent: "codex", ID: "private-session-42"}, disable: true, reason: "agent resumption disabled"},
		{name: "resumed", agent: &proto.AgentSession{Agent: "codex", ID: "private-session-42"}, command: "codex resume private-session-42"},
		{name: "browser", browser: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := testDaemon(t)
			var output bytes.Buffer
			d.log = log.New(&output, "", 0)
			argsPath := filepath.Join(d.dir, "args")
			t.Setenv("KERO_TEST_ARGS", argsPath)
			t.Setenv("KERO_TEST_PRIVATE", "private-environment-value")
			// Capture the actual PTY argv without running an installed agent or
			// loading the user's shell profile. The name sh selects POSIX argv.
			shell := filepath.Join(d.dir, "sh")
			if err := os.WriteFile(shell, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$KERO_TEST_ARGS\"\nprintf 'END\\n' >> \"$KERO_TEST_ARGS\"\nexec /bin/cat\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			config := fmt.Sprintf("command = %s\nresume-agents = %t\n", shell, !tc.disable)
			if err := os.WriteFile(os.Getenv("KERO_CONFIG"), []byte(config), 0o600); err != nil {
				t.Fatal(err)
			}
			sp := savedPane{ID: "pane", Dir: d.dir, Command: []string{"private-command-payload"}, Agent: tc.agent, Cols: 80, Rows: 24}
			if tc.plain {
				sp.Command = nil
			}
			if tc.browser {
				sp.URL = "https://example.test/private-page"
			}
			data, err := json.Marshal(savedState{Version: 2, Sessions: []savedSession{{ID: "session", Panes: []savedPane{sp}}}})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(d.statePath(), data, 0o600); err != nil {
				t.Fatal(err)
			}
			d.restore()
			p := d.panes["pane"]
			if p == nil {
				t.Fatalf("pane not restored: %s", output.String())
			}
			t.Cleanup(func() {
				p.close()
				if p.proc != nil {
					select {
					case <-p.proc.exited:
					case <-time.After(5 * time.Second):
						t.Error("fixture shell did not exit")
					}
				}
			})
			gotLog := output.String()
			if tc.reason != "" {
				if want := "pane pane restored as shell: " + tc.reason; !strings.Contains(gotLog, want) {
					t.Errorf("missing restoration reason %q in %q", want, gotLog)
				}
			} else if strings.Contains(gotLog, "restored as shell") {
				t.Errorf("reported a shell fallback for %s: %s", tc.name, gotLog)
			}
			for _, private := range []string{"private-command-payload", "private-session", "private-agent", "private-environment-value", "private-page"} {
				if strings.Contains(gotLog, private) {
					t.Errorf("log exposed %q: %s", private, gotLog)
				}
			}
			if tc.browser {
				if p.proc != nil || p.info.URL != sp.URL {
					t.Fatalf("browser changed: %+v", p.info)
				}
				return
			}
			wantAgent := tc.agent
			if tc.disable {
				wantAgent = nil
			}
			p.mu.Lock()
			unchanged := reflect.DeepEqual(p.info.Command, sp.Command) && reflect.DeepEqual(p.info.AgentSession, wantAgent)
			p.mu.Unlock()
			if !unchanged {
				t.Error("restoration changed saved command or agent metadata")
			}
			var args string
			for deadline := time.Now().Add(5 * time.Second); ; {
				b, _ := os.ReadFile(argsPath)
				args = string(b)
				if strings.HasSuffix(args, "END\n") {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("fixture shell did not record its arguments")
				}
				time.Sleep(time.Millisecond)
			}
			if tc.command == "" {
				if args != "\nEND\n" {
					t.Errorf("shell fallback ran a command: %q", args)
				}
			} else if !strings.Contains(args, tc.command) {
				t.Errorf("resume command missing from PTY argv: %q", args)
			}
		})
	}
}

// Run owns signals and background goroutines, so exercise it in a subprocess.
func TestDaemonDiagnosticsProcess(t *testing.T) {
	if os.Getenv("KERO_TEST_DAEMON") != "1" {
		return
	}
	if err := Run(Options{Serve: true}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

func TestDaemonRunDiagnostics(t *testing.T) {
	dir := t.TempDir()
	// A short directory keeps the Unix socket address within macOS's limit.
	socketDir, err := os.MkdirTemp("", "kd-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(socketDir) })
	sock := filepath.Join(socketDir, "s")
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", filepath.Join(dir, "config"))
	t.Setenv("KERO_SOCKET", sock)
	t.Setenv("KERO_TEST_DAEMON", "1")
	t.Setenv("KERO_TAKEOVER", "")
	newCommand := func() *exec.Cmd {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		t.Cleanup(cancel)
		return exec.CommandContext(ctx, os.Args[0], "-test.run=^TestDaemonDiagnosticsProcess$")
	}
	start := func() (*exec.Cmd, <-chan error) {
		cmd := newCommand()
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		t.Cleanup(func() { cmd.Process.Kill() })
		for deadline := time.Now().Add(5 * time.Second); ; {
			conn, err := net.DialTimeout("unix", sock, 100*time.Millisecond)
			if err == nil {
				conn.SetDeadline(time.Now().Add(time.Second))
				json.NewEncoder(conn).Encode(proto.Hello{Version: proto.Version})
				var welcome proto.Welcome
				err = json.NewDecoder(conn).Decode(&welcome)
				conn.Close()
				if err == nil && welcome.PID == cmd.Process.Pid {
					return cmd, done
				}
			}
			select {
			case err := <-done:
				t.Fatalf("daemon exited before readiness: %v", err)
			default:
			}
			if time.Now().After(deadline) {
				t.Fatal("daemon did not become ready")
			}
			time.Sleep(time.Millisecond)
		}
	}
	stop := func(cmd *exec.Cmd, done <-chan error, sig syscall.Signal) {
		t.Helper()
		if err := cmd.Process.Signal(sig); err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-done:
			if sig == syscall.SIGTERM && err != nil {
				t.Fatalf("clean shutdown: %v", err)
			}
			if sig == syscall.SIGKILL && err == nil {
				t.Error("killed daemon exited successfully")
			}
		case <-time.After(5 * time.Second):
			t.Fatal("daemon did not stop")
		}
	}
	readLog := func() string {
		b, err := os.ReadFile(filepath.Join(dir, "kerod.log"))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	marker := filepath.Join(dir, "kerod.running")
	first, firstDone := start()
	if strings.Contains(readLog(), "previous daemon exit was unclean") {
		t.Error("first start reported an unclean exit")
	}
	before, err := os.Stat(marker)
	if err != nil {
		t.Errorf("running daemon has no run marker: %v", err)
	}
	out, err := newCommand().CombinedOutput()
	if err == nil || !strings.Contains(string(out), "kerod is already running") {
		t.Fatalf("duplicate daemon: %v, %s", err, out)
	}
	after, err := os.Stat(marker)
	if err != nil {
		t.Errorf("duplicate daemon removed run marker: %v", err)
	} else if before != nil && !before.ModTime().Equal(after.ModTime()) {
		t.Error("duplicate daemon changed the owner's run marker")
	}
	if got := strings.Count(readLog(), "--- daemon run ---"); got != 1 {
		t.Errorf("run separators after duplicate: got %d, want 1", got)
	}
	stop(first, firstDone, syscall.SIGTERM)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Errorf("clean shutdown left run marker: %v", err)
	}
	second, secondDone := start()
	if strings.Contains(readLog(), "previous daemon exit was unclean") {
		t.Error("clean predecessor reported as unclean")
	}
	stop(second, secondDone, syscall.SIGKILL)
	if _, err := os.Stat(marker); err != nil {
		t.Errorf("killed daemon lost run marker: %v", err)
	}
	third, thirdDone := start()
	got := readLog()
	if strings.Count(got, "previous daemon exit was unclean") != 1 {
		t.Errorf("unclean predecessor not identified once: %s", got)
	}
	if strings.Contains(got, "crash") {
		t.Errorf("claimed a crash cause: %s", got)
	}
	if strings.Count(got, "--- daemon run ---") != 3 {
		t.Errorf("missing daemon run boundaries: %s", got)
	}
	stop(third, thirdDone, syscall.SIGTERM)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Errorf("final clean shutdown left run marker: %v", err)
	}
}
