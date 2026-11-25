package daemon

import (
	"bytes"
	"context"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kero/internal/git"
	"kero/internal/proto"
)

// A pane in a repository has its branch and changes, which stay the same
// value until they change; an agent going to work starts a turn, whose
// changes the panel shows, and whose edits can be reverted once it stops.
func TestGitFollow(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	p := testPane(t)
	d := p.d
	d.log = log.New(io.Discard, "", 0)
	d.quit = make(chan struct{})
	d.panes = map[string]*pane{"p": p}
	d.git = newGitFollow(d)

	repo := realPath(t, t.TempDir())
	gitIn(t, repo, "init", "-q")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\n"), 0o644)
	gitIn(t, repo, "add", "-A")
	gitIn(t, repo, "commit", "-q", "-m", "first")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\n"), 0o644)
	p.info.Dir = repo

	now := time.Now()
	d.git.look(now)
	g := p.info.Git
	if g == nil || g.Root != repo || g.Branch != "main" || g.Default != "main" || g.Files != 1 || g.Added != 1 {
		t.Fatalf("git info %+v", g)
	}
	d.git.look(now.Add(time.Second))
	if p.info.Git != g {
		t.Error("the info was replaced with nothing changed")
	}

	// The agent's turn: a snapshot of the worktree as it starts.
	p.mu.Lock()
	p.info.Agent = "claude"
	p.setStatus(proto.Working)
	p.mu.Unlock()
	for deadline := time.Now().Add(10 * time.Second); ; {
		p.mu.Lock()
		turn := p.info.Turn
		p.mu.Unlock()
		if turn != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no turn")
		}
		time.Sleep(20 * time.Millisecond)
	}
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\nthree\n"), 0o644)
	ch, err := d.gitChanges(proto.GitParams{Pane: "p", Base: git.BaseTurn})
	if err != nil {
		t.Fatal(err)
	}
	if len(ch.Files) != 1 || ch.Files[0].Path != "a.txt" || ch.Files[0].Added != 1 {
		t.Fatalf("turn changes %+v", ch)
	}
	txt, err := d.gitText(proto.GitParams{Pane: "p", Base: git.BaseTurn, Path: "a.txt"})
	if err != nil || txt.Old != "one\ntwo\n" || txt.New != "one\ntwo\nthree\n" {
		t.Fatalf("text %+v, %v", txt, err)
	}
	if same, _ := d.gitText(proto.GitParams{Pane: "p", Base: git.BaseTurn, Path: "a.txt", Known: txt.Hash}); !same.Same || same.New != "" {
		t.Errorf("a known text sent again: %+v", same)
	}

	revert := proto.GitWriteParams{Pane: "p", Base: git.BaseTurn, Path: "a.txt", Hash: txt.Hash, Text: txt.Old}
	if _, err := d.gitRevert(revert); err == nil {
		t.Error("reverted under a working agent")
	}
	p.mu.Lock()
	p.setStatus(proto.Idle)
	p.mu.Unlock()
	if _, err := d.gitRevert(proto.GitWriteParams{Pane: "p", Base: git.BaseTurn, Path: "../x", Hash: txt.Hash, Text: "x"}); err == nil {
		t.Error("wrote outside the worktree")
	}
	if hash, err := d.gitRevert(revert); err != nil || hash != git.Hash([]byte(txt.Old)) {
		t.Fatal(hash, err)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "a.txt")); string(b) != "one\ntwo\n" {
		t.Errorf("reverted to %q", b)
	}
	if _, err := d.gitRevert(revert); err == nil {
		t.Error("reverted a file with no changes, or one changed since shown")
	}
}

// A revert, as a file written, has the pane's worktree show its changes
// anew at once — also for a pane in a directory of it, not the root
// itself, which is not a directory a refresh is asked of.
func TestRevertPokesThePane(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	p := testPane(t)
	d := p.d
	d.log = log.New(io.Discard, "", 0)
	d.quit = make(chan struct{})
	d.panes = map[string]*pane{"p": p}
	d.git = newGitFollow(d)

	repo := gitRepo(t)
	sub := filepath.Join(repo, "sub")
	os.Mkdir(sub, 0o755)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("a\nb\n"), 0o644)
	p.info.Dir = sub

	now := time.Now()
	d.git.look(now)
	if g := p.info.Git; g == nil || g.Files != 1 || g.Added != 1 {
		t.Fatalf("the change shows: %+v", g)
	}
	txt, err := d.gitText(proto.GitParams{Pane: "p", Path: "a.txt"})
	if err != nil || txt.New != "a\nb\n" || txt.Old != "a\n" {
		t.Fatalf("text %+v, %v", txt, err)
	}
	if _, err := d.gitRevert(proto.GitWriteParams{Pane: "p", Path: "a.txt", Hash: txt.Hash, Text: txt.Old}); err != nil {
		t.Fatal(err)
	}
	d.git.look(now.Add(time.Second))
	if g := p.info.Git; g == nil || g.Files != 0 {
		t.Errorf("the pane is not told the revert: %+v", g)
	}
}

