package main

import (
	"encoding/json"
	"slices"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

func projectIDs(ps []proto.Project) []string {
	ids := make([]string, len(ps))
	for i, p := range ps {
		ids[i] = p.ID
	}
	return ids
}

// A host's projects move among the places they had, the other hosts'
// staying where they are.
func TestReorderProjects(t *testing.T) {
	all := []proto.Project{{ID: "a1"}, {ID: "b1"}, {ID: "a2"}, {ID: "a3"}, {ID: "b2"}}
	mine := func(p proto.Project) bool { return p.ID[0] == 'a' }
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
		got := projectIDs(reorderProjects(all, tc.id, tc.index, mine))
		if !slices.Equal(got, tc.want) {
			t.Errorf("move %s to %d: %v, want %v", tc.id, tc.index, got, tc.want)
		}
	}
	if got := projectIDs(all); !slices.Equal(got, []string{"a1", "b1", "a2", "a3", "b2"}) {
		t.Errorf("the projects given changed: %v", got)
	}
}

func TestInsertionIndex(t *testing.T) {
	// Of a, b, c, d: b put before d goes to 2, before a to 0, at the end to 3.
	for _, tc := range [][3]int{{1, 3, 2}, {1, 0, 0}, {1, 4, 3}, {3, 0, 0}, {0, 2, 1}} {
		if got := insertionIndex(tc[0], tc[1]); got != tc[2] {
			t.Errorf("from %d before %d: %d, want %d", tc[0], tc[1], got, tc[2])
		}
	}
}

// orderApp is the app with three projects of a session each, and a kerod
// that records the projects moved.
func orderApp(t *testing.T) (*App, chan proto.MoveProjectParams) {
	t.Helper()
	a := testApp(t)
	a.st = proto.State{
		Projects: []proto.Project{
			{ID: "p1", Name: "alpha", Dir: "/tmp/alpha"},
			{ID: "p2", Name: "beta", Dir: "/tmp/beta"},
			{ID: "p3", Name: "gamma", Dir: "/tmp/gamma"},
		},
		Sessions: []proto.Session{
			{ID: "s1", Project: "p1", Name: "api", Panes: []proto.Pane{{ID: "a", Shell: "zsh", Dir: "/tmp/alpha", Status: proto.Idle, Progress: -1}}, Focus: "a"},
			{ID: "s2", Project: "p2", Name: "web", Panes: []proto.Pane{{ID: "b", Shell: "zsh", Dir: "/tmp/beta", Status: proto.Idle, Progress: -1}}, Focus: "b"},
			{ID: "s3", Project: "p3", Name: "docs", Panes: []proto.Pane{{ID: "c", Shell: "zsh", Dir: "/tmp/gamma", Status: proto.Idle, Progress: -1}}, Focus: "c"},
		},
	}
	a.selected = "s1"
	a.local().conn = connReady
	a.terms["a"], a.terms["b"], a.terms["c"] = &termEntry{}, &termEntry{}, &termEntry{}
	moved := make(chan proto.MoveProjectParams, 4)
	a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method == "project.move" {
			var p proto.MoveProjectParams
			json.Unmarshal(raw, &p)
			moved <- p
		}
		return true, nil
	})
	return a, moved
}

