package client

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
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

// A socket that is there but cannot be asked is a daemon that is there:
// its pid is unknown, but "no daemon" is not the answer, and a caller
// that reads it as none stops nothing and says it stopped.
func TestDaemonPIDSaysWhenTheSocketCannotBeAsked(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("windows does not keep a folder from being entered")
	}
	if os.Geteuid() == 0 {
		t.Skip("root asks the socket whatever its folder's permissions")
	}
	dir := t.TempDir()
	sock := filepath.Join(dir, "kerod.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	// The socket is there, but the folder it is in cannot be entered, so
	// the dial cannot be made: another user's kerod, or one whose folder
	// the user may not look into.
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	t.Setenv("KERO_SOCKET", sock)
	pid, err := DaemonPID()
	if err == nil {
		t.Fatalf("a kerod that could not be asked was read as none: pid %d", pid)
	}
	if pid != 0 {
		t.Errorf("the pid was %d, want none", pid)
	}
}