// A change of a file's mode is a change to revert: the revert puts the
// mode back with the text, and the file shows as it was.
func TestRevertPutsBackTheMode(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	p := testPane(t)
	d := p.d
	d.log = log.New(io.Discard, "", 0)
	d.panes = map[string]*pane{"p": p}
	repo := realPath(t, t.TempDir())
	gitIn(t, repo, "init", "-q")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\n"), 0o644)
	gitIn(t, repo, "add", "-A")
	gitIn(t, repo, "commit", "-q", "-m", "first")
	p.info.Dir = repo
	full := filepath.Join(repo, "a.txt")
	// The file is made to run: the bytes are as they were.
	if err := os.Chmod(full, 0o755); err != nil {
		t.Fatal(err)
	}
	txt, err := d.gitText(proto.GitParams{Pane: "p", Base: git.BaseHead, Path: "a.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.gitRevert(proto.GitWriteParams{Pane: "p", Base: git.BaseHead, Path: "a.txt", Hash: txt.Hash, Text: txt.Old}); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(full)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o644 {
		t.Errorf("the mode after the revert: %v", fi.Mode())
	}
	r, err := git.Open(context.Background(), repo)
	if err != nil {
		t.Fatal(err)
	}
	changed, err := r.Changed(context.Background(), "HEAD", "a.txt")
	if err != nil || changed {
		t.Errorf("the file after the revert: changed=%v, %v", changed, err)
	}
}

// A status that cannot be read is said, as the worktree's own finding is:
// the numbers the pane shows stay as they were, and nothing would say why
// they never move again. A directory that holds no worktree is not a
// failure to say.
func TestGitStatusThatFailedIsSaid(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	var logs bytes.Buffer
	p := testPane(t)
	d := p.d
	d.log = log.New(&logs, "", 0)
	g := newGitFollow(d)

	// A folder with no worktree of its own: the common case.
	plain := realPath(t, t.TempDir())
	rs := &repoStatus{repo: git.Repo{Root: plain}}
	g.refresh(rs, rs.repo.Stamp(""), time.Now())
	if !rs.failed {
		t.Fatal("a folder with no worktree was read as a status")
	}
	if logs.Len() != 0 {
		t.Errorf("a folder with no worktree was said: %q", logs.String())
	}

	// One that is there but cannot be read is said, with its root.
	notADir := filepath.Join(plain, "not-a-folder")
	if err := os.WriteFile(notADir, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	rs = &repoStatus{repo: git.Repo{Root: notADir}}
	g.refresh(rs, rs.repo.Stamp(""), time.Now())
	if !rs.failed {
		t.Fatal("a worktree that could not be read was read as a status")
	}
	if !strings.Contains(logs.String(), notADir) {
		t.Errorf("a status that failed was not said: %q", logs.String())
	}
}

// Reverting a hunk of a renamed file writes to its current name.
func TestRevertHunkOfRenamedFile(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	p := testPane(t)
	d := p.d
	d.log = log.New(io.Discard, "", 0)
	d.panes = map[string]*pane{"p": p}
	repo := realPath(t, t.TempDir())
	gitIn(t, repo, "init", "-q")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\n"), 0o644)
	gitIn(t, repo, "add", "-A")
	gitIn(t, repo, "commit", "-q", "-m", "first")
	p.info.Dir = repo
	// The agent renamed the file.
	if err := os.Rename(filepath.Join(repo, "a.txt"), filepath.Join(repo, "b.txt")); err != nil {
		t.Fatal(err)
	}
	txt, err := d.gitText(proto.GitParams{Pane: "p", Base: git.BaseHead, Path: "b.txt", OldPath: "a.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.gitRevert(proto.GitWriteParams{Pane: "p", Base: git.BaseHead, Path: "b.txt", OldPath: "a.txt", Hash: txt.Hash, Text: txt.Old}); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(repo, "b.txt")); err != nil || string(b) != "one\n" {
		t.Errorf("current file: %q, %v", b, err)
	}
	if _, err := os.Stat(filepath.Join(repo, "a.txt")); !os.IsNotExist(err) {
		t.Errorf("old name unexpectedly restored: %v", err)
	}
}
