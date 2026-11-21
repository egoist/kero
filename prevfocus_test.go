package main

import (
	"testing"

	"kero/internal/proto"
)

// Closing a pane focuses the pane the user was in before it, and not the
// neighbor taking its room: the user was in b, then in c, and c is closed
// (#390).
func TestCloseFocusesPrevious(t *testing.T) {
	a := testApp(t)
	// a | b, b split with c below it: a | (b over c).
	var l *proto.Layout
	l = l.Split("a", "b", "right", 0)
	l = l.Split("b", "c", "down", 0)
	s := &a.st.Sessions[0]
	s.Panes = append(s.Panes, proto.Pane{ID: "c", Shell: "zsh", Dir: "/tmp", Status: proto.Idle, Progress: -1})
	s.Layout = l
	s.Focus = "a"
	// The user was in b, and then in c.
	a.setFocus(s, "b")
	a.setFocus(s, "c")
	a.closePane(s, "c", false)
	if got := a.focusOf(s); got != "b" {
		t.Fatalf("the focus after closing the pane c: %q, want b", got)
	}
}

// With the window in the background no pane is the one the user is in, and
// with it in the foreground the pane the user was in is again (#390).
func TestPaneFocused(t *testing.T) {
	a := testApp(t)
	s := a.session("s1")
	a.focus["s1"] = "a"
	a.focused = false
	if a.paneFocused(s, &s.Panes[0]) {
		t.Fatal("a pane is focused with the window in the background")
	}
	a.focused = true
	if !a.paneFocused(s, &s.Panes[0]) {
		t.Fatal("the pane the user is in is not focused with the window in the foreground")
	}
	if a.paneFocused(s, &s.Panes[1]) {
		t.Fatal("a pane the user is not in is focused")
	}
}
