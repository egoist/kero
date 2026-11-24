//go:build darwin || linux

package daemon

import (
	"errors"
	"os"
	"os/exec"
	"testing"
	"time"
)

// A shell that exits on its own lets go of the terminal: kerod would
// else hold a descriptor for every session that ever ended, over its
// whole uptime.
func TestShellExitLetsGoOfTheTerminal(t *testing.T) {
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("sh not installed")
	}
	s := testPane(t)
	proc, err := startPTY(ptyOptions{
		Path: sh, Args: []string{"sh", "-c", "exit 1"}, Dir: t.TempDir(),
		Env: []string{"TERM=xterm-256color"}, Cols: s.info.Cols, Rows: s.info.Rows,
	})
	if err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	s.proc = proc
	s.mu.Unlock()
	go s.pump(proc)
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := proc.master.Read(make([]byte, 1)); errors.Is(err, os.ErrClosed) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the terminal's master is still open after the shell exited")
		}
	}
}
