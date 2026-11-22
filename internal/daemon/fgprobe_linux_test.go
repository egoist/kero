//go:build linux

package daemon

import (
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// groupMember is the question tick asks of a foreground job: is there
// still a process in this group, and which one.
func TestGroupMember(t *testing.T) {
	pgid, err := syscall.Getpgid(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if pid, ok := groupMember(pgid); !ok || pid == 0 {
		t.Fatalf("the test's own group: %d, %v", pid, ok)
	}
	if _, ok := groupMember(1 << 22); ok {
		t.Fatal("a group that is not there reads as alive")
	}
	// A process in a group of its own: its own pid while it runs, none
	// after it ends.
	cmd := exec.Command("sleep", "30")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pg := cmd.Process.Pid
	defer cmd.Process.Kill()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if pid, ok := groupMember(pg); ok {
			if pid != pg {
				t.Fatalf("the member of the group of one process: %d, want %d", pid, pg)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the group of the process that runs does not read as alive")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cmd.Process.Kill()
	cmd.Wait()
	deadline = time.Now().Add(5 * time.Second)
	for {
		if _, ok := groupMember(pg); !ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the group of a process that ended still reads as alive")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
