package main

import (
	"testing"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

// The quick terminal's session, with a browser in focus and no terminal
// pane: the panel said nothing, a spinner for ever. It says so now, and a
// terminal pane coming into focus attaches.
func TestQuickTerminalSaysTheFocusedPaneIsABrowser(t *testing.T) {
	a := testApp(t)
	a.prefs.QuickSession = "s1"
	a.st.Sessions[0].Panes[1].URL = proto.BrowserURL("localhost:3000")
	a.st.Sessions[0].Focus = "b"
	a.quick.shown = true
	a.attachQuick()
	if a.quick.err == "" {
		t.Fatal("no word of the browser pane")
	}
	tt := ui.NewTester(a.quickView, 960, 400)
	tt.Frame()
	if !tt.HasText("The pane in focus is a browser") {
		t.Errorf("the browser pane is not said; texts %q", tt.Texts())
	}
	// A terminal pane coming into focus attaches it again.
	a.st.Sessions[0].Focus = "a"
	a.quickChanged()
	if a.quick.err != "" {
		t.Errorf("the word is stale with a terminal pane in focus: %q", a.quick.err)
	}
}
