package daemon

import (
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
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
