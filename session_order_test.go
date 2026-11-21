package main

import (
	"encoding/json"
	"slices"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

func sessionIDs(ss []proto.Session) []string {
	ids := make([]string, len(ss))
	for i, s := range ss {
		ids[i] = s.ID
	}
	return ids
}

// A group's sessions move among the places they had, the other groups'
// staying where they are.
func TestReorderSessions(t *testing.T) {
	all := []proto.Session{
		{ID: "a1", Project: "p1"},
		{ID: "b1", Project: "p2"},
		{ID: "a2", Project: "p1"},
		{ID: "a3", Project: "p1"},
		{ID: "b2", Project: "p2"},
	}
	mine := func(s proto.Session) bool { return s.Project == "p1" }
	for _, tc := range []struct {
		id    string
		index int
		want  []string
	}{
		{"a3", 0, []string{"a3", "b1", "a1", "a2", "b2"}},
		{"a1", 2, []string{"a2", "b1", "a3", "a1", "b2"}},
		{"a1", 99, []string{"a2", "b1", "a3", "a1", "b2"}},
		{"a2", -3, []string{"a2", "b1", "a1", "a3", "b2"}},
		{"zz", 0, []string{"a1", "b1", "a2", "a3", "b2"}},
	} {
		got := sessionIDs(reorderSessions(all, tc.id, tc.index, mine))
		if !slices.Equal(got, tc.want) {
			t.Errorf("move %s to %d: %v, want %v", tc.id, tc.index, got, tc.want)
		}
	}
	if got := sessionIDs(all); !slices.Equal(got, []string{"a1", "b1", "a2", "a3", "b2"}) {
		t.Errorf("the sessions given changed: %v", got)
	}
}

// orderSessions is the app with three sessions of one project, and a kerod
// that records the sessions moved.
func orderSessions(t *testing.T) (*App, chan proto.MoveParams) {
	t.Helper()
	a := testApp(t)
	a.st = proto.State{
		Projects: []proto.Project{{ID: "p1", Name: "alpha", Dir: "/tmp/alpha"}},
		Sessions: []proto.Session{
			{ID: "s1", Project: "p1", Name: "api", Panes: []proto.Pane{{ID: "a", Shell: "zsh", Dir: "/tmp/alpha", Status: proto.Idle, Progress: -1}}, Focus: "a"},
			{ID: "s2", Project: "p1", Name: "web", Panes: []proto.Pane{{ID: "b", Shell: "zsh", Dir: "/tmp/alpha", Status: proto.Idle, Progress: -1}}, Focus: "b"},
			{ID: "s3", Project: "p1", Name: "docs", Panes: []proto.Pane{{ID: "c", Shell: "zsh", Dir: "/tmp/alpha", Status: proto.Idle, Progress: -1}}, Focus: "c"},
		},
	}
	a.selected = "s1"
	a.local().conn = connReady
	a.terms["a"], a.terms["b"], a.terms["c"] = &termEntry{}, &termEntry{}, &termEntry{}
	moved := make(chan proto.MoveParams, 4)
	a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method == "move" {
			var p proto.MoveParams
			json.Unmarshal(raw, &p)
			moved <- p
		}
		return true, nil
	})
	return a, moved
}

