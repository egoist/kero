package git

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A session's worktree starts on a new branch from its base; what
// removing it would lose counts its changes and the commits nothing else
// has, and removing it deletes its branch only once the base has it.
func TestWorktree(t *testing.T) {
	ctx := context.Background()
	r := repo(t, map[string]string{"a.txt": "a\n"})
	if r.Main() != r.Root {
		t.Fatalf("main %q, root %q", r.Main(), r.Root)
	}
	if err := CheckBranch(ctx, r.Root, "fix/login"); err != nil {
		t.Error(err)
	}
	for _, bad := range []string{"", "-x", "a..b", "a b", "x~1"} {
		if CheckBranch(ctx, r.Root, bad) == nil {
			t.Errorf("%q named a branch", bad)
		}
	}
	path := filepath.Join(r.Root, ".kero", "worktrees", "fix-login")
	if err := r.AddWorktree(ctx, path, "fix/login", "main"); err != nil {
		t.Fatal(err)
	}
	if err := r.Exclude("/.kero/"); err != nil {
		t.Fatal(err)
	}
	r.Exclude("/.kero/")
	if b, _ := os.ReadFile(filepath.Join(r.Common, "info", "exclude")); strings.Count(string(b), "/.kero/") != 1 {
		t.Errorf("exclude:\n%s", b)
	}
	if st, _ := r.Status(ctx); st.Files != 0 {
		t.Errorf("the main checkout shows %d files changed: .kero isn't ignored", st.Files)
	}
	wt, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if wt.Main() != r.Root {
		t.Errorf("the worktree's main checkout %q", wt.Main())
	}
	state := func() WorktreeState {
		t.Helper()
		st, err := wt.State(ctx, "fix/login", "main")
		if err != nil {
			t.Fatal(err)
		}
		return st
	}
	if st := state(); st != (WorktreeState{Merged: true}) {
		t.Errorf("fresh: %+v", st)
	}
	write(t, filepath.Join(path, "b.txt"), "b\n")
	if st := state(); st.Files != 1 || st.Unpushed != 0 {
		t.Errorf("a new file: %+v", st)
	}
	gitIn(t, path, "add", "-A")
	gitIn(t, path, "commit", "-q", "-m", "b")
	if st := state(); st.Files != 0 || st.Unpushed != 1 || st.Merged {
		t.Errorf("a commit: %+v", st)
	}

	// Not merged: the worktree goes, its branch stays.
	if err := RemoveWorktree(ctx, r.Root, path, "fix/login", "main"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("the worktree is still there: %v", err)
	}
	if !r.HasBranch("fix/login") {
		t.Fatal("deleted a branch with commits main doesn't have")
	}

	// Merged: the branch goes too.
	gitIn(t, r.Root, "merge", "-q", "--ff-only", "fix/login")
	if err := r.AddWorktree(ctx, path, "fix/login", ""); err != nil {
		t.Fatal(err)
	}
	if err := RemoveWorktree(ctx, r.Root, path, "fix/login", "main"); err != nil {
		t.Fatal(err)
	}
	if r.HasBranch("fix/login") {
		t.Error("kept a merged branch")
	}
}
