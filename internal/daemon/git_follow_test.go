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
