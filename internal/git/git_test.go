package git

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
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

// A git that fails is a failure, not a file that is not in the rev: the
// diff of a file that is there showed the whole file as new, and a file
// that was clean looked changed, both without an error.
func TestGitFailureIsNotAFileThatIsNotThere(t *testing.T) {
	r := repo(t, map[string]string{"a.txt": "one\n"})
	write(t, filepath.Join(r.Root, "a.txt"), "two\n")
	// A context that is done: git fails at once, as it does when the
	// daemon's fifteen seconds are up.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	text, err := r.FileText(ctx, "HEAD", "a.txt", "")
	if err == nil {
		t.Errorf("the text of the file: %+v", text)
	}
	changed, err := r.Changed(ctx, "HEAD", "a.txt")
	if err == nil {
		t.Errorf("the file looks changed: %v", changed)
	}
	// A file that is not in the rev is not a failure: it was added.
	write(t, filepath.Join(r.Root, "new.txt"), "new\n")
	text, err = r.FileText(context.Background(), "HEAD", "new.txt", "")
	if err != nil {
		t.Fatal(err)
	}
	if text.Old != "" || text.New != "new\n" {
		t.Errorf("a file that was added: %+v", text)
	}
	changed, err = r.Changed(context.Background(), "HEAD", "new.txt")
	if err != nil || !changed {
		t.Errorf("a file that was added is changed: %v, %v", changed, err)
	}
	// The words that tell a file that is not in the rev are git's English
	// ones, which the call is given LC_ALL=C for: a git of another locale
	// says them otherwise, and every file that was added would read as a
	// failure.
	t.Setenv("LANG", "de_DE.UTF-8")
	t.Setenv("LANGUAGE", "de")
	t.Setenv("LC_MESSAGES", "de_DE.UTF-8")
	text, err = r.FileText(context.Background(), "HEAD", "new.txt", "")
	if err != nil {
		t.Errorf("the text of a file that was added, in another locale: %v", err)
	}
	if text.Old != "" || text.New != "new\n" {
		t.Errorf("a file that was added, in another locale: %+v", text)
	}
	changed, err = r.Changed(context.Background(), "HEAD", "new.txt")
	if err != nil || !changed {
		t.Errorf("a file that was added, in another locale, is changed: %v, %v", changed, err)
	}
	// A failure is a failure there too.
	ctx2, cancel2 := context.WithCancel(context.Background())
	cancel2()
	if _, err := r.FileText(ctx2, "HEAD", "a.txt", ""); err == nil {
		t.Error("the text of the file, in another locale: no error")
	}
	if _, err := r.Changed(ctx2, "HEAD", "a.txt"); err == nil {
		t.Error("the file looks changed, in another locale: no error")
	}
	// A git that says it in its own language says nothing that is read:
	// the calls are given LC_ALL=C, so that git says it in English.
	if notInRev(errors.New("git cat-file: fatal: Pfad 'x' existiert nicht in 'HEAD'")) {
		t.Error("a message of another language reads as a file that is not there")
	}
}

