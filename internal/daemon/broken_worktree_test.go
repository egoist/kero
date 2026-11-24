package daemon

import (
	"os"
	"path/filepath"
	"testing"

	"kero/internal/proto"
)

// A worktree whose git cannot be read is not "nothing to lose": the
// check says so, the close is refused, and the worktree's work stays —
// not removed as if it held nothing.
func TestBrokenWorktreeIsNotNothingToLose(t *testing.T) {
	d := testDaemon(t)
	repo := gitRepo(t)
	d.projects = []proto.Project{{ID: "pr", Name: "repo", Dir: repo}}
	s, err := d.create(proto.CreateParams{Dir: repo, Worktree: "fix"})
	if err != nil {
		t.Fatal(err)
	}
	// A change in the worktree, which removing it would lose.
	if err := os.WriteFile(filepath.Join(s.Worktree.Path, "b.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The worktree's git is broken: its .git file points nowhere, so the
	// change cannot be counted.
	if err := os.WriteFile(filepath.Join(s.Worktree.Path, ".git"), []byte("gitdir: /nonexistent\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := d.checkWorktree(s.ID); err == nil {
		t.Fatal("a worktree whose git cannot be read is checked as one that holds nothing")
	}
	if err := d.closeSession(proto.CloseParams{ID: s.ID, RemoveWorktree: true}); err == nil {
		t.Error("the close went through as though nothing would be lost")
	}
	if _, err := os.Stat(s.Worktree.Path); err != nil {
		t.Error("the worktree is gone, with the change in it")
	}
}
