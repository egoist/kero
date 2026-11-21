package main

import (
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/git"
	"kero/internal/proto"
)

// Two hosts may have a worktree of the same path: their changes are not
// each other's, and the list of one is not the list of the other.
func TestChangesScopeByHost(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	s.Panes[0].Git = &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main"}
	local := a.changesScopeOf(s)
	// A remote host with a worktree of the same path.
	h := &host{name: "box"}
	a.hosts = append(a.hosts, h)
	a.owner = map[string]*host{"a": h}
	remote := a.changesScopeOf(s)
	if local == remote {
		t.Fatalf("the changes of two hosts are one list: %q", local)
	}
}

// The diff of a file is asked of the pane that is in the worktree now: the
// one it was asked of before may be gone, with the session it was in.
func TestChangesPaneRefreshed(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 1, Added: 10}
	s.Panes[0].Git = g
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo", Files: []proto.GitFile{{Path: "a.go", Status: "modified", Added: 1}}}
	ch.fetched = time.Now()
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Frame()
	sf := ch.files[scope+"|a.go"]
	if sf == nil {
		t.Fatal("the file's diff was not asked for")
	}
	if sf.pane != "a" {
		t.Fatalf("the diff is of the pane %q", sf.pane)
	}
	// The session is closed and opened again: the pane is another.
	s.Panes[0].ID, s.Focus = "c", "c"
	tt.Frame()
	tt.Frame()
	if sf.pane != "c" {
		t.Fatalf("the diff is still of the pane %q", sf.pane)
	}
}
