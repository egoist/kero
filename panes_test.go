package main

import "testing"

// A drag keeps the keyboard in the pane the user is in, unless that pane
// is a browser: its page takes the mouse capture back when the keyboard
// comes to it, and the drag with it (#394).
func TestKeepsFocus(t *testing.T) {
	a := testApp(t)
	s := a.session("s1")
	if !a.keepsFocus() {
		t.Fatal("a terminal pane does not keep the keyboard through a drag")
	}
	s.Panes[0].URL = "https://example.com"
	if a.keepsFocus() {
		t.Fatal("a browser's page keeps the keyboard through a drag")
	}
	// The pane the user is in decides, not the session's panes: another
	// pane of the same session is a terminal, and keeps the keyboard.
	a.focus["s1"] = "b"
	if !a.keepsFocus() {
		t.Fatal("the focus is not where the user is")
	}
}
