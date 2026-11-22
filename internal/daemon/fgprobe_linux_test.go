//go:build linux

package daemon

import (
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// groupAlive is the question tick asks of a pipeline's group when its
// leader has gone first: the group is alive while any of it is.
func TestGroupAlive(t *testing.T) {
	// The test's own group: alive while the test runs.
	pgid, err := syscall.Getpgid(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if !groupAlive(pgid) {
		t.Fatal("the test's own group reads as dead")
	}
	if groupAlive(1 << 22) {
		t.Fatal("a group that is not there reads as alive")
	}
	// A process in a group of its own: alive while it runs, dead after.
	cmd := exec.Command("sleep", "30")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pg := cmd.Process.Pid
	defer cmd.Process.Kill()
	deadline := time.Now().Add(5 * time.Second)
	for !groupAlive(pg) {
		if time.Now().After(deadline) {
			t.Fatal("the group of the process that runs does not read as alive")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cmd.Process.Kill()
	cmd.Wait()
	deadline = time.Now().Add(5 * time.Second)
	for groupAlive(pg) {
		if time.Now().After(deadline) {
			t.Fatal("the group of a process that ended still reads as alive")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
