package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"kero/internal/proto"
)

// gitRepo makes a repository with a first commit on main.
func gitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	runGit(t, dir, "init", "-q")
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\n"), 0o644)
	runGit(t, dir, "add", "-A")
	runGit(t, dir, "commit", "-q", "-m", "first")
	return dir
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// A session in a worktree of its own starts there, on its branch from
// the default branch, in the repository's project; closing it keeps the
// worktree unless asked, and removing one that would lose work needs
// Force.
func TestWorktreeSession(t *testing.T) {
	d := testDaemon(t)
	repo := gitRepo(t)
	d.projects = []proto.Project{{ID: "pr", Name: "repo", Dir: repo}}
	s, err := d.create(proto.CreateParams{Dir: repo, Worktree: "fix/login"})
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(repo, ".kero", "worktrees", "fix-login")
	wt := s.Worktree
	if wt == nil || wt.Path != want || wt.Branch != "fix/login" || wt.Base != "main" || wt.Main != repo || s.Project != "pr" {
		t.Fatalf("session %+v, worktree %+v", s, wt)
	}
	if s.Panes[0].Dir != want {
		t.Errorf("the pane starts in %s", s.Panes[0].Dir)
	}
	if _, err := d.create(proto.CreateParams{Dir: repo, Worktree: "fix/login"}); err == nil {
		t.Error("made a second worktree where the first is")
	}
	if _, err := d.create(proto.CreateParams{Dir: repo, Worktree: "a b"}); err == nil {
		t.Error("made a branch of a bad name")
	}
	if _, err := d.create(proto.CreateParams{Dir: t.TempDir(), Worktree: "x"}); err == nil || !strings.Contains(err.Error(), "no git repository") {
		t.Errorf("outside a repository: %v", err)
	}

	os.WriteFile(filepath.Join(want, "b.txt"), []byte("b\n"), 0o644)
	wc, err := d.checkWorktree(s.ID)
	if err != nil || wc.Files != 1 || wc.Shared || !wc.Merged {
		t.Fatalf("check %+v, %v", wc, err)
	}
	if err := d.closeSession(proto.CloseParams{ID: s.ID, RemoveWorktree: true}); err == nil || !strings.Contains(err.Error(), "1 file changed") {
		t.Fatalf("removed a worktree with changes: %v", err)
	}
	if d.findPane(s.Panes[0].ID) == nil {
		t.Fatal("closed the session it refused")
	}
	if err := d.closeSession(proto.CloseParams{ID: s.ID, RemoveWorktree: true, Force: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(want); !os.IsNotExist(err) {
		t.Errorf("the worktree stays: %v", err)
	}

	// Closing alone keeps it; a session working in it shares it.
	s, err = d.create(proto.CreateParams{Dir: repo, Worktree: "docs", Base: "HEAD"})
	if err != nil {
		t.Fatal(err)
	}
	other, err := d.create(proto.CreateParams{Dir: s.Worktree.Path})
	if err != nil {
		t.Fatal(err)
	}
	if wc, _ := d.checkWorktree(s.ID); !wc.Shared {
		t.Error("not shared with a session in it")
	}
	if err := d.closeSession(proto.CloseParams{ID: s.ID, RemoveWorktree: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.Worktree.Path); err != nil {
		t.Errorf("removed a worktree another session works in: %v", err)
	}
	d.removeSession(other.ID)
}

func TestWorktreePath(t *testing.T) {
	main := filepath.FromSlash("/src/kero")
	if got := worktreePath(main, "fix/login", ""); got != filepath.FromSlash("/src/kero/.kero/worktrees/fix-login") {
		t.Error(got)
	}
	if got := worktreePath(main, "x", filepath.FromSlash("/wt")); got != filepath.FromSlash("/wt/kero/x") {
		t.Error(got)
	}
	if got := worktreePath(main, "x", "../trees"); got != filepath.FromSlash("/src/trees/kero/x") {
		t.Error(got)
	}
}
