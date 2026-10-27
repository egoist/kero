package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// gitIn runs git in dir, failing the test when it fails.
func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"}, args...)...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// realPath returns path with its symbolic links resolved, as the temporary
// directory's are on macOS.
func realPath(t *testing.T, path string) string {
	t.Helper()
	p, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRepoRoot(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	tmp := realPath(t, t.TempDir())
	repo := filepath.Join(tmp, "repo")
	if err := os.MkdirAll(filepath.Join(repo, "src", "pkg"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "init", "-q")
	gitIn(t, repo, "commit", "-q", "--allow-empty", "-m", "init")

	lib := filepath.Join(tmp, "lib")
	if err := os.Mkdir(lib, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, lib, "init", "-q")
	gitIn(t, lib, "commit", "-q", "--allow-empty", "-m", "init")
	gitIn(t, repo, "submodule", "add", "-q", lib, "lib")

	gitIn(t, repo, "worktree", "add", "-q", "-b", "inside", filepath.Join(repo, ".claude", "worktrees", "inside"))
	gitIn(t, repo, "worktree", "add", "-q", "-b", "outside", filepath.Join(tmp, "outside"))
	// --relative-paths came in git 2.48.
	relative := filepath.Join(tmp, "relative")
	cmd := exec.Command("git", "worktree", "add", "-q", "--relative-paths", "-b", "relative", relative)
	cmd.Dir = repo
	if cmd.Run() != nil {
		relative = filepath.Join(tmp, "outside")
	}

	bare := filepath.Join(tmp, "bare.git")
	gitIn(t, tmp, "clone", "-q", "--bare", repo, bare)
	gitIn(t, bare, "worktree", "add", "-q", filepath.Join(tmp, "of-bare"), "main")

	plain := filepath.Join(tmp, "plain")
	if err := os.Mkdir(plain, 0o755); err != nil {
		t.Fatal(err)
	}

	for _, c := range []struct{ dir, want string }{
		{repo, repo},
		{filepath.Join(repo, "src", "pkg"), repo},
		{filepath.Join(repo, ".claude", "worktrees", "inside"), repo},
		{filepath.Join(tmp, "outside"), repo},
		{relative, repo},
		// A submodule, and a bare repository's worktree, are roots of their own.
		{filepath.Join(repo, "lib"), filepath.Join(repo, "lib")},
		{filepath.Join(tmp, "of-bare"), filepath.Join(tmp, "of-bare")},
		{plain, plain},
	} {
		if got := repoRoot(c.dir); got != c.want {
			t.Errorf("repoRoot(%s) = %s, want %s", c.dir, got, c.want)
		}
	}
}
