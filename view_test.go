package main

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"runtime"
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
	a.local().loaded = true
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

// With the sidebar hidden, only the header at the window's top left
// keeps clear of the traffic lights: a pane under it starts its title
// where any card does.
func TestHeaderPadBelowTopLeft(t *testing.T) {
	a := testApp(t)
	a.prefs.SidebarHidden = true
	var l *proto.Layout
	a.st.Sessions[0].Layout = l.Split("a", "b", "down", 0)
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	top, ok1 := tt.Find("fish")
	below, ok2 := tt.Find("zsh")
	if !ok1 || !ok2 {
		t.Fatalf("no titles; texts %q", tt.Texts())
	}
	if below.Y <= top.Y {
		t.Fatalf("pane b is not under a: %v, %v", top, below)
	}
	if below.X >= top.X {
		t.Errorf("the title under the top left's starts at %v, as far in as the top left's %v", below.X, top.X)
	}
	shot(t, tt, "header-pad-below")
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
	a.local().conn = connReady
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
	a.local().conn, a.local().daemonApp = connReady, "1.9.0"
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

	a.confirm, a.local().daemonApp = nil, mygo.App.Version()
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

// Command over the path of an image a pane printed, relative to its
// directory, shows the image beside it, until Command is let go of,
// which lets go of the image too.
func TestImagePeek(t *testing.T) {
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	dir := t.TempDir()
	a.st.Sessions[0].Panes[0].Dir = dir
	f, err := os.Create(filepath.Join(dir, "shot.png"))
	if err != nil {
		t.Fatal(err)
	}
	img := image.NewRGBA(image.Rect(0, 0, 30, 20))
	draw.Draw(img, img.Bounds(), image.NewUniform(color.RGBA{230, 120, 40, 255}), image.Point{}, draw.Src)
	png.Encode(f, img)
	f.Close()
	term, err := terminal.New(terminal.Options{Conn: idleConn{make(chan struct{})}, OpenLink: func(link string) bool { return a.openLink("a", link) }})
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	term.Feed([]byte("saved shot.png:3 and notes.txt\r\n"))
	a.terms["a"] = &termEntry{term: term}
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	b, ok := tt.Find("Terminal")
	if !ok {
		t.Fatalf("no terminal; texts %q", tt.Texts())
	}
	// Along the first row to the path, Command pressed with the pointer
	// still.
find:
	for y := b.Y; y < b.Y+40; y += 4 {
		for x := b.X; x < b.X+b.W/2; x += 3 {
			tt.Move(x, y)
			tt.HoldModifiers(ui.Cmd)
			if link, _, _ := term.HoveredLink(); link != "" {
				break find
			}
		}
	}
	tt.Frame()
	if link, path, _ := term.HoveredLink(); link != "shot.png:3" || !path {
		t.Fatalf("hovered %q, %v; text %q", link, path, term.Text())
	}
	if want := filepath.Join(dir, "shot.png"); a.peek.path != want {
		t.Fatalf("peeks at %q, want %q", a.peek.path, want)
	}
	// The decoded image lands, as the window's update would bring it, and
	// shows in the flyout.
	data, _ := os.ReadFile(a.peek.path)
	a.peek.bm, _ = ui.DecodeBitmap(data)
	tt.Frame()
	ft := ui.NewTester(a.peekView, peekMinW, 20+peekPad+peekCaption)
	ft.Frame()
	if !ft.HasText("shot.png") || !ft.HasText("30 × 20") {
		t.Fatalf("no preview; texts %q", ft.Texts())
	}
	shot(t, ft, "peek")
	tt.HoldModifiers(0)
	tt.Frame()
	if a.peek.bm != nil || a.peek.path != "" {
		t.Errorf("the preview stays once Command is let go of: %+v", a.peek)
	}
}

// A split top to bottom, with one side by side inside it, gives every
// split element a key of its own: MyGo panics on two elements with one key
// under one parent, as when a column split made a Row before its Column.
func TestNestedSplitKeys(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	s.Panes = append(s.Panes, proto.Pane{ID: "c", Shell: "bash", Dir: "/tmp", Status: proto.Idle, Progress: -1})
	s.Layout = &proto.Layout{Ratio: 0.5, A: &proto.Layout{Pane: "a"},
		B: &proto.Layout{Row: true, Ratio: 0.5, A: &proto.Layout{Pane: "b"}, B: &proto.Layout{Pane: "c"}}}
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	tt.Frame()
	for _, title := range []string{"fish", "zsh", "bash"} {
		if !tt.HasText(title) {
			t.Errorf("no pane %s; texts %q", title, tt.Texts())
		}
	}
}

// A browser pane shows a toolbar over its page, as its header, with an
// address bar that a blank page asks to type in and Open Location gives
// the keyboard; it attaches no terminal.
func TestBrowserPane(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	s.Panes[1] = proto.Pane{ID: "b", Dir: "/tmp", URL: proto.BlankURL, Status: proto.Idle, Progress: -1}
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	tt.Frame()
	for _, text := range []string{locales.BrowserBlank()} {
		if !tt.HasText(text) {
			t.Errorf("no %q; texts %q", text, tt.Texts())
		}
	}
	if a.terms["b"] != nil {
		t.Error("a browser pane attached a terminal")
	}
	e := a.webs["b"]
	if e == nil {
		t.Fatal("no browser for pane b")
	}
	// A blank page's address bar takes the keyboard: what is typed there
	// goes to the page, as a URL.
	tt.Type("localhost:5173")
	tt.Frame()
	if e.address != "localhost:5173" {
		t.Errorf("typed %q into the address bar", e.address)
	}
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if e.url != "http://localhost:5173" {
		t.Errorf("went to %q", e.url)
	}

	// Its toolbar is its header: no title over it, page's or other.
	s = &a.st.Sessions[0]
	s.Panes[1].Title = "Vite App"
	tt.Frame()
	if tt.HasText("Vite App") || tt.HasText("browser") || !tt.HasText(locales.BrowserAddress()) {
		t.Errorf("a browser pane shows a title bar; texts %q", tt.Texts())
	}
	// Open Location gives the browser's address bar the keyboard, with
	// what it holds to type over.
	a.setFocus(s, "b")
	a.run("browser.address", nil)
	tt.Frame()
	tt.Type("kero.sh")
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if e.url != "https://kero.sh" {
		t.Errorf("Open Location went to %q", e.url)
	}
	shot(t, tt, "browser")
}

// An address typed in the palette opens in a browser, first of what it
// finds; words find the browser's actions, but open nothing.
func TestPaletteOpensAddress(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Type("localhost:5173")
	tt.Frame()
	// The palette's rows follow its label.
	texts := tt.Texts()
	rows := texts[slices.Index(texts, locales.PaletteLabel())+1:]
	if len(rows) < 2 || rows[0] != locales.PaletteOpenInBrowser() || rows[1] != "http://localhost:5173" {
		t.Fatalf("the address is not the first item; rows %q", rows)
	}
	a.pal.query = ""
	tt.Frame()
	tt.Type("web")
	tt.Frame()
	if tt.HasText(locales.PaletteOpenInBrowser()) || !tt.HasText(locales.ActionNewBrowser()) {
		t.Errorf("words: texts %q", tt.Texts())
	}
}

// With focus-follows-mouse, the pointer going into a pane focuses it, but
// a pane that comes under a pointer standing still does not.
func TestFocusFollowsMouse(t *testing.T) {
	a := testApp(t)
	a.set.FocusFollowsMouse = true
	s := &a.st.Sessions[0]
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	ar, _ := tt.Find("fish") // pane a's title
	br, _ := tt.Find("zsh")  // pane b's
	move := func(x float32) {
		tt.Move(x, 340)
		tt.Advance(16 * time.Millisecond)
		tt.Frame()
	}
	move(ar.X + 40)
	if got := a.focusOf(s); got != "a" {
		t.Fatalf("over a, focus %q", got)
	}
	move(br.X + 40)
	if got := a.focusOf(s); got != "b" {
		t.Fatalf("into b, focus %q, want b", got)
	}

	// The keyboard takes the focus back to a: b, under the pointer, keeps
	// it from there, as the pointer moves on in it.
	a.setFocus(s, "a")
	tt.Frame()
	move(br.X + 60)
	if got := a.focusOf(s); got != "a" {
		t.Fatalf("moving in b after the keyboard focused a, focus %q", got)
	}

	// The panes swap places under the pointer standing still, and back.
	var l *proto.Layout
	s.Layout = l.Split("b", "a", "right", 0)
	tt.Advance(time.Second)
	tt.Frame()
	s.Layout = l.Split("a", "b", "right", 0)
	tt.Advance(time.Second)
	tt.Frame()
	if got := a.focusOf(s); got != "a" {
		t.Fatalf("b came under the pointer standing still, and took the focus")
	}

	// Off, the pointer leaves the focus be.
	a.set.FocusFollowsMouse = false
	move(ar.X + 40)
	move(br.X + 40)
	if got := a.focusOf(s); got != "a" {
		t.Fatalf("with the setting off, focus %q", got)
	}
}

// writes is a Conn that keeps what the terminal sends to the program.
type writes struct {
	idleConn
	got chan []byte
}

func (w writes) Write(b []byte) (int, error) {
	w.got <- append([]byte(nil), b...)
	return len(b), nil
}

// ⌘⌫ sends Control+U, which clears the line, and only on a Mac, where
// ⌘ is not the terminal's Control.
func TestCommandBackspaceClearsLine(t *testing.T) {
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	conn := writes{idleConn{make(chan struct{})}, make(chan []byte, 8)}
	term, err := terminal.New(terminal.Options{Conn: conn})
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	a.terms["a"] = &termEntry{term: term}
	o := a.termOptions("a", nil)
	if took := o.OnKey(ui.Super, ui.KeyBackspace); took != (runtime.GOOS == "darwin") {
		t.Fatalf("⌘⌫ taken: %v", took)
	}
	if runtime.GOOS != "darwin" {
		return
	}
	select {
	case b := <-conn.got:
		if string(b) != "\x15" {
			t.Errorf("⌘⌫ sent %q, want Control+U", b)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("⌘⌫ sent nothing")
	}
	for _, k := range []struct {
		mods ui.Modifiers
		key  ui.Key
	}{{0, ui.KeyBackspace}, {ui.Super | ui.Shift, ui.KeyBackspace}, {ui.Super, ui.KeyDelete}} {
		if o.OnKey(k.mods, k.key) {
			t.Errorf("%v+%v taken", k.mods, k.key)
		}
	}
}
