package main

import (
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"

	"kero/locales"
)

// testApp is the app with a session of two panes side by side, a | b,
// and no kerod.
func testApp(t *testing.T) *App {
	t.Helper()
	home := t.TempDir()
	t.Setenv("KERO_HOME", home)
	// The configuration too: never the user's.
	t.Setenv("KERO_CONFIG", filepath.Join(home, "config"))
	a := newApp()
	var l *proto.Layout
	a.st = proto.State{
		Projects: []proto.Project{{ID: "p1", Name: "demo", Dir: "/tmp"}},
		Sessions: []proto.Session{{
			ID: "s1", Project: "p1", Name: "demo",
			Panes: []proto.Pane{
				{ID: "a", Shell: "fish", Dir: "/tmp", Status: proto.Idle, Progress: -1},
				{ID: "b", Shell: "zsh", Dir: "/tmp", Status: proto.Idle, Progress: -1},
			},
			Layout: l.Split("a", "b", "right", 0),
			Focus:  "a",
		}},
	}
	a.loaded, a.selected = true, "s1"
	return a
}

// shot writes the tester's frame to $KERO_SHOTS, to look at.
func shot(t *testing.T, tt *ui.Tester, name string) {
	dir := os.Getenv("KERO_SHOTS")
	if dir == "" {
		return
	}
	f, err := os.Create(filepath.Join(dir, name+".png"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	png.Encode(f, tt.Image())
}

func TestDragPaneToSide(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	grip, ok := tt.Find("zsh")
	if !ok {
		t.Fatalf("no title of pane b; texts %q", tt.Texts())
	}
	// Pick pane b up by its title, and carry it over a's left edge.
	x, y := grip.X+grip.W/2, grip.Y+grip.H/2
	ar, _ := tt.Find("fish") // pane a's title
	tx, ty := ar.X+10, float32(340)
	tt.Press(x, y)
	for i := 1; i <= 12; i++ {
		f := float32(i) / 12
		tt.Move(x+(tx-x)*f, y+(ty-y)*f)
		tt.Advance(16 * time.Millisecond)
		tt.Frame()
	}
	tt.Advance(400 * time.Millisecond)
	tt.Frame()
	if !tt.HasText("Split Left") {
		t.Errorf("no preview of a split on the left; texts %q", tt.Texts())
	}
	shot(t, tt, "drag-left")

	// Over a's middle: the panes would swap.
	tt.Move(ar.X+120, 340)
	tt.Advance(400 * time.Millisecond)
	tt.Frame()
	if !tt.HasText("Swap Panes") {
		t.Errorf("no preview of a swap; texts %q", tt.Texts())
	}
	shot(t, tt, "drag-swap")

	tt.Release(ar.X+120, 340)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	if got := a.st.Sessions[0].Layout.Panes(); !slices.Equal(got, []string{"b", "a"}) {
		t.Fatalf("after the drop, panes %v, want b then a", got)
	}
	if a.focusOf(&a.st.Sessions[0]) != "b" {
		t.Errorf("the pane moved has not the focus")
	}
	shot(t, tt, "dropped")
}

// The sidebar's animation moves the header's title one way only, in
// whole pixels: a title that steps back and forth shakes.
func TestSidebarAnimationMonotonic(t *testing.T) {
	bar := ui.TitleBar{Left: 78, Height: 60}
	for _, width := range []float32{200, 268, 333, 440} {
		prevX := float32(-1)
		prevEdge := float32(-1)
		for i := 0; i <= 20000; i++ {
			ch := chromeFor(float32(i)/20000, width, bar)
			x := ch.sideW + ch.mainPad + ch.headerPad // the title's left, in the window
			edge := ch.sideW + ch.mainPad             // the card's left edge
			for _, v := range []float32{ch.sideW, ch.mainPad, ch.headerPad} {
				if v != float32(int(v)) {
					t.Fatalf("width %v, progress %v: %v is not a whole pixel", width, ch.shown, v)
				}
			}
			if x < prevX {
				t.Fatalf("width %v, step %d: the title moved back, %v to %v", width, i, prevX, x)
			}
			if edge < prevEdge {
				t.Fatalf("width %v, step %d: the card's edge moved back, %v to %v", width, i, prevEdge, edge)
			}
			prevX, prevEdge = x, edge
		}
		if ch := chromeFor(1, width, bar); ch.headerPad != 16 || ch.mainPad != 0 || ch.sideW != width {
			t.Errorf("width %v shown: %+v", width, ch)
		}
		if ch := chromeFor(0, width, bar); ch.sideW != 0 || ch.mainPad != cardGap {
			t.Errorf("width %v hidden: %+v", width, ch)
		}
	}
}

// The sidebar's animation never holds still before it lands: a frame
// that does not move, then one that does, reads as a stutter.
func TestSidebarAnimationNoHolds(t *testing.T) {
	ease := sidebarMotion.Ease
	frames := int(sidebarMotion.Duration / (time.Second / 60))
	prev := float32(-1)
	for i := 0; i <= frames; i++ {
		w := chromeFor(ease(float32(i)/float32(frames)), 268, ui.TitleBar{}).sideW
		if w == prev && w != 268 {
			t.Errorf("frame %d: the sidebar held at %v before landing", i, w)
		}
		prev = w
	}
}

// The window moves from the panes' headers and the gaps around them, and
// not from a press on a pane, which focuses it.
func TestWindowDragRegions(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	// Pane b's header, past its title: it moves the window, and leaves
	// the focus where it was.
	b, _ := tt.Find("zsh")
	tt.ClickAt(b.X+200, b.Y+b.H/2)
	tt.Frame()
	if f := a.focusOf(&a.st.Sessions[0]); f != "a" {
		t.Errorf("a press on a header's empty stretch moved the focus to %q", f)
	}
	// Pane b's body: it takes the press, and the focus.
	tt.ClickAt(b.X+200, 400)
	tt.Frame()
	if f := a.focusOf(&a.st.Sessions[0]); f != "b" {
		t.Errorf("a press on pane b left the focus on %q", f)
	}
}

// A selection copied as it ends says so; a copy the user asked for, or
// a program's, does not.
func TestCopyOnSelectToast(t *testing.T) {
	a := testApp(t)
	o := a.termOptions("a", nil)
	o.OnCopy("x", terminal.CopyUser)
	o.OnCopy("x", terminal.CopyProgram)
	if a.pendingToast != "" {
		t.Errorf("toast %q for a copy that shows itself", a.pendingToast)
	}
	o.OnCopy("x", terminal.CopySelect)
	if a.pendingToast != "Copied to clipboard" {
		t.Errorf("toast %q after copying a selection", a.pendingToast)
	}
}

// The sidebar's foot counts what wants a look, each count going to the
// next session of it, and says nothing while nothing does ($KERO_SHOTS).
func TestSidebarFooter(t *testing.T) {
	a := testApp(t)
	a.conn = connReady
	tt := ui.NewTester(a.view, 1100, 700)
	tt.Frame()
	for _, txt := range tt.Texts() {
		if strings.Contains(txt, "running") {
			t.Errorf("the foot still says %q", txt)
		}
	}
	base := a.st.Sessions[0]
	add := func(id, name string, st proto.Status, unread bool) {
		s := base
		s.ID, s.Name, s.Status, s.Unread = id, name, st, unread
		a.st.Sessions = append(a.st.Sessions, s)
	}
	add("s2", "deploy", proto.Waiting, true)
	add("s3", "refactor", proto.Working, false)
	add("s4", "tests", proto.Working, false)
	add("s5", "docs", proto.Idle, true)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	shot(t, tt, "sidebar-footer")
	for label, want := range map[string]string{"1 session needs you": "s2", "2 sessions working": "s3", "1 session done, unseen": "s5"} {
		a.selected = "s1"
		tt.Frame()
		if err := tt.Click(label); err != nil {
			t.Errorf("no %q in the foot: %v", label, err)
			continue
		}
		tt.Frame()
		if a.selected != want {
			t.Errorf("%q went to %s, want %s", label, a.selected, want)
		}
	}
}

// A session's tooltip shows below the pointer where it rested, as macOS
// shows tooltips, not centered over the row ($KERO_SHOTS).
func TestSessionTooltipAtPointer(t *testing.T) {
	for _, dx := range []float32{20, 160} {
		a := testApp(t)
		a.st.Sessions[0].Process = "claude"
		a.st.Sessions[0].Dir = "/Users/someone/dev/kero"
		tt := ui.NewTester(a.view, 1100, 700)
		tt.Frame()
		r, ok := tt.Find("1") // the project header's count, above the row
		if !ok {
			t.Fatal("no project header")
		}
		x, y := 12+dx, r.Y+r.H/2+34 // the session row's middle
		tt.Move(x, y)
		tt.Advance(2 * time.Second)
		tt.Frame()
		var tip ui.Rect
		found := false
		for _, txt := range tt.Texts() {
			if strings.HasPrefix(txt, "claude · ") {
				tip, found = tt.Find(txt)
			}
		}
		if !found {
			t.Fatalf("dx %g: no tooltip; texts %q", dx, tt.Texts())
		}
		if d := tip.X - x; d < 0 || d > 16 {
			t.Errorf("dx %g: tooltip text at x %g, the pointer at %g", dx, tip.X, x)
		}
		if d := tip.Y - y; d < 12 || d > 36 {
			t.Errorf("dx %g: tooltip text at y %g, the pointer at %g", dx, tip.Y, y)
		}
		shot(t, tt, fmt.Sprintf("session-tooltip-%g", dx))
	}
}

// A kerod of another version of Kero gets a chip to restart it, which asks
// first while a program runs, as the restart ends it.
func TestRestartStaleDaemon(t *testing.T) {
	a := testApp(t)
	a.conn, a.daemonApp = connReady, "1.9.0"
	a.st.Sessions[0].Process = "claude"
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	if err := tt.Click("Restart Service"); err != nil {
		t.Fatalf("no chip to restart kerod: %v; texts %q", err, tt.Texts())
	}
	tt.Frame()
	if a.confirm == nil || !strings.Contains(a.confirm.detail, "Kero 1.9.0") {
		t.Fatalf("no question before the restart: %+v", a.confirm)
	}

	a.confirm, a.daemonApp = nil, mygo.App.Version()
	tt.Frame()
	if tt.HasText("Restart Service") {
		t.Error("a chip to restart a kerod of this version")
	}
}

// idleConn is a Conn that shows only what a test feeds the terminal.
type idleConn struct{ closed chan struct{} }

func (c idleConn) Read([]byte) (int, error) {
	<-c.closed
	return 0, os.ErrClosed
}
func (c idleConn) Write(b []byte) (int, error) { return len(b), nil }
func (c idleConn) Close() error {
	select {
	case <-c.closed:
	default:
		close(c.closed)
	}
	return nil
}

// Find searches the pane the user is in, its scrollback too: the bar
// counts the matches as one types, Enter and the buttons go through them,
// and Escape closes it, the highlights going; Find Next opens it again
// with the last query.
func TestFindBar(t *testing.T) {
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	term, err := terminal.New(terminal.Options{Conn: idleConn{make(chan struct{})}})
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	var b strings.Builder
	for i := range 200 {
		if i%50 == 7 {
			b.WriteString("error: build failed\r\n")
		} else {
			b.WriteString("ok " + itoa(i) + "\r\n")
		}
	}
	term.Feed([]byte(b.String()))
	a.terms["a"] = &termEntry{term: term}
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	a.run("find.open", nil)
	tt.Frame()
	tt.Type("ERROR")
	for range 50 {
		tt.Frame()
		if s := term.SearchStatus(); !s.Searching && s.Selected > 0 {
			break
		}
	}
	tt.Frame()
	if !tt.HasText("1 of 4") {
		t.Fatalf("no count; texts %q", tt.Texts())
	}
	shot(t, tt, "find")
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	tt.Key(ui.Shift, ui.KeyEnter)
	tt.Frame()
	if !tt.HasText("2 of 4") {
		t.Errorf("after Enter twice and Shift+Enter; texts %q", tt.Texts())
	}
	if err := tt.Click(a.tip(locales.ActionFindNext(), "find.next")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !tt.HasText("3 of 4") {
		t.Errorf("after the button for the next; texts %q", tt.Texts())
	}
	shot(t, tt, "find-scrolled")
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	tt.Frame()
	if a.find.pane != "" || tt.HasText("3 of 4") || term.SearchStatus().Text != "" {
		t.Errorf("Escape left the bar open or the search on: %+v; texts %q", term.SearchStatus(), tt.Texts())
	}
	a.run("find.next", nil)
	tt.Frame()
	tt.Frame()
	if a.find.pane != "a" || a.find.query != "ERROR" || term.SearchStatus().Text != "ERROR" {
		t.Errorf("Find Next did not search again: %+v, %+v", a.find.query, term.SearchStatus())
	}
}

// Turning the dimming of the panes the user is not in off shows them at
// full strength, as the pane they are in.
func TestDimUnfocusedPanes(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	// In the dark, where the veil and the card's dimming show.
	tt.SetDark(true)
	settle := func() {
		for range 3 {
			tt.Advance(400 * time.Millisecond)
			tt.Frame()
		}
	}
	settle()
	// Pane b's card, under its title: empty, the veil over it.
	if _, ok := tt.Find("zsh"); !ok {
		t.Fatalf("no title of pane b; texts %q", tt.Texts())
	}
	mean := func() float64 {
		img := tt.Image()
		var sum float64
		var n int
		for y := 120; y < 600; y += 5 {
			for x := 700; x < 1090; x += 5 {
				c := img.RGBAAt(x, y)
				sum += float64(c.R) + float64(c.G) + float64(c.B)
				n++
			}
		}
		if n == 0 {
			t.Fatal("no pixels of pane b")
		}
		return sum / float64(n)
	}
	if !a.set.DimUnfocused {
		t.Fatal("the dimming is off as the app starts")
	}
	dimmed := mean()
	a.set.DimUnfocused = false
	settle()
	plain := mean()
	if plain <= dimmed*1.05 {
		t.Fatalf("pane b at %v with the dimming off, %v with it on: not brighter", plain, dimmed)
	}
	a.set.DimUnfocused = true
	settle()
	if back := mean(); back >= plain {
		t.Fatalf("pane b at %v with the dimming back on, not dimmer than %v", back, plain)
	}
	shot(t, tt, "dim-back-on")
	a.set.DimUnfocused = false
	settle()
	shot(t, tt, "dim-off")
}
