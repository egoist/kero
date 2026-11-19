package main

import (
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/locales"
)

func TestSidebarSwipeGesture(t *testing.T) {
	a := testApp(t)
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