// The patch of a file too big to show whole, when it cannot be made: a
// failure, not an empty patch.
func TestFileTextSaysThePatchFailed(t *testing.T) {
	r := repo(t, map[string]string{"big.txt": "small\n", "other.txt": "x\n"})
	write(t, filepath.Join(r.Root, "big.txt"), strings.Repeat("x", 1<<20+1))
	if err := os.Chmod(filepath.Join(r.Root, "other.txt"), 0o000); err != nil {
		t.Fatal(err)
	}
	// On a system where a file with no read permission is still read
	// (as root, or on Windows), the patch is made, and there is no
	// failure to say.
	if f, err := os.Open(filepath.Join(r.Root, "other.txt")); err == nil {
		f.Close()
		t.Skip("a file with no read permission is still read")
	}
	if text, err := r.FileText(context.Background(), "HEAD", "big.txt", ""); err == nil {
		t.Errorf("the patch of the file too big to show: %+v", text)
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

// A change of a file's mode is a change, as git shows it, though the
// file's bytes are as they were.
func TestChangedSeesAModeChange(t *testing.T) {
	r := repo(t, map[string]string{"f.txt": "line\n"})
	if err := os.Chmod(filepath.Join(r.Root, "f.txt"), 0o755); err != nil {
		t.Fatal(err)
	}
	// On a system where a file's mode is not kept — Windows, or a
	// filesystem with no permissions — git sees no change either.
	if out := gitIn(t, r.Root, "status", "--porcelain"); out == "" {
		t.Skip("the mode is not tracked here")
	}
	if changed, err := r.Changed(context.Background(), "HEAD", "f.txt"); err != nil || !changed {
		t.Errorf("a change of the mode: %v, %v", changed, err)
	}
	if err := os.Chmod(filepath.Join(r.Root, "f.txt"), 0o644); err != nil {
		t.Fatal(err)
	}
	if changed, err := r.Changed(context.Background(), "HEAD", "f.txt"); err != nil || changed {
		t.Errorf("the mode as it was: %v, %v", changed, err)
	}
}

// git records only the execute bit: a revert takes it from the rev and
// leaves the rest of the file's mode as it is.
func TestRevertKeepsTheRestOfTheMode(t *testing.T) {
	r := repo(t, map[string]string{"a.txt": "one\n"})
	full := filepath.Join(r.Root, "a.txt")
	// A group-writable file, made to run.
	if err := os.Chmod(full, 0o774); err != nil {
		t.Fatal(err)
	}
	if err := r.Revert(context.Background(), "HEAD", "a.txt", "", Hash([]byte("one\n")), "one\n"); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(full)
	if err != nil {
		t.Fatal(err)
	}
	// The rev has no execute bit (100644), so the +x goes; the group
	// write is not git's to take.
	if fi.Mode().Perm() != 0o664 {
		t.Errorf("the mode after the revert: %v", fi.Mode())
	}
}

// A file the agent deleted, reverted: written anew as the rev has it.
func TestRevertRestoresADeletedFile(t *testing.T) {
	r := repo(t, map[string]string{"a.txt": "one\n"})
	full := filepath.Join(r.Root, "a.txt")
	if err := os.Remove(full); err != nil {
		t.Fatal(err)
	}
	// The hash the diff shows of a file that is not there: the empty
	// content's.
	if err := r.Revert(context.Background(), "HEAD", "a.txt", "", Hash(nil), "one\n"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(full)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "one\n" {
		t.Errorf("restored %q", b)
	}
	fi, err := os.Stat(full)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o644 {
		t.Errorf("the mode of the file written anew: %v", fi.Mode())
	}
	// One changed meanwhile is asked about, as a write is.
	if err := os.Remove(full); err != nil {
		t.Fatal(err)
	}
	if err := r.Revert(context.Background(), "HEAD", "a.txt", "", Hash([]byte("other\n")), "one\n"); err != ErrChanged {
		t.Errorf("a file that went another way: %v", err)
	}
}

// A file the agent added, reverted: taken away, as the rev has none.
func TestRevertRemovesAFileNotInTheRev(t *testing.T) {
	r := repo(t, map[string]string{"a.txt": "one\n"})
	write(t, filepath.Join(r.Root, "new.txt"), "new\n")
	if err := r.Revert(context.Background(), "HEAD", "new.txt", "", Hash([]byte("new\n")), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(r.Root, "new.txt")); !os.IsNotExist(err) {
		t.Errorf("the file the rev does not have stays: %v", err)
	}
	// One changed meanwhile is asked about, as a write is.
	write(t, filepath.Join(r.Root, "new.txt"), "other\n")
	if err := r.Revert(context.Background(), "HEAD", "new.txt", "", Hash([]byte("new\n")), ""); err != ErrChanged {
		t.Errorf("a file that went another way: %v", err)
	}
}

// Reverting a hunk of a renamed file keeps its current name and other edits.
func TestRevertHunkOfRenamedFile(t *testing.T) {
	r := repo(t, map[string]string{"a.txt": "one\n"})
	if err := os.Rename(filepath.Join(r.Root, "a.txt"), filepath.Join(r.Root, "b.txt")); err != nil {
		t.Fatal(err)
	}
	// The rev has no file at that name: nothing is written, and nothing
	// is taken away.
	if err := r.Revert(context.Background(), "HEAD", "b.txt", "c.txt", Hash([]byte("one\n")), "one\n"); err == nil {
		t.Error("reverted a rename the rev does not have")
	}
	if _, err := os.Stat(filepath.Join(r.Root, "b.txt")); err != nil {
		t.Errorf("the file the rev does not have is taken away: %v", err)
	}
	// The result of reverting one hunk can still contain another edit.
	if err := r.Revert(context.Background(), "HEAD", "b.txt", "a.txt", Hash([]byte("one\n")), "one\nother edit\n"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(r.Root, "b.txt"))
	if err != nil || string(b) != "one\nother edit\n" {
		t.Fatalf("current file: %q, %v", b, err)
	}
	if _, err := os.Stat(filepath.Join(r.Root, "a.txt")); !os.IsNotExist(err) {
		t.Errorf("old name unexpectedly restored: %v", err)
	}
	// One changed meanwhile is asked about, as a write is.
	write(t, filepath.Join(r.Root, "b.txt"), "other\n")
	if err := r.Revert(context.Background(), "HEAD", "b.txt", "a.txt", Hash([]byte("one\n")), "one\n"); err != ErrChanged {
		t.Errorf("a file that went another way: %v", err)
	}
	// The rev has a file under both names: it is not a rename, and the
	// file is put back under the name it has now.
	r2 := repo(t, map[string]string{"a.txt": "one\n", "b.txt": "two\n"})
	if err := r2.Revert(context.Background(), "HEAD", "b.txt", "a.txt", Hash([]byte("two\n")), "one\n"); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(r2.Root, "b.txt")); err != nil || string(b) != "one\n" {
		t.Errorf("reverted to %q, %v", b, err)
	}
	if b, err := os.ReadFile(filepath.Join(r2.Root, "a.txt")); err != nil || string(b) != "one\n" {
		t.Errorf("the other file is written: %q, %v", b, err)
	}
}

// A file that is not there is the empty content to a write: one over a
// file deleted since it was read is asked about, and one of the empty
// content's hash writes it anew.
func TestWriteFileOverADeletedFile(t *testing.T) {
	dir := t.TempDir()
	full := filepath.Join(dir, "f.txt")
	if err := WriteFile(full, Hash([]byte("read\n")), "text\n"); err != ErrChanged {
		t.Errorf("a file that is not there, with the hash of one that was: %v", err)
	}
	if err := WriteFile(full, Hash(nil), "text\n"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(full)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "text\n" {
		t.Errorf("wrote %q", b)
	}
}

// NoWorktree tells "there is no worktree to follow" — git itself not
// installed, a directory outside a repository, a bare one, or gone —
// from git's other failures: the common case for a pane's directory,
// which a caller that only wanted to know keeps quiet about.
func TestNoWorktree(t *testing.T) {
	for _, err := range []error{
		ErrNoGit,
		fmt.Errorf("git rev-parse: %w", ErrNoGit),
		// A directory that is gone fails the chdir before git runs.
		fmt.Errorf("git rev-parse: %w", &fs.PathError{Op: "chdir", Path: "/gone", Err: fs.ErrNotExist}),
		errors.New("git rev-parse: exit status 128: fatal: not a git repository (or any of the parent directories): .git"),
		errors.New("git rev-parse: exit status 128: fatal: not a git repository (or any parent up to mount point /)"),
		errors.New("git rev-parse: exit status 128: fatal: this operation must be run in a work tree"),
	} {
		if !NoWorktree(err) {
			t.Errorf("%v was not the answer for no worktree", err)
		}
	}
	for _, err := range []error{
		// A .git file pointing nowhere names a gitdir: a read that failed.
		errors.New("git rev-parse: exit status 128: fatal: not a git repository: /nonexistent"),
		errors.New("git rev-parse: context deadline exceeded"),
		// A directory that is there but cannot be entered is said.
		fmt.Errorf("git rev-parse: %w", &fs.PathError{Op: "chdir", Path: "/locked", Err: fs.ErrPermission}),
	} {
		if NoWorktree(err) {
			t.Errorf("%v was taken for no worktree", err)
		}
	}
	if NoWorktree(nil) {
		t.Error("no error was taken for no worktree")
	}
}
