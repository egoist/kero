package main

import (
	"bytes"
	"image"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/git"
	"kero/internal/proto"
	"kero/locales"
)

func TestSidebarSwipeGesture(t *testing.T) {
	a := testApp(t)
	a.set.TrackpadGestures = true
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()

	if a.prefs.SidebarHidden || a.chrome.sideW != a.prefs.SidebarWidth {
		t.Fatalf("initial sidebar hidden=%v sideW=%v, want visible at %v", a.prefs.SidebarHidden, a.chrome.sideW, a.prefs.SidebarWidth)
	}

	// Horizontal swipe left (positive DX) hides the sidebar.
	tt.Scroll(600, 320, 25, 0)
	tt.Advance(20 * time.Millisecond)
	tt.Scroll(600, 320, 25, 2)
	tt.Advance(time.Second)
	tt.Frame()
	if !a.prefs.SidebarHidden || a.chrome.sideW != 0 {
		t.Fatalf("after left swipe: hidden=%v sideW=%v, want true and 0", a.prefs.SidebarHidden, a.chrome.sideW)
	}

	// Small horizontal jitter below threshold does not reopen the sidebar.
	tt.Advance(250 * time.Millisecond)
	tt.Scroll(600, 320, -12, 0)
	tt.Frame()
	if !a.prefs.SidebarHidden {
		t.Fatal("small horizontal delta unexpectedly showed sidebar")
	}

	// Horizontal swipe right (negative DX) shows the sidebar again.
	tt.Advance(250 * time.Millisecond)
	tt.Scroll(600, 320, -55, 0)
	tt.Advance(time.Second)
	tt.Frame()
	if a.prefs.SidebarHidden || a.chrome.sideW != a.prefs.SidebarWidth {
		t.Fatalf("after right swipe: hidden=%v sideW=%v, want false and %v", a.prefs.SidebarHidden, a.chrome.sideW, a.prefs.SidebarWidth)
	}

	// Vertical scrolling locks out horizontal swipe within the same gesture.
	tt.Advance(250 * time.Millisecond)
	tt.Scroll(600, 320, 0, 20)
	tt.Advance(20 * time.Millisecond)
	tt.Scroll(600, 320, 60, 0)
	tt.Frame()
	if a.prefs.SidebarHidden {
		t.Fatal("horizontal move after vertical scroll lock hid sidebar")
	}

	// Mouse wheel notches do not trigger trackpad sidebar swipes.
	tt.Advance(250 * time.Millisecond)
	tt.Wheel(600, 320, 80, 0)
	tt.Frame()
	if a.prefs.SidebarHidden {
		t.Fatal("mouse wheel unexpectedly hid sidebar")
	}

	// Momentum events never refresh the active gesture window, so a new swipe
	// immediately following momentum works without waiting for gestureIdle.
	now := tt.Now().Add(time.Second)
	a.handleSidebarSwipe(ui.InputEvent{Kind: ui.InputScroll, DX: 35, Precise: true, Time: now})
	if !a.prefs.SidebarHidden {
		t.Fatal("left swipe did not hide sidebar")
	}
	a.handleSidebarSwipe(ui.InputEvent{Kind: ui.InputScroll, DX: 10, Precise: true, Momentum: true, Time: now.Add(50 * time.Millisecond)})
	a.handleSidebarSwipe(ui.InputEvent{Kind: ui.InputScroll, DX: -35, Precise: true, Time: now.Add(80 * time.Millisecond)})
	if a.prefs.SidebarHidden {
		t.Fatal("new right swipe after momentum did not show sidebar")
	}

	// Modifier-held or momentum scroll events are ignored.
	now = now.Add(time.Second)
	if a.handleSidebarSwipe(ui.InputEvent{Kind: ui.InputScroll, DX: 80, Precise: true, Mods: ui.Alt, Time: now}) {
		t.Fatal("Option/Alt-held horizontal scroll was consumed by sidebar swipe")
	}
	if a.handleSidebarSwipe(ui.InputEvent{Kind: ui.InputScroll, DX: 80, Precise: true, Momentum: true, Time: now.Add(250 * time.Millisecond)}) {
		t.Fatal("momentum scroll triggered sidebar swipe")
	}
	if a.prefs.SidebarHidden {
		t.Fatal("ignored events changed SidebarHidden")
	}

	// Disabling the setting or opening a modal stops gestures.
	a.set.TrackpadGestures = false
	tt.Advance(250 * time.Millisecond)
	tt.Scroll(600, 320, 80, 0)
	tt.Frame()
	if a.prefs.SidebarHidden {
		t.Fatal("swipe fired while trackpad-gestures was off")
	}

	a.set.TrackpadGestures = true
	a.pal.open = true
	tt.Advance(250 * time.Millisecond)
	tt.Scroll(600, 320, 80, 0)
	tt.Frame()
	if a.prefs.SidebarHidden {
		t.Fatal("swipe fired while command palette was open")
	}
}