func wantMovedSession(t *testing.T, moved chan proto.MoveParams, want proto.MoveParams) {
	t.Helper()
	select {
	case got := <-moved:
		if got != want {
			t.Errorf("kerod was asked to move %+v, want %+v", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Errorf("kerod was not asked to move %+v", want)
	}
}

// Dragging a session's row above another's moves it there, at once in the
// sidebar and in kerod, which keeps the order.
func TestDragSessionInSidebar(t *testing.T) {
	a, moved := orderSessions(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	docs, ok := tt.Find("docs")
	if !ok {
		t.Fatalf("no row of docs; texts %q", tt.Texts())
	}
	api, _ := tt.Find("api")
	x, y := docs.X+docs.W/2, docs.Y+docs.H/2
	// Above api's middle: before it.
	tx, ty := api.X+api.W/2, api.Y+2
	tt.Press(x, y)
	for i := 1; i <= 12; i++ {
		f := float32(i) / 12
		tt.Move(x+(tx-x)*f, y+(ty-y)*f)
		tt.Advance(16 * time.Millisecond)
		tt.Frame()
	}
	tt.Advance(200 * time.Millisecond)
	tt.Frame()
	if a.sessMove.id != "s3" || a.sessMove.at != 0 {
		t.Errorf("dragging docs over api's top: %+v, want s3 going to 0", a.sessMove)
	}
	shot(t, tt, "session-drag")
	tt.Release(tx, ty)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	if got := sessionIDs(a.st.Sessions); !slices.Equal(got, []string{"s3", "s1", "s2"}) {
		t.Errorf("after the drop, sessions %v, want s3 s1 s2", got)
	}
	wantMovedSession(t, moved, proto.MoveParams{ID: "s3", Index: 0})
}

// Dragged to where it is, a session stays, and kerod hears nothing.
func TestDragSessionInPlace(t *testing.T) {
	a, moved := orderSessions(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	web, _ := tt.Find("web")
	x, y := web.X+web.W/2, web.Y+web.H/2
	tt.Press(x, y)
	for i := 1; i <= 8; i++ {
		tt.Move(x, y+float32(i))
		tt.Advance(16 * time.Millisecond)
		tt.Frame()
	}
	tt.Release(x, y+8)
	tt.Frame()
	tt.Frame()
	if got := sessionIDs(a.st.Sessions); !slices.Equal(got, []string{"s1", "s2", "s3"}) {
		t.Errorf("sessions %v, want them as they were", got)
	}
	select {
	case p := <-moved:
		t.Errorf("kerod was asked to move %+v", p)
	case <-time.After(100 * time.Millisecond):
	}
}

// The session's menu moves it up, down, to the top and to the bottom.
func TestMoveSessionFromMenu(t *testing.T) {
	a, moved := orderSessions(t)
	a.reorderSession("s1", 1)
	if got := sessionIDs(a.st.Sessions); !slices.Equal(got, []string{"s2", "s1", "s3"}) {
		t.Errorf("api moved down: %v", got)
	}
	wantMovedSession(t, moved, proto.MoveParams{ID: "s1", Index: 1})
	a.reorderSession("s3", 0)
	if got := sessionIDs(a.st.Sessions); !slices.Equal(got, []string{"s3", "s2", "s1"}) {
		t.Errorf("docs moved to the top: %v", got)
	}
	wantMovedSession(t, moved, proto.MoveParams{ID: "s3", Index: 0})
	// Where it is already: nothing to ask.
	a.reorderSession("s3", 0)
	select {
	case p := <-moved:
		t.Errorf("kerod was asked to move %+v", p)
	case <-time.After(100 * time.Millisecond):
	}
}

// The session's context menu has its moves, the ones going nowhere
// disabled, and choosing one moves the session.
func TestSessionMenuMoves(t *testing.T) {
	a, moved := orderSessions(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	if err := tt.RightClick("web"); err != nil {
		t.Fatal(err)
	}
	if got := tt.Menu(); !slices.Contains(got, "Move") {
		t.Fatalf("web's menu is %q", got)
	}
	if err := tt.ChooseMenuItem("Move", "Move to Top"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if got := sessionIDs(a.st.Sessions); !slices.Equal(got, []string{"s2", "s1", "s3"}) {
		t.Errorf("web moved to the top: %v", got)
	}
	wantMovedSession(t, moved, proto.MoveParams{ID: "s2", Index: 0})
	tt.Frame()
	if err := tt.RightClick("web"); err != nil {
		t.Fatal(err)
	}
	// At the top already: Move Up goes nowhere.
	if err := tt.ChooseMenuItem("Move", "Move Up"); err == nil {
		t.Error("Move Up was enabled for the top session")
	}
	tt.CloseMenu()
	tt.Frame()
	if err := tt.RightClick("web"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("Move", "Move Down"); err != nil {
		t.Fatal(err)
	}
	wantMovedSession(t, moved, proto.MoveParams{ID: "s2", Index: 1})
}
