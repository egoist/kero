package git

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// repo makes a repository with a first commit of files, and returns it.
func repo(t *testing.T, files map[string]string) Repo {
	t.Helper()
	if command() == "" {
		t.Skip("no git")
	}
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "init", "-q")
	for name, text := range files {
		write(t, filepath.Join(dir, name), text)
	}
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "first")
	r, err := Open(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStatus(t *testing.T) {
	ctx := context.Background()
	r := repo(t, map[string]string{"a.txt": "one\ntwo\n", "b.txt": "b\n"})
	write(t, filepath.Join(r.Root, "a.txt"), "one\nTWO\nthree\n")
	write(t, filepath.Join(r.Root, "new", "c.txt"), "c1\nc2")
	os.Remove(filepath.Join(r.Root, "b.txt"))

	st, err := r.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Branch != "main" || st.Head == "" || st.Upstream != "" {
		t.Errorf("branch %q head %q upstream %q", st.Branch, st.Head, st.Upstream)
	}
	// a.txt +2 -1, b.txt -1, new/c.txt +2 (untracked, no final newline).
	if st.Files != 3 || st.Added != 4 || st.Removed != 2 {
		t.Errorf("files %d, +%d −%d; want 3, +4 −2", st.Files, st.Added, st.Removed)
	}
	if r.DefaultBranch() != "main" {
		t.Errorf("default branch %q", r.DefaultBranch())
	}
	stamp := r.Stamp(st.Branch)
	gitIn(t, r.Root, "add", "-A")
	if r.Stamp(st.Branch) == stamp {
		t.Error("the stamp stayed as the index changed")
	}
}

func TestTurnChanges(t *testing.T) {
	ctx := context.Background()
	r := repo(t, map[string]string{"a.txt": "one\n", "keep.txt": "k\n"})
	// Dirty before the turn: not the turn's change.
	write(t, filepath.Join(r.Root, "keep.txt"), "k2\n")
	write(t, filepath.Join(r.Root, ".gitignore"), "ignored/\n")
	index, _ := os.ReadFile(filepath.Join(r.GitDir, "index"))

	turn, err := r.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if now, _ := os.ReadFile(filepath.Join(r.GitDir, "index")); string(now) != string(index) {
		t.Fatal("the snapshot changed the index")
	}
	write(t, filepath.Join(r.Root, "a.txt"), "one\ntwo\n")
	write(t, filepath.Join(r.Root, "made.txt"), "m\n")
	write(t, filepath.Join(r.Root, "ignored", "x.txt"), "x\n")

	rev, _, err := r.Base(ctx, BaseTurn, turn)
	if err != nil {
		t.Fatal(err)
	}
	files, err := r.Changes(ctx, rev, "")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]File{}
	for _, f := range files {
		got[f.Path] = f
	}
	if len(got) != 2 || got["a.txt"].Status != "modified" || got["a.txt"].Added != 1 || got["made.txt"].Status != "added" {
		t.Errorf("turn changes %+v; want a.txt modified +1 and made.txt added", files)
	}

	// Since HEAD: keep.txt and .gitignore too.
	rev, name, err := r.Base(ctx, BaseHead, "")
	if err != nil || name != "HEAD" {
		t.Fatal(name, err)
	}
	files, err = r.Changes(ctx, rev, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 4 {
		t.Errorf("changes since HEAD %+v; want 4", files)
	}

	txt, err := r.FileText(ctx, turn, "a.txt", "")
	if err != nil {
		t.Fatal(err)
	}
	if txt.Old != "one\n" || txt.New != "one\ntwo\n" || txt.Binary || txt.Large {
		t.Errorf("text %+v", txt)
	}
	if txt, _ := r.FileText(ctx, turn, "made.txt", ""); txt.Old != "" || txt.New != "m\n" {
		t.Errorf("added file's text %+v", txt)
	}
	if patch, err := r.Patch(ctx, turn, "", "a.txt"); err != nil || !strings.Contains(patch, "+two") {
		t.Errorf("patch %q, %v", patch, err)
	}
	if ok, err := r.Changed(ctx, turn, "a.txt"); !ok || err != nil {
		t.Errorf("a.txt changed: %v, %v", ok, err)
	}
	if ok, err := r.Changed(ctx, turn, "keep.txt"); ok || err != nil {
		t.Errorf("keep.txt changed in the turn: %v, %v", ok, err)
	}
}

func TestBranchBase(t *testing.T) {
	ctx := context.Background()
	r := repo(t, map[string]string{"a.txt": "a\n"})
	gitIn(t, r.Root, "checkout", "-q", "-b", "feature")
	write(t, filepath.Join(r.Root, "f.txt"), "f\n")
	gitIn(t, r.Root, "add", "-A")
	gitIn(t, r.Root, "commit", "-q", "-m", "feature")
	rev, name, err := r.Base(ctx, BaseBranch, "")
	if err != nil || name != "main" {
		t.Fatal(name, err)
	}
	files, err := r.Changes(ctx, rev, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].Path != "f.txt" {
		t.Errorf("branch changes %+v; want f.txt", files)
	}
}

func TestWrite(t *testing.T) {
	r := repo(t, map[string]string{"a.txt": "a\n"})
	full := filepath.Join(r.Root, "a.txt")
	os.Chmod(full, 0o755)
	if err := r.Write("a.txt", Hash([]byte("not it")), "x\n"); err != ErrChanged {
		t.Errorf("a stale write: %v", err)
	}
	if err := r.Write("a.txt", Hash([]byte("a\n")), "b\n"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(full)
	fi, _ := os.Stat(full)
	if string(b) != "b\n" || fi.Mode().Perm() != 0o755 {
		t.Errorf("wrote %q, mode %v", b, fi.Mode())
	}
}

func TestLocal(t *testing.T) {
	r := repo(t, map[string]string{"a.txt": "a\n"})
	outside := t.TempDir()
	os.Symlink(outside, filepath.Join(r.Root, "link"))
	for _, p := range []string{"", "../x", "a/../../x", "/etc/passwd", ".git/config", "link/x", ".GIT/config"} {
		if _, err := r.local(p); err == nil {
			t.Errorf("local(%q) let it through", p)
		}
	}
	for _, p := range []string{"a.txt", "sub/../a.txt", "gone/file.txt"} {
		if _, err := r.local(p); err != nil {
			t.Errorf("local(%q): %v", p, err)
		}
	}
	if _, err := r.FileText(context.Background(), "HEAD", "../outside", ""); err == nil {
		t.Error("FileText read outside the worktree")
	}
}
