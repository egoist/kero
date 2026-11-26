package client

import (
	"fmt"
	"io"
	"net"
	"path/filepath"
	"testing"
)

// A daemon that answers the socket but not with a hello is a daemon: its
// pid is unknown, but "no daemon" is not the answer, and a caller that
// reads it as none stops nothing and says it stopped.
func TestDaemonPIDSaysWhenNobodySaysHello(t *testing.T) {
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
	pid, err := DaemonPID()
	if err == nil {
		t.Fatalf("a daemon that did not say hello was read as none: pid %d", pid)
	}
	if pid != 0 {
		t.Errorf("the pid was %d, want none", pid)
	}
}

// No daemon answers the socket when it is not there: that is none, and it
// is no error.
func TestDaemonPIDOfNoDaemon(t *testing.T) {
	t.Setenv("KERO_SOCKET", filepath.Join(t.TempDir(), "kerod.sock"))
	pid, err := DaemonPID()
	if err != nil {
		t.Errorf("no daemon answered the socket: %v, want none and no error", err)
	}
	if pid != 0 {
		t.Errorf("the pid was %d, want none", pid)
	}
}
