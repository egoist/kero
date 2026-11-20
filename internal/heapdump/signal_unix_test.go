//go:build !windows

package heapdump

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// SIGUSR1 asks for a dump while the process runs: `kill -USR1 <pid>`,
// as a report's writer would.
func TestSIGUSR1Dumps(t *testing.T) {
	dir := withTempDir(t)
	t.Setenv("KERO_HEAP_PROFILE", "1")
	Enable()
	if err := syscall.Kill(os.Getpid(), syscall.SIGUSR1); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, fmt.Sprintf("heap-%d.pprof", os.Getpid()))
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		if _, err := os.Stat(want); err == nil {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Errorf("no dump within five seconds of SIGUSR1")
}
