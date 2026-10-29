package main

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

// The label printed by an agent need not contain the file path: the
// terminal passes the destination of its OSC 8 link to the app.
func TestDocumentHyperlinkClick(t *testing.T) {
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	a.set.OpenDocumentLinks = true
	link := testDocumentURL(filepath.Join(t.TempDir(), "concepts.html"))
	calls := make(chan proto.CreateParams, 1)
	a.local().cl, _ = projectClient(t, func(_ string, raw json.RawMessage) (any, error) {
		var p proto.CreateParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		calls <- p
		return proto.Session{ID: "s1"}, nil
	})
	term, err := terminal.New(terminal.Options{Conn: idleConn{make(chan struct{})}, OpenLink: func(dest string) bool { return a.openLink("a", dest) }})
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	term.Feed([]byte("\x1b]8;;" + link + "\x1b\\Open the interactive HTML concepts\x1b]8;;\x1b\\\r\n"))
	a.terms["a"] = &termEntry{term: term}
	tt := ui.NewTester(a.view, 1400, 900)
	tt.Frame()
	bounds, ok := tt.Find("Terminal")
	if !ok {
		t.Fatal("no terminal")
	}
	clicked := false
find:
	for y := bounds.Y; y < bounds.Y+40; y += 4 {
		for x := bounds.X; x < bounds.X+bounds.W/2; x += 3 {
			tt.Move(x, y)
			tt.HoldModifiers(ui.Cmd)
			if dest, _, _ := term.HoveredLink(); dest == link {
				tt.ClickAtWith(ui.Cmd, x, y)
				tt.Frame()
				clicked = true
				break find
			}
		}
	}
	if !clicked {
		t.Fatal("could not click the agent's labeled hyperlink")
	}
	select {
	case got := <-calls:
		if got.Split != "a" || got.URL != link {
			t.Fatalf("hyperlink opened %+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("clicking the labeled hyperlink did not open a document split")
	}
}
