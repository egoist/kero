package main

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

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

// A click without a drag on a divider gives the pane the user is in its
// keyboard back: the press takes it from a browser's page, and the
// pointer letting go gives it back (#398).
func TestHandlePressGivesKeyboardBack(t *testing.T) {
	a := testApp(t)
	s := a.session("s1")
	s.Panes[0].URL = "https://example.com" // the pane the user is in is a browser
	a.focus["s1"] = "a"
	h := a.paneRef("a")
	h.Focus()
	var c *ui.Context
	tt := ui.NewTester(func(ctx *ui.Context) {
		c = ctx
		ui.Column(ctx).Children(func() {
			ui.Box(ctx.Key("pane")).Size(60, 60).Bind(h)
			grip := ui.Box(ctx.Key("grip")).Size(20, 20).Label("grip")
			a.handlePress("div", grip)
		})
	}, 200, 200)
	tt.Frame()
	if !h.FocusWithin(c) {
		t.Fatal("the pane does not have the keyboard")
	}
	r, ok := tt.Find("grip")
	if !ok {
		t.Fatal("the handle is not there")
	}
	x, y := r.X+r.W/2, r.Y+r.H/2
	// The press takes the keyboard from the page.
	tt.Press(x, y)
	tt.Frame()
	if h.FocusWithin(c) {
		t.Fatal("the press did not take the keyboard from the page")
	}
	// The pointer lets go, with no drag in between: the page has the
	// keyboard again.
	tt.Release(x, y)
	tt.Frame()
	if !h.FocusWithin(c) {
		t.Fatal("the page did not get the keyboard back")
	}
}
