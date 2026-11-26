package cli

import (
	"fmt"
	"io"
	"net"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"kero/internal/proto"
)

// A daemon that answers the socket but not with a hello is a daemon: it is
// there, and `kero daemon stop` must not say it stopped. It read the
// silence as no daemon and exited 0, while the daemon kept the lock and
// its sessions.
func TestStopDaemonSaysWhenNobodySaysHello(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "kerod.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				fmt.Fprint(conn, "not a hello\n")
				io.Copy(io.Discard, conn)
			}()
		}
	}()
	t.Setenv("KERO_SOCKET", sock)
	err = StopDaemon()
	if err == nil {
		t.Fatal("a daemon that did not say hello was stopped")
	}
	if !strings.Contains(err.Error(), "hello") {
		t.Errorf("the error is %v, want the daemon's silence named", err)
	}
}

// A kerod that is shutting down can still accept on its socket and close
// it before a hello: the stop must wait for the socket to go quiet, not
// take one silent probe for the end. This daemon says hello once (with
// the pid of a child, so the stop's signal has somewhere to go), then
// accepts and closes without a word three times, and then is gone.
func TestStopDaemonWaitsForAShutdownThatSaysNothing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("windows stops through its event, not a signal")
	}
	child := exec.Command("sleep", "30")
	if err := child.Start(); err != nil {
		t.Skipf("no child process to name in the hello: %v", err)
	}
	t.Cleanup(func() { child.Process.Kill() })

	sock := filepath.Join(t.TempDir(), "kerod.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	var served atomic.Int32
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			if served.Add(1) == 1 {
				fmt.Fprintf(conn, `{"version":%d,"pid":%d}`+"\n", proto.Version, child.Process.Pid)
			}
			conn.Close() // silent after the first: a shutdown that says nothing
			if served.Load() == 4 {
				ln.Close() // three silent probes: the daemon is gone
			}
		}
	}()
	t.Setenv("KERO_SOCKET", sock)
	if err := StopDaemon(); err != nil {
		t.Fatalf("a stop that kept answering without a hello read as failed: %v", err)
	}
	if served.Load() < 4 {
		t.Errorf("the stop stopped asking after %d probes; it must wait for the socket to go quiet", served.Load())
	}
}
