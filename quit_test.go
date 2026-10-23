package main

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

// quit-ends-sessions, off by default, makes every quit end this machine's
// sessions, asking first while a program runs.
func TestQuitEndsSessions(t *testing.T) {
	a := testApp(t)
	if a.set.QuitEndsSessions {
		t.Fatal("quit-ends-sessions is on by default")
	}

	// A shell alone: the quit is let through, to end the sessions as it
	// goes, not to close the window and leave them.
	a.own(a.local(), a.st.Sessions[0])
	a.local().conn, a.local().loaded = connReady, true
	a.set.QuitEndsSessions = true
	if !a.quitRequested() {
		t.Fatal("a quit of idle sessions was taken back")
	}

	// A program runs: the quit asks, and the question takes a click.
	a = testApp(t)
	a.own(a.local(), a.st.Sessions[0])
	a.local().conn, a.local().loaded = connReady, true
	a.set.QuitEndsSessions, a.st.Sessions[0].Process = true, "claude" // the sessions came
	if a.quitRequested() {
		t.Fatal("a quit that ends a running program went ahead unasked")
	}
	if a.confirm == nil || !a.confirm.ends {
		t.Fatalf("no question that ends programs before the quit: %+v", a.confirm)
	}
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	// Return may be a program's to read: only a click answers it.
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if a.confirm == nil || !a.confirm.open {
		t.Fatalf("Return answered a question that ends programs: %+v", a.confirm)
	}
	tt.Click("End Sessions and Quit")
	tt.Frame()
	if a.confirm != nil {
		t.Fatalf("a click left the question: %+v", a.confirm)
	}

	// The quit the answer makes goes ahead, without asking again, and
	// closes the window.
	if !a.quitRequested() {
		t.Fatal("the quit the answer made was taken back")
	}
	if a.quitting {
		t.Fatal("the quit the answer made was taken back after all")
	}
}

// A quit before the sessions came, whose programs it cannot know, is taken
// back while the app shows them, as it ends them; the quit the window makes
// then goes ahead. A keyboard shortcut reaches the app before it closes
// its windows.
func TestQuitEndsSessionsNotLoaded(t *testing.T) {
	a := testApp(t)
	a.set.QuitEndsSessions = true
	if a.quitRequested() {
		t.Fatal("a quit of sessions the app has not seen went ahead")
	}
	if a.confirm != nil || !a.quitting {
		t.Fatalf("a quit with nothing seen asked a question: %+v, quitting %v", a.confirm, a.quitting)
	}
	if !a.quitRequested() {
		t.Fatal("the quit the window makes after was taken back")
	}
}
