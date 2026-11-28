package daemon

import (
	"testing"

	"kero/internal/proto"
)

// A pane that goes away hands the focus to the pane the user was in
// before it, and not to the neighbor taking its room: the user was in b,
// then in c, and c is gone (#390).
func TestFocusAfterPaneGone(t *testing.T) {
	d := testDaemon(t)
	// a | b, b split with c below it: a | (b over c).
	var l *proto.Layout
	l = l.Split("a", "b", "right", 0)
	l = l.Split("b", "c", "down", 0)
	s := &session{id: "s1", layout: l}
	for _, id := range []string{"a", "b", "c"} {
		p, err := newPane(d, "s1", proto.Pane{ID: id, Status: proto.Idle, Cols: 80, Rows: 24})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { p.term.Close() })
		s.panes = append(s.panes, p)
		d.panes[id] = p
	}
	d.sessions = []*session{s}
	// The user was in b, and then in c.
	s.setFocus("b")
	s.setFocus("c")
	if err := d.removePane("c"); err != nil {
		t.Fatal(err)
	}
	if s.focus != "b" {
		t.Fatalf("the focus after the pane c went away: %q, want b", s.focus)
	}
}

// A pane that goes away with no pane before it leaves the focus to the
// neighbor taking its room (#390).
func TestFocusAfterPaneGoneWithoutPrevious(t *testing.T) {
	d := testDaemon(t)
	var l *proto.Layout
	l = l.Split("a", "b", "right", 0)
	s := &session{id: "s1", layout: l}
	for _, id := range []string{"a", "b"} {
		p, err := newPane(d, "s1", proto.Pane{ID: id, Status: proto.Idle, Cols: 80, Rows: 24})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { p.term.Close() })
		s.panes = append(s.panes, p)
		d.panes[id] = p
	}
	d.sessions = []*session{s}
	s.setFocus("b")
	if err := d.removePane("b"); err != nil {
		t.Fatal(err)
	}
	if s.focus != "a" {
		t.Fatalf("the focus after the pane b went away: %q, want a", s.focus)
	}
}
