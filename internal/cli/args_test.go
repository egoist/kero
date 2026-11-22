package cli

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"kero/internal/proto"
)

// A number the CLI cannot read is a usage error: `kero read -n abc` and
// `kero split -r abc` took it for none, and read the pane whole or
// split it in half, as though the number had been said.
func TestNumberArgsAreUsageErrors(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)

	// A count of lines that is no number.
	if err := run([]string{"read", "p1", "-n", "abc"}, ""); !errors.Is(err, errUsage) {
		t.Errorf("kero read -n abc: %v, want a usage error", err)
	}
	// A ratio that is no number.
	if err := run([]string{"split", "p1", "-r", "abc"}, ""); !errors.Is(err, errUsage) {
		t.Errorf("kero split -r abc: %v, want a usage error", err)
	}
	// A ratio out of the room's share: kerod takes it for half.
	if err := run([]string{"split", "p1", "-r", "5"}, ""); !errors.Is(err, errUsage) {
		t.Errorf("kero split -r 5: %v, want a usage error", err)
	}

	// Nothing was read and nothing was split: the CLI said no before it
	// asked the daemon of anything but the state.
	for _, m := range calls() {
		if m != "state" {
			t.Errorf("the daemon was asked of %q, want only of the state", m)
		}
	}
}

// A number the CLI can read is used as it is said.
func TestNumberArgsAreUsed(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)

	if err := run([]string{"read", "p1", "-n", "40"}, ""); err != nil {
		t.Fatalf("kero read -n 40: %v", err)
	}
	if err := run([]string{"split", "p1", "-r", "0.3"}, ""); err != nil {
		t.Fatalf("kero split -r 0.3: %v", err)
	}
	got := calls()
	if len(got) != 4 || got[0] != "state" || got[1] != "read" || got[2] != "state" || got[3] != "split" {
		t.Errorf("the daemon was asked of %q", got)
	}
}

// A ratio of NaN passes the two comparisons: NaN is neither less than
// none nor more than all. It used to go as far as the daemon, which
// answered that it could not be written out at all, so the command
// failed with a word of nothing instead of a usage error naming the flag.
func TestRatioOfNaNIsAUsageError(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)

	for _, v := range []string{"NaN", "nan"} {
		if err := run([]string{"split", "p1", "-r", v}, ""); !errors.Is(err, errUsage) {
			t.Errorf("kero split -r %s: %v, want a usage error", v, err)
		}
	}
	for _, m := range calls() {
		if m != "state" {
			t.Errorf("the daemon was asked of %q, want only of the state", m)
		}
	}
}

// A status the CLI cannot read is a usage error: `kero wait --for idel`
// took it for a status, and kerod waits for a pane to have it, and none
// ever does, so the wait never ended.
func TestStatusArgsAreUsageErrors(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)

	if err := run([]string{"wait", "p1", "--for", "idel"}, ""); !errors.Is(err, errUsage) {
		t.Errorf("kero wait --for idel: %v, want a usage error", err)
	}
	if err := run([]string{"wait", "p1", "--for", "working,idel"}, ""); !errors.Is(err, errUsage) {
		t.Errorf("kero wait --for working,idel: %v, want a usage error", err)
	}

	// Nothing was waited for: the CLI said no before it asked the daemon
	// of anything but the state.
	for _, m := range calls() {
		if m != "state" {
			t.Errorf("the daemon was asked of %q, want only of the state", m)
		}
	}
}

// A status the CLI can read is waited for as it is said.
func TestStatusArgsAreUsed(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)

	if err := run([]string{"wait", "p1", "--for", "waiting,error"}, ""); err != nil {
		t.Fatalf("kero wait --for waiting,error: %v", err)
	}
	got := calls()
	if len(got) != 2 || got[0] != "state" || got[1] != "wait" {
		t.Errorf("the daemon was asked of %q, want of the state and of a wait", got)
	}
}