func TestPanePinchZoomGesture(t *testing.T) {
	a := testApp(t)
	a.set.TrackpadGestures = true
	s := &a.st.Sessions[0]
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()

	br, ok := tt.Find("zsh")
	if !ok {
		t.Fatalf("missing pane b header; texts %q", tt.Texts())
	}
	bx, by := br.X+40, br.Y+br.H+80

	// Spread below threshold does not zoom yet.
	tt.Pinch(bx, by, 1.05)
	tt.Frame()
	if s.Zoomed != "" {
		t.Fatalf("small spread zoomed %q", s.Zoomed)
	}

	// Crossing threshold in the same gesture zooms and focuses pane b.
	tt.Advance(20 * time.Millisecond)
	tt.Pinch(bx, by, 1.15)
	tt.Frame()
	if s.Zoomed != "b" || a.focusOf(s) != "b" {
		t.Fatalf("after spread: zoomed=%q focus=%q, want b and b", s.Zoomed, a.focusOf(s))
	}

	// Continuing to spread in the same gesture stays zoomed.
	tt.Advance(20 * time.Millisecond)
	tt.Pinch(bx, by, 1.25)
	tt.Frame()
	if s.Zoomed != "b" {
		t.Fatalf("continued spread changed zoomed to %q", s.Zoomed)
	}

	// After idle, pinching in restores all panes.
	tt.Advance(250 * time.Millisecond)
	tt.Pinch(bx, by, 0.80)
	tt.Frame()
	if s.Zoomed != "" {
		t.Fatalf("after pinch in: zoomed=%q, want empty", s.Zoomed)
	}

	// Windows precision touchpads send Ctrl with InputZoom; Alt skips it.
	now := tt.Now().Add(time.Second)
	if a.handlePanePinch(ui.InputEvent{Kind: ui.InputZoom, Scale: 1.3, Mods: ui.Alt, Time: now}, s.ID, "b") {
		t.Fatal("Alt+pinch was consumed")
	}
	if s.Zoomed != "" {
		t.Fatal("Alt+pinch zoomed pane")
	}
	if !a.handlePanePinch(ui.InputEvent{Kind: ui.InputZoom, Scale: 1.3, Mods: ui.Ctrl, Time: now.Add(250 * time.Millisecond)}, s.ID, "b") {
		t.Fatal("Ctrl+pinch was not consumed")
	}
	if s.Zoomed != "b" {
		t.Fatalf("Ctrl+pinch zoomed=%q, want b", s.Zoomed)
	}

	// Disabling the setting or opening a modal stops pinch gestures.
	a.set.TrackpadGestures = false
	tt.Advance(250 * time.Millisecond)
	tt.Pinch(bx, by, 0.80)
	tt.Frame()
	if s.Zoomed != "b" {
		t.Fatal("pinch fired while trackpad-gestures was off")
	}
	a.set.TrackpadGestures = true
	a.pal.open = true
	tt.Advance(250 * time.Millisecond)
	tt.Pinch(bx, by, 0.80)
	tt.Frame()
	if s.Zoomed != "b" {
		t.Fatal("pinch fired while command palette was open")
	}
	a.pal.open = false

	// Single-pane sessions ignore pinch.
	s.Zoomed = ""
	s.Panes = s.Panes[:1]
	s.Layout = nil
	if a.handlePanePinch(ui.InputEvent{Kind: ui.InputZoom, Scale: 1.3, Time: now.Add(500 * time.Millisecond)}, s.ID, "a") {
		t.Fatal("single-pane session consumed pinch")
	}
}

