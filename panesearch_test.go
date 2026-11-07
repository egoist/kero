package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/client"
	"kero/internal/proto"
)

// blockedConn is a terminal's connection with nothing to read: the test
// feeds the terminal.
type blockedConn struct{ closed chan struct{} }

func (b blockedConn) Read([]byte) (int, error) {
	<-b.closed
	return 0, io.EOF
}
func (b blockedConn) Write(p []byte) (int, error) { return len(p), nil }
func (b blockedConn) Close() error {
	close(b.closed)
	return nil
}

func searchTerm(t *testing.T) *terminal.Terminal {
	t.Helper()
	term, err := terminal.New(terminal.Options{Conn: blockedConn{make(chan struct{})}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { term.Close() })
	return term
}

// termSearched runs frames until a terminal's search is through.
func termSearched(t *testing.T, tt *ui.Tester, term *terminal.Terminal, query string) terminal.SearchStatus {
	t.Helper()
	for range 500 {
		tt.Frame()
		if s := term.SearchStatus(); s.Text == query && !s.Searching {
			return s
		}
	}
	t.Fatalf("the search of %q did not end", query)
	return terminal.SearchStatus{}
}

// The search of all panes counts as a pane's find does, on the real
// terminal: choosing a match relies on it.
func TestSearchAgreesWithFind(t *testing.T) {
	term := searchTerm(t)
	tt := ui.NewTester(func(c *ui.Context) { terminal.View(c, term).Fill() }, 800, 400)
	tt.Frame()
	cols, _ := term.Size()
	var long strings.Builder
	for i := range 4000 {
		fmt.Fprintf(&long, "log line %d %s\r\n", i, map[bool]string{true: "needle", false: "hay"}[i%7 == 0])
	}
	cases := []struct{ feed, query string }{
		{"foo foo foo\r\nfoo\r\nbar\r\n", "foo"},
		{"aaaaa\r\n", "aa"},
		{"abab abab\r\nAB\r\n", "ab"},
		{"Error ERROR error eRRoR\r\n", "error"},
		{"\x1b[31mERR\x1b[32mOR\x1b[0m done\r\n", "error"},
		{strings.Repeat("x", cols-3) + "needle tail\r\n", "needle"},
		{strings.Repeat("y", cols*3+5) + "\r\n", "yy"},
		{"wide 你好 world 你好\r\n", "你好"},
		{"ÉCOLE école\r\n", "école"},
		{"a\tb\r\n", "a b"},
		{"a\tb\r\n", "a   "},
		{"trail   \r\nnext\r\n", "trail "},
		{"x\x1b[10Cy\r\n", "x  "},
		{long.String(), "needle"},
	}
	for _, tc := range cases {
		term.Feed([]byte("\x1b[3J\x1b[H\x1b[2J" + tc.feed))
		term.EndSearch()
		term.Search(tc.query)
		st := termSearched(t, tt, term, tc.query)
		n := 0
		proto.ScanMatches(term.Text(), tc.query, nil, func(proto.SearchMatch) bool { n++; return true })
		if st.Total != n {
			t.Errorf("%q in %.40q: the pane's find counts %d, the search of all panes %d", tc.query, tc.feed, st.Total, n)
		}
	}
}

// paneSearchApp is an app in the palette's search mode, on a search in
// progress, as its debounce started it.
func paneSearchApp(t *testing.T, query string) (*App, *ui.Tester, *paneSearch) {
	t.Helper()
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPaneSearch(query)
	run := a.pal.run
	if run == nil {
		t.Fatal("no search started")
	}
	run.timer.Stop()
	run.hosts = []*hostSearch{{h: a.local()}}
	tt.Frame()
	return a, tt, run
}

func hit(pane, line, query string, newer int) proto.SearchMatch {
	i := strings.Index(strings.ToLower(line), strings.ToLower(query))
	return proto.SearchMatch{Session: "s1", Pane: pane, Line: line, Start: i, End: i + len(query), Newer: newer}
}

// Matches list as they come: the session, the pane and the line.
func TestPaneSearchLists(t *testing.T) {
	a, tt, run := paneSearchApp(t, "needle")
	if !tt.HasText("Searching…") {
		t.Errorf("no word of the search going: %q", tt.Texts())
	}
	a.takeHits(run, a.local(), []proto.SearchMatch{hit("a", "a needle here", "needle", 0)})
	tt.Frame()
	if !tt.HasText("a needle here") {
		t.Fatalf("no line: %q", tt.Texts())
	}
	s := a.session("s1")
	pane := s.PaneByID("a")
	want := s.DisplayName(a.set.SessionName) + " · " + pane.PaneName()
	if !tt.HasText(want) {
		t.Errorf("no %q: %q", want, tt.Texts())
	}
	a.takeHits(run, a.local(), []proto.SearchMatch{hit("b", "b needle there", "needle", 0)})
	tt.Frame()
	if !tt.HasText("a needle here") || !tt.HasText("b needle there") {
		t.Errorf("the second batch did not join the first: %q", tt.Texts())
	}
	a.hostSearched(run, run.hosts[0], proto.SearchResult{Panes: 2}, nil)
	tt.Frame()
	if a.searching() {
		t.Error("still searching with every host through")
	}
	shot(t, tt, "palette-search")
}

// A remote host's hits say where they are, and a host gone or old says so
// in place of holding the search up, with the Update of a host behind.
func TestPaneSearchHosts(t *testing.T) {
	a, tt, run := paneSearchApp(t, "needle")
	box := &host{name: "box", conn: connReady}
	a.owner = map[string]*host{"s1": box}
	gone := &host{name: "gone"}
	old := &host{name: "old", conn: connVersion}
	dead := &host{name: "dead", conn: connReady}
	broken := &host{name: "broken", conn: connReady}
	run.hosts = []*hostSearch{{h: a.local()}, {h: box}, {h: gone, state: searchLost}, {h: old, state: searchOld}, {h: dead}, {h: broken}}
	a.takeHits(run, box, []proto.SearchMatch{hit("a", "far needle", "needle", 0)})
	a.hostSearched(run, run.hosts[0], proto.SearchResult{}, client.ErrNoSearch)
	a.hostSearched(run, run.hosts[4], proto.SearchResult{}, context.DeadlineExceeded)
	a.hostSearched(run, run.hosts[5], proto.SearchResult{}, errors.New("bad"))
	tt.Frame()
	for _, want := range []string{"far needle", "Not connected to gone", "old runs a Kero that can't search yet", "dead didn't answer in time",
		"Couldn't search broken: bad", "This computer's background service can't search yet: run Restart Background Service", "Searching box…", "Update"} {
		if !tt.HasText(want) {
			t.Errorf("no %q: %q", want, tt.Texts())
		}
	}
	found := false
	for _, s := range tt.Texts() {
		found = found || strings.HasSuffix(s, " · box")
	}
	if !found {
		t.Errorf("no hit names its host: %q", tt.Texts())
	}
	if !a.searching() {
		t.Error("not searching with one host to answer")
	}
	shot(t, tt, "palette-search-hosts")
}

// What a superseded search still sends shows nowhere, and typing stops the
// search going at once, starting the next only as it pauses.
func TestPaneSearchSuperseded(t *testing.T) {
	a, tt, run := paneSearchApp(t, "first")
	a.takeHits(run, a.local(), []proto.SearchMatch{hit("a", "first one", "first", 0)})
	canceled := false
	run.cancel = func() { canceled = true }
	a.pal.query = "second"
	a.paneSearchChanged()
	if !canceled || a.pal.run == run || a.pal.run == nil {
		t.Fatalf("canceled %v, run %p after %p", canceled, a.pal.run, run)
	}
	next := a.pal.run
	next.timer.Stop()
	next.hosts = []*hostSearch{{h: a.local()}}
	if next.cancel != nil {
		t.Error("the next search started before the typing paused")
	}
	a.takeHits(run, a.local(), []proto.SearchMatch{hit("b", "first late", "first", 0)})
	a.hostSearched(run, run.hosts[0], proto.SearchResult{}, nil)
	tt.Frame()
	if tt.HasText("first late") {
		t.Error("the superseded search's hits show")
	}
	// The last hits stay until the next's come.
	if !tt.HasText("first one") {
		t.Errorf("the list emptied at the key: %q", tt.Texts())
	}
	a.takeHits(next, a.local(), []proto.SearchMatch{hit("a", "second one", "second", 0)})
	tt.Frame()
	if tt.HasText("first one") || !tt.HasText("second one") {
		t.Errorf("not replaced: %q", tt.Texts())
	}
	// An empty query lists nothing, and closing stops the search.
	a.pal.query = " "
	a.paneSearchChanged()
	if a.pal.run != nil || a.pal.shown != nil {
		t.Error("a blank query searches")
	}
	a.pal.query = "third"
	a.paneSearchChanged()
	third := a.pal.run
	third.cancel = func() { canceled = false }
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	if a.pal.open || a.pal.run != nil || canceled {
		t.Errorf("escape left open %v, run %p", a.pal.open, a.pal.run)
	}
}

// The bound of all that lists holds whatever comes, and says so.
func TestPaneSearchShownBound(t *testing.T) {
	a, _, run := paneSearchApp(t, "x")
	batch := make([]proto.SearchMatch, searchShownMost+50)
	for i := range batch {
		batch[i] = hit("a", "x", "x", i)
	}
	a.takeHits(run, a.local(), batch)
	if len(run.hits) != searchShownMost || !run.more {
		t.Errorf("%d hits, more %v", len(run.hits), run.more)
	}
}

// Whatever no session or command names, the palette offers to search for,
// after any that do, keeping what was typed.
func TestPaletteOffersSearch(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	if tt.HasText("Search All Panes for “”") {
		t.Error("offered with nothing typed")
	}
	tt.Type("zzqq")
	tt.Frame()
	if !tt.HasText("Search All Panes for “zzqq”") {
		t.Fatalf("not offered: %q", tt.Texts())
	}
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if !a.pal.open || !a.pal.search || a.pal.query != "zzqq" || a.pal.run == nil {
		t.Fatalf("open %v search %v query %q run %p", a.pal.open, a.pal.search, a.pal.query, a.pal.run)
	}
	a.stopPaneSearch()
	// Typing keeps searching in the field the palette had.
	tt.Type("x")
	tt.Frame()
	if a.pal.query != "zzqqx" || a.pal.run == nil {
		t.Errorf("query %q, run %p", a.pal.query, a.pal.run)
	}
	a.stopPaneSearch()

	// One that matches comes first, the offer last.
	a.openPalette()
	tt.Frame()
	tt.Type("demo")
	tt.Frame()
	texts := strings.Join(tt.Texts(), "\n")
	if i, j := strings.Index(texts, "demo"), strings.Index(texts, "Search All Panes for"); i < 0 || j < i {
		t.Errorf("the offer comes before what matches: %q", texts)
	}
	a.pal.open = false
	tt.Frame()
}

// The action opens the mode, with the query kero do gives it.
func TestSearchAction(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.run("search.panes", map[string]string{"query": "needle"})
	tt.Frame()
	if !a.pal.open || !a.pal.search || a.pal.query != "needle" {
		t.Errorf("open %v search %v query %q", a.pal.open, a.pal.search, a.pal.query)
	}
	a.stopPaneSearch()
	if !tt.HasText("Search All Panes") {
		t.Error("the palette doesn't say it searches panes")
	}
}

// jumpApp has the session's two panes attached to terminals of their own.
func jumpApp(t *testing.T) (*App, *ui.Tester, *terminal.Terminal) {
	t.Helper()
	a := testApp(t)
	a.local().conn = connReady
	term := searchTerm(t)
	a.terms["b"] = &termEntry{term: term}
	a.terms["a"] = &termEntry{term: searchTerm(t)}
	var out strings.Builder
	for i := range 200 {
		fmt.Fprintf(&out, "line %d needle\r\n", i)
	}
	term.Feed([]byte(out.String()))
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	return a, tt, term
}

// Choosing a hit shows its pane, and selects the match in its find, as far
// down its matches as it lies.
func TestJumpToMatch(t *testing.T) {
	a, tt, term := jumpApp(t)
	a.openPaneSearch("needle")
	run := a.pal.run
	run.timer.Stop()
	run.hosts = []*hostSearch{{h: a.local()}}
	m := hit("b", "line 150 needle", "needle", 49)
	a.takeHits(run, a.local(), []proto.SearchMatch{m})
	tt.Frame()
	tt.Key(0, ui.KeyEnter)
	if a.pal.open || a.pal.run != nil {
		t.Fatalf("the palette stayed: open %v", a.pal.open)
	}
	if got := a.focusOf(a.session("s1")); got != "b" {
		t.Errorf("focus on pane %q", got)
	}
	if a.find.pane != "b" || a.find.query != "needle" || a.find.jump == nil {
		t.Fatalf("find %+v", a.find)
	}
	// The terminal's search ends; the app finds the match in what it holds,
	// which takes its window's updates, here at hand.
	termSearched(t, tt, term, "needle")
	text := term.Text()
	newer, ok := proto.LocateMatch(text, "needle", m)
	if !ok || newer != 49 {
		t.Fatalf("located %d %v", newer, ok)
	}
	a.jumpLocated(a.find.jump, newer, ok, len(text))
	tt.Frame()
	tt.Frame()
	st := term.SearchStatus()
	if st.Selected != 50 || st.Total != 200 {
		t.Errorf("selected %d of %d, want 50 of 200", st.Selected, st.Total)
	}
	if !tt.HasText("50 of 200") {
		t.Errorf("the find bar doesn't count it: %q", tt.Texts())
	}
	// A terminal just attached starts over as it takes its window's size,
	// its selection gone: the jump selects it again.
	j := a.find.jump
	if j == nil || !j.selected {
		t.Fatal("the jump didn't stay to look after the selection")
	}
	var out strings.Builder
	for i := range 200 {
		fmt.Fprintf(&out, "line %d needle\r\n", i)
	}
	term.Feed([]byte("\x1bc\x1b[3J" + out.String()))
	for range 500 {
		tt.Frame()
		if s := term.SearchStatus(); !s.Searching && s.Total == 200 && s.Selected != 50 {
			break
		}
	}
	tt.Frame()
	if j.selected || j.newer != -1 {
		t.Fatalf("the selection went and the jump went on as it was: %+v, %+v", j, term.SearchStatus())
	}
	a.jumpLocated(j, 49, true, 0)
	tt.Frame()
	tt.Frame()
	if st := term.SearchStatus(); st.Selected != 50 {
		t.Errorf("selected %d again, want 50", st.Selected)
	}
	// It ends, having nothing to say.
	j.until = time.Now().Add(-time.Second)
	tt.Frame()
	if a.find.jump != nil || a.pendingToast != "" {
		t.Errorf("jump %+v, toast %q", a.find.jump, a.pendingToast)
	}
	// Going back up, as output went on the other way.
	a.find.jump = &findJump{pane: "b", query: "needle", newer: 3, deadline: time.Now().Add(time.Minute)}
	tt.Frame()
	if st := term.SearchStatus(); st.Selected != 4 {
		t.Errorf("selected %d, want 4", st.Selected)
	}
}

// A match no longer in the pane leaves the bar on the pane's newest, saying
// so; a pane closed since says so in place of showing anything.
func TestJumpFallsBack(t *testing.T) {
	a, tt, term := jumpApp(t)
	a.jumpToHit(searchHit{host: a.local(), query: "needle", SearchMatch: hit("b", "line gone needle", "needle", 5)})
	termSearched(t, tt, term, "needle")
	if _, ok := proto.LocateMatch(term.Text(), "needle", a.find.jump.match); ok {
		t.Fatal("found a line that isn't there")
	}
	// Looked for while the terminal's scrollback may be coming, then no more.
	j := a.find.jump
	for _, size := range []int{0, 100, 200, 200} {
		a.jumpLocated(j, -1, false, size)
		if a.find.jump != j {
			t.Fatalf("gave up at a terminal holding %d", size)
		}
	}
	a.jumpLocated(j, -1, false, 200)
	if a.find.jump != nil {
		t.Error("the jump went on")
	}
	if a.pendingToast == "" && !tt.HasText("That match is no longer in the pane's scrollback") {
		t.Errorf("nothing said of it: %q", tt.Texts())
	}
	if st := term.SearchStatus(); st.Selected != 1 || a.find.pane != "b" {
		t.Errorf("selected %d in pane %q", st.Selected, a.find.pane)
	}
	tt.Frame()

	// One never found, as of output going on, gives up in the end too.
	a.jumpToHit(searchHit{host: a.local(), query: "needle", SearchMatch: hit("b", "line gone needle", "needle", 5)})
	a.find.jump.deadline = time.Now().Add(-time.Second)
	tt.Frame()
	if a.find.jump != nil {
		t.Error("the jump went on past its deadline")
	}
	tt.Frame()

	a.jumpToHit(searchHit{host: a.local(), query: "needle", SearchMatch: proto.SearchMatch{Session: "s1", Pane: "closed"}})
	if a.pendingToast == "" {
		t.Error("nothing said of a pane closed")
	}
	a.jumpToHit(searchHit{host: a.local(), query: "needle", SearchMatch: proto.SearchMatch{Session: "gone", Pane: "x"}})
	if a.find.jump != nil {
		t.Error("jumped to a session closed")
	}
}

// A hit of a pane that closed lists no more.
func TestPaneSearchDropsClosed(t *testing.T) {
	a, tt, run := paneSearchApp(t, "needle")
	a.takeHits(run, a.local(), []proto.SearchMatch{{Session: "s1", Pane: "closed", Line: "gone needle"}, hit("a", "kept needle", "needle", 0)})
	tt.Frame()
	if tt.HasText("gone needle") || !tt.HasText("kept needle") {
		t.Errorf("%q", tt.Texts())
	}
}

// A row shows its match however far along its line it is.
func TestHitText(t *testing.T) {
	long := "    " + strings.Repeat("x", 200)
	line := long + "needle tail"
	before, match, after := hitText(line, len(long), len(long)+6)
	if match != "needle" || after != " tail" || len([]rune(before)) != hitContext+1 || !strings.HasPrefix(before, "…") {
		t.Errorf("%q %q %q", before, match, after)
	}
	before, match, after = hitText("  short needle", 8, 14)
	if before != "short " || match != "needle" || after != "" {
		t.Errorf("%q %q %q", before, match, after)
	}
}

// Stopping nothing is nothing.
func TestStopPaneSearchIdle(t *testing.T) {
	a := testApp(t)
	a.stopPaneSearch()
	if a.searching() {
		t.Error("searching with no search")
	}
}

// BenchmarkPaletteHits is a frame of the palette listing as many hits as it
// ever does.
func BenchmarkPaletteHits(b *testing.B) {
	home := b.TempDir()
	b.Setenv("KERO_HOME", home)
	b.Setenv("KERO_CONFIG", home+"/config")
	a := newApp()
	a.st = proto.State{Sessions: []proto.Session{{ID: "s1", Name: "demo", Panes: []proto.Pane{{ID: "a"}}, Focus: "a"}}}
	a.loaded, a.selected = true, "s1"
	a.local().loaded = true
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPaneSearch("needle")
	run := a.pal.run
	run.timer.Stop()
	run.hosts = []*hostSearch{{h: a.local()}}
	ms := make([]proto.SearchMatch, searchShownMost)
	for i := range ms {
		ms[i] = hit("a", fmt.Sprintf("some output line %d with a needle in it and more text after it", i), "needle", i)
	}
	a.takeHits(run, a.local(), ms)
	b.ResetTimer()
	for b.Loop() {
		tt.Frame()
	}
}
