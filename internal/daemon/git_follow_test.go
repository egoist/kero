package daemon

import (
	"io"
	"log"
	"testing"
	"time"

	"kero/internal/git"
	"kero/internal/proto"
)

// A git status that fails is not a stamp the follower took: the stamp it
// recorded of the state it never read kept the stale numbers shown as
// current, and the failure never told. The time of the try still counts —
// a worktree's status is not asked again every second because one ask
// failed — but the stamp is only the one a status answered for.
func TestGitFollowAFailingStatusIsNoStamp(t *testing.T) {
	d := &Daemon{}
	d.log = log.New(io.Discard, "", 0)
	d.quit = make(chan struct{})
	g := newGitFollow(d)

	// A worktree whose git cannot answer: the Root names one that is not
	// there, so Status fails on it. The stamp the look would take next is
	// whatever a live HEAD makes — here a fixed one stands for it.
	rs := &repoStatus{
		repo:  git.Repo{Root: "/nonexistent/worktree", GitDir: "/nonexistent/.git", Common: "/nonexistent/.git"},
		info:  &proto.GitInfo{Root: "/nonexistent/worktree", Branch: "main", Files: 2},
		stamp: "old",
		at:    time.Now().Add(-time.Hour),
	}
	g.refresh(rs, "new", time.Now())
	if rs.stamp == "new" {
		t.Fatalf("a failed status's stamp was taken: %q", rs.stamp)
	}
	if rs.at.IsZero() || time.Since(rs.at) > time.Minute {
		t.Errorf("the failed try was not counted: at %v", rs.at)
	}
	if rs.info == nil || rs.info.Files != 2 {
		t.Errorf("the last good info was dropped: %+v", rs.info)
	}
}

// A failing repository is not asked of again on the next look: a status
// that cannot answer is backed off to the working step, not asked of
// every second.
func TestGitFollowAFailingRepositoryBacksOff(t *testing.T) {
	p := testPane(t)
	d := p.d
	d.log = log.New(io.Discard, "", 0)
	d.quit = make(chan struct{})
	d.panes = map[string]*pane{"p": p}
	d.git = newGitFollow(d)
	// A pane in a worktree of its own, whose git cannot answer: the Root
	// names one that is not there, so Status fails on it — but repoOf
	// still points the pane's directory at it.
	repo := git.Repo{Root: "/nonexistent/worktree", GitDir: "/nonexistent/.git", Common: "/nonexistent/.git"}
	p.info.Dir = repo.Root
	rs := &repoStatus{
		repo:  repo,
		info:  &proto.GitInfo{Root: repo.Root, Branch: "main", Files: 1},
		stamp: "old",
		at:    time.Now().Add(-time.Hour),
	}
	d.git.mu.Lock()
	d.git.repos[repo.Root] = rs
	d.git.dirs[repo.Root] = dirRepo{repo: repo, at: time.Now()}
	d.git.mu.Unlock()

	// The first look asks, and fails: the time of the try counts, and the
	// failure is marked.
	now := time.Now()
	d.git.look(now)
	if !rs.failed {
		t.Fatal("the failed ask was not marked")
	}
	first := rs.at
	if first.Before(now.Add(-time.Second)) {
		t.Fatalf("the failed try was not counted: at %v, want it near %v", first, now)
	}

	// The look two seconds later asks the same due rule of the follower:
	// the stamp did not move, and the failure is backed off, so the
	// worktree's ask is refused — its time does not advance.
	d.git.look(now.Add(2 * time.Second))
	if rs.at.After(first) {
		t.Errorf("a failing repository was asked of again: at %v, want it left at %v", rs.at, first)
	}

	// Past the working step the ask is taken again, as a repository that
	// failed is not given up on.
	d.git.look(now.Add(gitWorkingStep + time.Second))
	if !rs.at.After(first) {
		t.Errorf("a failing repository was never asked of again: at %v, want it past %v", rs.at, first)
	}
}
