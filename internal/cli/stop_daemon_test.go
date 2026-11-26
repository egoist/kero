package cli

import (
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
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