func wantMoved(t *testing.T, moved chan proto.MoveProjectParams, want proto.MoveProjectParams) {
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

// Dragging a project's header above another's moves it there, at once in
// the sidebar and in kerod, which keeps the order.
func TestDragProjectInSidebar(t *testing.T) {
	a, moved := orderApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	gamma, ok := tt.Find("gamma")
	if !ok {
		t.Fatalf("no header of gamma; texts %q", tt.Texts())
	}
	alpha, _ := tt.Find("alpha")
	x, y := gamma.X+gamma.W/2, gamma.Y+gamma.H/2
	// Above alpha's middle: before it.
	tx, ty := alpha.X+alpha.W/2, alpha.Y+2
	tt.Press(x, y)
	for i := 1; i <= 12; i++ {
		f := float32(i) / 12
		tt.Move(x+(tx-x)*f, y+(ty-y)*f)
		tt.Advance(16 * time.Millisecond)
		tt.Frame()
	}
	tt.Advance(200 * time.Millisecond)
	tt.Frame()
	if a.projMove.id != "p3" || a.projMove.at != 0 {
		t.Errorf("dragging gamma over alpha's top: %+v, want p3 going to 0", a.projMove)
	}
	shot(t, tt, "project-drag")
	tt.Release(tx, ty)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	if got := projectIDs(a.st.Projects); !slices.Equal(got, []string{"p3", "p1", "p2"}) {
		t.Errorf("after the drop, projects %v, want p3 p1 p2", got)
	}
	wantMoved(t, moved, proto.MoveProjectParams{ID: "p3", Index: 0})
	if a.projMove.id != "" {
		t.Errorf("the drag is still on after the drop: %+v", a.projMove)
	}
	// The project's header is no click: gamma did not collapse.
	if a.prefs.Collapsed["p3"] {
		t.Error("the drag collapsed the project dragged")
	}
	shot(t, tt, "project-dropped")
}

// Dragged to where it is, a project stays, and kerod hears nothing.
func TestDragProjectInPlace(t *testing.T) {
	a, moved := orderApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	beta, _ := tt.Find("beta")
	x, y := beta.X+beta.W/2, beta.Y+beta.H/2
	tt.Press(x, y)
	for i := 1; i <= 8; i++ {
		tt.Move(x, y+float32(i))
		tt.Advance(16 * time.Millisecond)
		tt.Frame()
	}
	if a.projMove.id != "p2" || a.projMove.at != -1 {
		t.Errorf("beta over itself: %+v, want p2 going nowhere", a.projMove)
	}
	tt.Release(x, y+8)
	tt.Frame()
	tt.Frame()
	if got := projectIDs(a.st.Projects); !slices.Equal(got, []string{"p1", "p2", "p3"}) {
		t.Errorf("projects %v, want them as they were", got)
	}
	select {
	case p := <-moved:
		t.Errorf("kerod was asked to move %+v", p)
	case <-time.After(100 * time.Millisecond):
	}
}

// The project's menu moves it up, down, to the top and to the bottom.
func TestMoveProjectFromMenu(t *testing.T) {
	a, moved := orderApp(t)
	a.moveProject("p1", 1)
	if got := projectIDs(a.st.Projects); !slices.Equal(got, []string{"p2", "p1", "p3"}) {
		t.Errorf("alpha moved down: %v", got)
	}
	wantMoved(t, moved, proto.MoveProjectParams{ID: "p1", Index: 1})
	a.moveProject("p3", 0)
	if got := projectIDs(a.st.Projects); !slices.Equal(got, []string{"p3", "p2", "p1"}) {
		t.Errorf("gamma moved to the top: %v", got)
	}
	wantMoved(t, moved, proto.MoveProjectParams{ID: "p3", Index: 0})
	// Where it is already: nothing to ask.
	a.moveProject("p3", 0)
	select {
	case p := <-moved:
		t.Errorf("kerod was asked to move %+v", p)
	case <-time.After(100 * time.Millisecond):
	}
}

// The project's context menu has its moves, the ones going nowhere
// disabled, and choosing one moves the project.
func TestProjectMenuMoves(t *testing.T) {
	a, moved := orderApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	if err := tt.RightClick("beta"); err != nil {
		t.Fatal(err)
	}
	if got := tt.Menu(); !slices.Contains(got, "Move") {
		t.Fatalf("beta's menu is %q", got)
	}
	if err := tt.ChooseMenuItem("Move", "Move to Top"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if got := projectIDs(a.st.Projects); !slices.Equal(got, []string{"p2", "p1", "p3"}) {
		t.Errorf("beta moved to the top: %v", got)
	}
	wantMoved(t, moved, proto.MoveProjectParams{ID: "p2", Index: 0})
	tt.Frame()
	if err := tt.RightClick("beta"); err != nil {
		t.Fatal(err)
	}
	// At the top already: Move Up goes nowhere.
	if err := tt.ChooseMenuItem("Move", "Move Up"); err == nil {
		t.Error("Move Up was enabled for the top project")
	}
	tt.CloseMenu()
	tt.Frame()
	if err := tt.RightClick("beta"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("Move", "Move Down"); err != nil {
		t.Fatal(err)
	}
	wantMoved(t, moved, proto.MoveProjectParams{ID: "p2", Index: 1})
}
