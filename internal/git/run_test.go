package git

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// A git that leaves a child holding its output, as core.fsmonitor does, is
// killed when the context ends. The caller must not then wait for that child
// to finish: the statuses of every pane run one after another, and a hook
// that sleeps would hold them all past the deadline.
func TestStatusReturnsWhenGitLeavesAChild(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fsmonitor hook is a shell script")
	}
	r := repo(t, map[string]string{"a.txt": "a\n"})
	dir := t.TempDir()
	marker := filepath.Join(dir, "ran")
	hook := filepath.Join(dir, "fsmonitor")
	write(t, hook, fmt.Sprintf("#!/bin/sh\ntouch '%s'\nprintf '1\\n'\nsleep 8\n", marker))
	if err := os.Chmod(hook, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, r.Root, "config", "core.fsmonitor", hook)

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := r.Status(ctx)
	elapsed := time.Since(start)
	if _, statErr := os.Stat(marker); statErr != nil {
		t.Fatalf("git did not run core.fsmonitor after %s: %v", elapsed, err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("status after %s: %v", elapsed, err)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("status returned after %s, past the deadline", elapsed)
	}
}