// A timeout of less than none is a usage error: `kero wait -t -5s` took
// it for no timeout at all, and kerod waits for the pane till it ends,
// which is no end.
func TestTimeoutArgsAreUsageErrors(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)

	for _, v := range []string{"-5s", "-5", "-0.5s"} {
		if err := run([]string{"wait", "p1", "-t", v}, ""); !errors.Is(err, errUsage) {
			t.Errorf("kero wait -t %s: %v, want a usage error", v, err)
		}
	}

	// Nothing was waited for: the CLI said no before it asked the daemon
	// of anything but the state.
	for _, m := range calls() {
		if m != "state" {
			t.Errorf("the daemon was asked of %q, want only of the state", m)
		}
	}
}

// The daemon's state, which it could not give, is said: no sessions
// would tell the user theirs were gone.
func TestDaemonStatusSaysAFailedState(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)
	failCall(t, "state", "the state is gone")

	out := captureStdout(t, func() {
		if err := run([]string{"daemon", "status"}, ""); err != nil {
			t.Errorf("kero daemon status: %v", err)
		}
	})
	if !strings.Contains(out, "the state is gone") {
		t.Errorf("no word of the state that failed:\n%s", out)
	}
	if strings.Contains(out, "sessions") {
		t.Errorf("it counted the sessions it has none of:\n%s", out)
	}
	if m := calls(); len(m) == 0 || m[0] != "state" {
		t.Errorf("the daemon was asked of %q, want of the state", m)
	}
}

// fakeDaemon is a kerod that answers what the CLI asks of it, and
// remembers the calls it got. Its socket is the one the CLI is told of.
func fakeDaemon(t *testing.T) (string, func() []string) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "kerod.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	var mu sync.Mutex
	var got []string
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				r := bufio.NewReader(conn)
				line, err := proto.ReadLine(r, proto.MaxLine)
				if err != nil {
					return
				}
				var hello proto.Hello
				json.Unmarshal(line, &hello)
				fmt.Fprintf(conn, `{"version":%d,"pid":1}`+"\n", proto.Version)
				for {
					line, err := proto.ReadLine(r, proto.MaxLine)
					if err != nil {
						return
					}
					var req proto.Request
					if json.Unmarshal(line, &req) != nil {
						return
					}
					mu.Lock()
					got = append(got, req.Method)
					mu.Unlock()
					if msg, failed := failing(req.Method); failed {
						fmt.Fprintf(conn, `{"id":%d,"error":%q}`+"\n", req.ID, msg)
						continue
					}
					res, _ := json.Marshal(fakeResult(req.Method))
					fmt.Fprintf(conn, `{"id":%d,"result":%s}`+"\n", req.ID, res)
				}
			}()
		}
	}()
	return sock, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), got...)
	}
}

// failing is what the fake kerod answers a method with as an error, when
// it answers with one: failCall says.
func failing(method string) (string, bool) {
	failMu.Lock()
	defer failMu.Unlock()
	msg, ok := failCalls[method]
	return msg, ok
}

var (
	failMu    sync.Mutex
	failCalls = map[string]string{}
)

// failCall makes the fake kerod answer a method with an error, till the
// test is over.
func failCall(t *testing.T, method, msg string) {
	t.Helper()
	failMu.Lock()
	defer failMu.Unlock()
	failCalls[method] = msg
	t.Cleanup(func() {
		failMu.Lock()
		defer failMu.Unlock()
		delete(failCalls, method)
	})
}

// captureStdout is what f wrote to the standard output.
func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		var b bytes.Buffer
		io.Copy(&b, r)
		done <- b.String()
	}()
	f()
	w.Close()
	os.Stdout = old
	return <-done
}

// fakeResult is what the fake kerod answers a call of the CLI with.
func fakeResult(method string) any {
	switch method {
	case "state":
		return proto.State{Sessions: []proto.Session{
			{ID: "s1", Name: "api", Panes: []proto.Pane{{ID: "p1", Status: proto.Idle}}},
		}}
	case "read":
		return proto.ReadResult{Text: "hello\n"}
	case "wait":
		return proto.Pane{ID: "p1", Status: proto.Waiting}
	case "split":
		return proto.Session{ID: "s2", Name: "new", Focus: "p2"}
	}
	return nil
}
