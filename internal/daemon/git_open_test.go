package daemon

import (
	"bytes"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// A git that cannot be read is said: repoOf and snapshot dropped
// git.Open's error whole, so a pane in a worktree whose .git pointed
// nowhere was never followed, and never told why. A directory no
// worktree holds — a plain folder — is the common case and stays quiet,
// or every plain-directory pane would fill the log once a half minute.
func TestGitFollowSaysAGitThatCannotBeRead(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	var buf bytes.Buffer
	p := testPane(t)
	d := p.d
	d.log = log.New(&buf, "", 0)
	d.quit = make(chan struct{})
	d.git = newGitFollow(d)

	// A plain directory, outside any repository: quiet.
	plain := realPath(t, t.TempDir())
	if r := d.git.repoOf(plain, time.Now(), false); r.Root != "" {
		t.Fatalf("a plain directory was taken for the worktree %q", r.Root)
	}
	if buf.Len() != 0 {
		t.Errorf("a plain directory was said: %s", buf.String())
	}

	// A directory that is gone: quiet too — git cannot look in it, which
	// for finding a worktree is as good as none.
	gone := filepath.Join(plain, "gone")
	if r := d.git.repoOf(gone, time.Now(), false); r.Root != "" {
		t.Fatalf("a gone directory was taken for the worktree %q", r.Root)
	}
	if buf.Len() != 0 {
		t.Errorf("a gone directory was said: %s", buf.String())
	}

	// A broken worktree, whose .git file points nowhere: said, as its
	// status's own failures are.
	broken := realPath(t, t.TempDir())
	if err := os.WriteFile(filepath.Join(broken, ".git"), []byte("gitdir: /nonexistent\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	buf.Reset()
	if r := d.git.repoOf(broken, time.Now(), false); r.Root != "" {
		t.Fatalf("a broken worktree was taken for one: %q", r.Root)
	}
	if !bytes.Contains(buf.Bytes(), []byte(broken)) {
		t.Errorf("a broken worktree was not said: %q", buf.String())
	}

	// The snapshot's side of the same split.
	buf.Reset()
	d.git.snapshot(p, plain, time.Now())
	if buf.Len() != 0 {
		t.Errorf("a snapshot of a plain directory was said: %s", buf.String())
	}
	buf.Reset()
	d.git.snapshot(p, broken, time.Now())
	if !bytes.Contains(buf.Bytes(), []byte("snapshot")) {
		t.Errorf("a snapshot of a broken worktree was not said: %q", buf.String())
	}
}
