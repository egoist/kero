//go:build linux || darwin

package daemon

import (
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A pipeline's leader going first does not end the job: the pane keeps
// the name of what runs, as `git log | less` keeps "less" after git is
// gone.
func TestPipelineLeaderGoneKeepsTheJob(t *testing.T) {
	s := testPane(t)
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("sh not installed")
	}
	// Job control on, so that the pipeline is a job of its own: true is
	// its leader and ends at once, sleep 30 is the member that goes on.
	proc, err := startPTY(ptyOptions{
		Path: shell, Args: []string{"sh", "-c", "set -m; true | sleep 30"},
		Dir: t.TempDir(), Env: []string{"TERM=xterm-256color", "PATH=/usr/local/bin:/usr/bin:/bin"},
		Cols: s.info.Cols, Rows: s.info.Rows,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer proc.Kill()
	s.mu.Lock()
	s.proc = proc
	s.shellPID = proc.PID()
	s.mu.Unlock()
	go s.pump(proc)

	// The job is in the terminal's foreground now.
	var pg int
	deadline := time.Now().Add(10 * time.Second)
	for {
		pg = proc.Foreground()
		if pg != 0 && pg != proc.PID() {
			break
		}
		if time.Now().After(deadline) {
			t.Skip("this shell does not give the pipeline a job of its own")
		}
		time.Sleep(20 * time.Millisecond)
	}
	defer syscall.Kill(-pg, syscall.SIGKILL)
	// The leader is gone, the member is not.
	deadline = time.Now().Add(10 * time.Second)
	for procName(pg) != "" {
		if time.Now().After(deadline) {
			t.Fatalf("the leader %d is still there", pg)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := groupMember(pg); !ok {
		t.Fatalf("the group %d reads as gone though a member runs", pg)
	}
	// The pane keeps the name of the member.
	s.tick(time.Now())
	s.mu.Lock()
	got := s.info.Process
	s.mu.Unlock()
	if got == "" {
		t.Fatal("the foreground job's name is gone with its leader")
	}
	if !strings.Contains(got, "sleep") {
		t.Fatalf("the foreground job is %q, want sleep", got)
	}
}
