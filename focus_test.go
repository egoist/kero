package main

import "testing"

// A pane that goes away by itself, its program exited and kerod closed it,
// hands the keyboard to the pane that took its place (#390).
func TestFocusGone(t *testing.T) {
	a := testApp(t)
	s := a.session("s1")
	a.focus["s1"] = "a"
	a.focusPane("a")
	// The pane a is gone: kerod closed it, and focused b.
	s.Panes = s.Panes[1:]
	s.Focus = "b"
	a.focusGone()
	if a.keyPane != "b" {
		t.Fatalf("the keyboard after the pane a went away: %q, want b", a.keyPane)
	}
	if a.focus["s1"] != "b" {
		t.Fatalf("the focus after the pane a went away: %q, want b", a.focus["s1"])
	}
}