func TestGesturesOverLiveTerminal(t *testing.T) {
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	a.set.TrackpadGestures = true
	var scrollRows []int
	termA, err := terminal.New(terminal.Options{
		Conn:     idleConn{make(chan struct{})},
		OnScroll: func(rows int) bool { scrollRows = append(scrollRows, rows); return true },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer termA.Close()
	termB, err := terminal.New(terminal.Options{Conn: idleConn{make(chan struct{})}})
	if err != nil {
		t.Fatal(err)
	}
	defer termB.Close()

	var sb strings.Builder
	for i := range 100 {
		sb.WriteString("line " + itoa(i) + "\r\n")
	}
	termA.Feed([]byte(sb.String()))

	a.terms["a"] = &termEntry{term: termA}
	a.terms["b"] = &termEntry{term: termB}

	s := &a.st.Sessions[0]
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()

	ar, ok1 := tt.Find("fish")
	br, ok2 := tt.Find("zsh")
	if !ok1 || !ok2 {
		t.Fatalf("missing pane headers; texts %q", tt.Texts())
	}
	ax, ay := ar.X+40, ar.Y+ar.H+80
	bx, by := br.X+40, br.Y+br.H+80

	// Horizontal swipe directly over pane a's terminal hides and shows the sidebar.
	tt.Scroll(ax, ay, 30, 0)
	tt.Advance(20 * time.Millisecond)
	tt.Scroll(ax, ay, 30, 2)
	tt.Frame()
	if !a.prefs.SidebarHidden {
		t.Fatal("left swipe over live terminal did not hide sidebar")
	}
	if len(scrollRows) != 0 {
		t.Fatalf("horizontal swipe scrolled terminal: %v", scrollRows)
	}

	tt.Advance(250 * time.Millisecond)
	tt.Scroll(ax, ay, -60, 0)
	tt.Frame()
	if a.prefs.SidebarHidden {
		t.Fatal("right swipe over live terminal did not show sidebar")
	}

	// Vertical scroll over pane a's terminal scrolls the terminal, not the sidebar.
	tt.Advance(250 * time.Millisecond)
	tt.Scroll(ax, ay, 0, -60)
	tt.Frame()
	if len(scrollRows) == 0 || scrollRows[0] >= 0 {
		t.Fatalf("vertical scroll over terminal got %v, want negative rows", scrollRows)
	}
	if a.prefs.SidebarHidden {
		t.Fatal("vertical scroll over terminal toggled sidebar")
	}

	// Spread and pinch directly over pane b's terminal zoom and restore pane b.
	tt.Pinch(bx, by, 1.25)
	tt.Frame()
	if s.Zoomed != "b" {
		t.Fatalf("spread over live terminal: zoomed=%q, want b", s.Zoomed)
	}
	tt.Advance(250 * time.Millisecond)
	tt.Pinch(bx, by, 0.80)
	tt.Frame()
	if s.Zoomed != "" {
		t.Fatalf("pinch over live terminal: zoomed=%q, want empty", s.Zoomed)
	}
}

func TestTrackpadGesturesSettingsSearch(t *testing.T) {
	found := searchResults("trackpad-gestures", nil)
	if hits := found["general"]; !slices.Contains(hits, locales.SetTrackpadGestures()) {
		t.Fatalf("search for trackpad-gestures = %v, want %q in general", found, locales.SetTrackpadGestures())
	}
}

func TestSidebarSwipeDoesNotStealHorizontalScroll(t *testing.T) {
	longLine := "const veryLongIdentifier = " + strings.Repeat("abcdefghij", 40)
	t.Run("diff", func(t *testing.T) {
		a, tt, card := changesViewer(t, longLine+"\n", "unified")
		// Below the viewer's header and the file's sticky header, on the line.
		assertSidewaysScroll(t, a, tt, card.X+160, card.Y+headerH+stickyH+16)
	})
	t.Run("split diff", func(t *testing.T) {
		a, tt, card := changesViewer(t, longLine+"\n", "split")
		// The new side of a side-by-side diff, past the divider.
		assertSidewaysScroll(t, a, tt, card.X+card.W*0.75, card.Y+headerH+stickyH+16)
	})
	t.Run("wide table in file", func(t *testing.T) {
		a := testApp(t)
		a.set.TrackpadGestures = true
		a.set.WrapLines = false
		s := &a.st.Sessions[0]
		// A markdown table wider than the viewer. Soft wrap is off, so the
		// row scrolls sideways instead of the sidebar taking the swipe.
		row := "| name | " + strings.Repeat("column ", 40) + "|"
		fv := &fileView{pane: "a", path: "/tmp/demo/table.md", rel: "table.md", fetched: time.Now()}
		a.showFile(fv, []byte(row+"\n"+row+"\n"))
		a.openView(s, sideFiles, fv)
		a.prefs.Side = sideFiles
		tt, card := viewerTester(t, a)
		assertSidewaysScroll(t, a, tt, card.X+80, card.Y+headerH+24)
	})
}

// changesViewer opens the Changes viewer on one file whose new side is text,
// laid out as layout ("unified" or "split").
func changesViewer(t *testing.T, text, layout string) (*App, *ui.Tester, ui.Rect) {
	t.Helper()
	a := testApp(t)
	a.set.TrackpadGestures = true
	a.set.WrapLines = false
	a.set.DiffLayout = layout
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 1, Added: 1}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	ch.base, ch.scope, ch.stamp = git.BaseHead, changesScope(&s.Panes[0], git.BaseHead), gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo", Files: []proto.GitFile{{Path: "f.go", Status: "modified", Added: 1}}}
	ch.fetched = time.Now()
	ch.files = map[string]*sideFile{
		ch.scope + "|f.go": {
			pane: s.Panes[0].ID,
			base: git.BaseHead,
			root: "/tmp/demo",
			f:    proto.GitFile{Path: "f.go", Status: "modified", Added: 1},
			d:    &editor.DiffState{Old: editor.NewBuffer(""), New: editor.NewBuffer(text)},
		},
	}
	tt, card := viewerTester(t, a)
	return a, tt, card
}

func viewerTester(t *testing.T, a *App) (*ui.Tester, ui.Rect) {
	t.Helper()
	var card ui.Rect
	tt := ui.NewTester(func(c *ui.Context) {
		a.view(c)
		card = a.paneRef("side-card").Bounds(c)
	}, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	if card.W < 100 || card.H < 100 {
		t.Fatalf("viewer card %+v", card)
	}
	return tt, card
}

// assertSidewaysScroll scrolls sideways at x, y by more than a sidebar swipe
// and fails unless that content moves and the sidebar stays put.
func assertSidewaysScroll(t *testing.T, a *App, tt *ui.Tester, x, y float32) {
	t.Helper()
	before, ok := pixelRect(tt.Image(), int(x)-20, int(y)-4, 80, 16)
	if !ok {
		t.Fatalf("sample at %v,%v outside the window", x, y)
	}
	tt.Scroll(x, y, 80, 0)
	tt.Frame()
	if a.prefs.SidebarHidden {
		t.Fatal("horizontal scroll hid the sidebar")
	}
	after, ok := pixelRect(tt.Image(), int(x)-20, int(y)-4, 80, 16)
	if !ok || bytes.Equal(before, after) {
		t.Fatal("horizontal scroll did not move the view under the pointer")
	}
}

func pixelRect(img *image.RGBA, x, y, w, h int) ([]byte, bool) {
	if img == nil || x < 0 || y < 0 || x+w > img.Bounds().Dx() || y+h > img.Bounds().Dy() {
		return nil, false
	}
	out := make([]byte, 0, w*h*4)
	for py := y; py < y+h; py++ {
		o := img.PixOffset(x, py)
		out = append(out, img.Pix[o:o+w*4]...)
	}
	return out, true
}

// A wide table under the side panel keeps a sideways trackpad scroll: the
// columns move, and the sidebar stays. The same scroll away from that panel
// still hides the sidebar.
func TestWideTableKeepsHorizontalScroll(t *testing.T) {
	a := testApp(t)
	a.set.TrackpadGestures = true
	s := ui.ListState{}
	cols := []ui.TableColumn{
		{Title: "Name", Width: 220},
		{Title: "Kind", Width: 220},
		{Title: "Size", Width: 220},
	}
	tt := ui.NewTester(func(c *ui.Context) {
		ui.Row(c).Fill().HandleInput(a.handleSidebarSwipe).Children(func() {
			ui.Table(c, &s, cols, 6, func(row, col int) {
				ui.Text(c, []string{"wide.go", "file", "1 KB"}[col]).SingleLine()
			}).Size(380, 240)
		})
	}, 800, 400)
	tt.Frame()

	cell, ok := tt.Find("wide.go")
	if !ok {
		t.Fatal("table cell was not built")
	}
	sizeBefore, ok := tt.Find("Size")
	if !ok {
		t.Fatal("Size column was not built")
	}
	atX, atY := cell.X+cell.W/2, cell.Y+cell.H/2
	// The table sits where the viewer is, so the gesture leaves the scroll.
	a.side.viewer = ui.Rect{X: 0, Y: 0, W: 800, H: 400}
	tt.Scroll(atX, atY, 160, 0)
	tt.Frame()
	if a.prefs.SidebarHidden {
		t.Fatal("horizontal scroll over a wide table hid the sidebar")
	}
	sizeAfter, ok := tt.Find("Size")
	if !ok || sizeAfter.X >= sizeBefore.X-1 {
		t.Fatalf("wide table did not scroll: Size at %v, was %v", sizeAfter.X, sizeBefore.X)
	}

	// Off the side panel, the same scroll is the sidebar gesture.
	a.side.viewer = ui.Rect{}
	a.gestures = gestureState{}
	tt.Scroll(atX, atY, 160, 0)
	tt.Frame()
	if !a.prefs.SidebarHidden {
		t.Fatal("horizontal scroll outside the side panel did not hide the sidebar")
	}
}
