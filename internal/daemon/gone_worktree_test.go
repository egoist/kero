package daemon

import (
	"os/exec"
	"strings"
	"testing"

	"kero/internal/proto"
)

// A worktree that is gone already is not a worktree that stays: closing
// the session says so, and the branch goes as it would have.
func TestCloseSessionWithAGoneWorktree(t *testing.T) {
	d := testDaemon(t)
	repo := gitRepo(t)
	d.projects = []proto.Project{{ID: "pr", Name: "repo", Dir: repo}}
	s, err := d.create(proto.CreateParams{Dir: repo, Worktree: "fix"})
	if err != nil {
		t.Fatal(err)
	}
	// The user removed the worktree by hand.
	runGit(t, repo, "worktree", "remove", "--force", s.Worktree.Path)
	if err := d.closeSession(proto.CloseParams{ID: s.ID, RemoveWorktree: true}); err != nil {
		t.Fatalf("closing a session whose worktree is gone: %v", err)
	}
	if out := gitList(t, repo, "branch", "--list", "fix"); strings.TrimSpace(out) != "" {
		t.Errorf("the branch of the closed session stays: %q", out)
	}
}

// gitList runs git in dir and gives what it printed.
func gitList(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}
