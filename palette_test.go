package main

import (
	"strings"
	"testing"

	"github.com/egoist/mygo/i18n"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/locales"
)

// The palette finds commands by their keywords and English names, in a
// language whose titles have neither.
func TestPaletteKeywords(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	i18n.SetLocaleFunc(func() string { return "zh-Hans" })
	t.Cleanup(func() { i18n.SetLocaleFunc(nil) })
	a.openPalette()
	tt.Frame()
	for query, want := range map[string]string{
		"browser":  locales.In("zh-Hans").ActionNewBrowser(),
		"adblock":  locales.In("zh-Hans").PaletteSettingsPage(locales.In("zh-Hans").PageBrowser()),
		"maximize": locales.In("zh-Hans").ActionZoomPane(),
	} {
		a.pal.query = ""
		tt.Frame()
		tt.Type(query)
		tt.Frame()
		if !tt.HasText(want) {
			t.Errorf("%q finds no %q; texts %q", query, want, tt.Texts())
		}
	}
	// Keywords match by their starts, not as letters strewn through them.
	if keywords("bsr", actionWords["pane.browser"]) >= 0 {
		t.Error("keywords matched letters in order")
	}
}

// The palette offers the modes of Keep computer awake, found by their
// English names in any language, but for the one it is in.
func TestPaletteKeepAwake(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	i18n.SetLocaleFunc(func() string { return "zh-Hans" })
	t.Cleanup(func() { i18n.SetLocaleFunc(nil) })
	zh := locales.In("zh-Hans")
	title := func(mode string) string { return zh.AwakeTitle() + ": " + awakeModeIn(zh, mode) }
	offers := func(mode string) *paletteItem {
		for _, it := range a.paletteItems(a.pal.query) {
			if it.title == title(mode) {
				return &it
			}
		}
		return nil
	}
	a.openPalette()
	tt.Frame()
	tt.Type("while agents")
	tt.Frame()
	if !tt.HasText(title(awakeAgents)) {
		t.Errorf("no %q found; texts %q", title(awakeAgents), tt.Texts())
	}
	if offers(awakeOff) != nil {
		t.Error("the palette offers the mode it is in")
	}
	offers(awakeAgents).run()
	if a.set.KeepAwake != awakeAgents {
		t.Errorf("the mode is %q, want %q", a.set.KeepAwake, awakeAgents)
	}
	if offers(awakeAgents) != nil || offers(awakeOff) == nil {
		t.Error("the palette's modes did not follow the choice")
	}
}

// The wheel scrolls the palette's list away from the one chosen.
func TestPaletteScrolls(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 900)
	a.openPalette()
	tt.Frame()
	r, ok := tt.Find(a.paletteItems(a.pal.query)[3].title)
	if !ok {
		t.Fatalf("no commands shown; texts %q", tt.Texts())
	}
	tt.Scroll(r.X+20, r.Y, 0, 300)
	tt.Frame()
	tt.Frame()
	if y := a.pal.scroll.Y; y < 100 {
		t.Errorf("the wheel scrolled the palette to %g, want 300", y)
	}
}

// Return presses the action of a confirmation, though Cancel comes first.
func TestConfirmReturnRunsAction(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	ran := false
	a.confirm = &confirmation{
		open:   true,
		title:  "Close this pane?",
		detail: "claude is still running in it.",
		action: "Close Pane",
		run:    func() { ran = true },
	}
	tt.Frame()
	if !tt.Focused("Close Pane") {
		t.Fatal("the action button does not have the focus")
	}
	tt.Key(0, ui.KeyEnter)
	if !ran || a.confirm != nil {
		t.Fatalf("Return ran the action %v and left the confirmation %v", ran, a.confirm)
	}
}

// Escape cancels a confirmation.
func TestConfirmEscapeCancels(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	ran := false
	a.confirm = &confirmation{
		open:   true,
		title:  "Close this pane?",
		detail: "claude is still running in it.",
		action: "Close Pane",
		run:    func() { ran = true },
	}
	tt.Frame()
	tt.Key(0, ui.KeyEscape)
	if ran || a.confirm != nil {
		t.Fatalf("Escape ran the action %v and left the confirmation %v", ran, a.confirm)
	}
}

// A space of the query is no letter of the item's: it takes none, which
// it did, so a query with a space of its own found nothing.
func TestFuzzySkipsQuerySpaces(t *testing.T) {
	for _, c := range []struct{ query, s string }{
		{"a b", "ab"},
		{"new  session", "New Session"},
		{"split right", "Split Right"},
		{"my file", "myfile"},
	} {
		if got := fuzzy(c.query, c.s); got < 0 {
			t.Errorf("fuzzy(%q, %q) = %d, want a match", c.query, c.s, got)
		}
	}
	// What is no letter of the query in the item is still no match.
	if got := fuzzy("a b", "ac"); got != -1 {
		t.Errorf("fuzzy(%q, %q) = %d, want no match", "a b", "ac", got)
	}
}

// paletteHasPane tells whether the palette's list offers a pane by its name.
func paletteHasPane(a *App, name string) bool {
	for _, it := range a.paletteItems(a.pal.query) {
		if it.pane != nil && it.title == name {
			return true
		}
	}
	return false
}

// The palette shows a session's panes when the user types, or when the
// session is expanded; → expands it and goes into its panes, ← goes back
// out, and Return moves the user into the pane chosen.
func TestPalettePanes(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	if paletteHasPane(a, "zsh") {
		t.Fatal("panes shown before the user typed or expanded")
	}
	if a.pal.index != 0 || a.pal.expanded["s1"] {
		t.Fatalf("index %d, expanded %v", a.pal.index, a.pal.expanded)
	}
	tt.Key(0, ui.KeyRight)
	tt.Frame()
	if !a.pal.expanded["s1"] || !paletteHasPane(a, "fish") || !paletteHasPane(a, "zsh") {
		t.Fatalf("→ didn't show the session's panes; expanded %v", a.pal.expanded)
	}
	tt.Key(0, ui.KeyRight)
	tt.Frame()
	if a.pal.index != 1 {
		t.Fatalf("→ again chose %d, want the first pane", a.pal.index)
	}
	tt.Key(0, ui.KeyLeft)
	tt.Frame()
	if a.pal.index != 0 || a.pal.expanded["s1"] {
		t.Fatalf("← left index %d, expanded %v", a.pal.index, a.pal.expanded)
	}
	tt.Key(0, ui.KeyRight)
	tt.Key(0, ui.KeyRight)
	tt.Key(0, ui.KeyDown)
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if a.pal.open {
		t.Fatal("Return didn't close the palette")
	}
	if s := a.session("s1"); a.focusOf(s) != "b" {
		t.Errorf("in pane %q, want b", a.focusOf(s))
	}
}

// Typed, the palette finds a pane by its name, and goes into it.
func TestPaletteFindsPane(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Type("zsh")
	tt.Frame()
	if !paletteHasPane(a, "zsh") {
		t.Fatal("no zsh pane found")
	}
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if s := a.session("s1"); a.focusOf(s) != "b" {
		t.Errorf("in pane %q, want b", a.focusOf(s))
	}
}

// Clicking a session's pane count shows its panes, and chooses nothing.
func TestPaletteExpandClick(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	if err := tt.Click(locales.SidebarShowPanes()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !a.pal.open {
		t.Fatal("the click chose the session")
	}
	if !a.pal.expanded["s1"] || !paletteHasPane(a, "zsh") {
		t.Errorf("the click didn't show the panes; expanded %v", a.pal.expanded)
	}
	if err := tt.Click(locales.SidebarHidePanes()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.pal.expanded["s1"] || !a.pal.open {
		t.Errorf("the click didn't hide the panes, or closed the palette")
	}
}

// After a click on the count, the field still has the keyboard: → goes
// into the panes, Return goes to the one chosen, and typing searches.
func TestPaletteKeysAfterClick(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	if err := tt.Click(locales.SidebarShowPanes()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	tt.Key(0, ui.KeyRight)
	tt.Frame()
	if a.pal.index != 1 {
		t.Fatalf("→ after the click chose %d, want the first pane", a.pal.index)
	}
	tt.Type("zs")
	tt.Frame()
	if a.pal.query != "zs" {
		t.Fatalf("typing after the click left the query %q", a.pal.query)
	}
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if a.pal.open {
		t.Fatal("Return after the click didn't choose")
	}
	if s := a.session("s1"); a.focusOf(s) != "b" {
		t.Errorf("in pane %q, want b", a.focusOf(s))
	}
}

// Arrows that come before a frame are acted on in the order pressed, on
// the list as each leaves it, and do nothing to a row that isn't a
// session or a pane.
func TestPaletteArrowsInOrder(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	a.pal.keys = []paletteInput{{key: ui.KeyRight}, {key: ui.KeyRight}, {key: ui.KeyDown}}
	tt.Frame()
	if a.pal.index != 2 || !paletteHasPane(a, "zsh") {
		t.Fatalf("→ → ↓ chose %d, want the second pane", a.pal.index)
	}
	if it := a.paletteMatches(a.pal.query)[a.pal.index]; it.pane == nil || it.pane.ID != "b" {
		t.Fatalf("→ → ↓ chose %q, want pane b", it.title)
	}
	a.pal.keys = []paletteInput{{key: ui.KeyUp}, {key: ui.KeyLeft}, {key: ui.KeyDown}}
	tt.Frame()
	if a.pal.expanded["s1"] || a.pal.index != 1 {
		t.Fatalf("↑ ← ↓ left index %d, expanded %v; want the row after the session", a.pal.index, a.pal.expanded)
	}
	a.pal.keys = []paletteInput{{key: ui.KeyRight}, {key: ui.KeyLeft}}
	tt.Frame()
	if a.pal.expanded["s1"] || a.pal.index != 1 {
		t.Errorf("arrows on a command changed the list: index %d, expanded %v", a.pal.index, a.pal.expanded)
	}
}

func TestPaletteReturnBeforeArrow(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Key(0, ui.KeyRight)
	tt.Key(0, ui.KeyRight)
	a.pal.keys = []paletteInput{{key: ui.KeyEnter}, {key: ui.KeyDown}}
	tt.Frame()
	if a.pal.open || a.focusOf(a.session("s1")) != "a" {
		t.Fatalf("Return followed by Down should open pane a, focus %q", a.focusOf(a.session("s1")))
	}
}

func TestPaletteExpandBeforeTyping(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	a.pal.keys = []paletteInput{{key: ui.KeyRight}}
	tt.Type("zsh")
	if !a.pal.expanded["s1"] || a.pal.resultsQuery != "zsh" {
		t.Fatalf("Right followed by typing left expanded %v, results for %q", a.pal.expanded, a.pal.resultsQuery)
	}
}

func TestPaletteScrollWhenMovingIntoPanes(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	a.pal.keys = []paletteInput{{key: ui.KeyRight}, {key: ui.KeyRight}}
	tt.Frame()
	if a.pal.index != 1 || a.pal.scroll.Y != 0 {
		t.Fatalf("Right twice left index %d and scroll %g, want index 1 and scroll 0", a.pal.index, a.pal.scroll.Y)
	}
}

// Typed, panes are found by their own name, not their session's.
func TestPalettePaneMatchesOwnName(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Type("demo")
	tt.Frame()
	for _, it := range a.paletteMatches(a.pal.query) {
		if it.pane != nil {
			t.Errorf("pane %q found by its session's name", it.title)
		}
	}
}

// Typed, a pane is found by the folder its program runs in, and Ctrl+N
// and Ctrl+P choose as ↓ and ↑ do.
func TestPaletteFindsPaneByFolder(t *testing.T) {
	a := testApp(t)
	a.session("s1").PaneByID("b").ProcessDir = "/tmp/webapp"
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Key(ui.Ctrl, ui.KeyN)
	tt.Key(ui.Ctrl, ui.KeyN)
	tt.Key(ui.Ctrl, ui.KeyP)
	tt.Frame()
	if a.pal.index != 1 {
		t.Errorf("Ctrl+N Ctrl+N Ctrl+P chose %d, want 1", a.pal.index)
	}
	tt.Type("webapp")
	tt.Frame()
	items := a.paletteMatches(a.pal.query)
	if len(items) == 0 || items[0].pane == nil || items[0].pane.ID != "b" {
		t.Fatalf("webapp didn't find pane b first: %v", items)
	}
}

// Arrows on an empty list, as one made for a search that matched nothing,
// choose nothing and don't fail.
func TestPaletteArrowsOnEmptyList(t *testing.T) {
	a := testApp(t)
	a.pal.open = true
	a.pal.query = "\x00"
	a.pal.keys = []paletteInput{{key: ui.KeyDown, query: a.pal.query}, {key: ui.KeyEnter, query: a.pal.query}}
	if items, chosen := a.paletteKeys(); len(items) != 0 || a.pal.index != 0 || chosen != nil {
		t.Errorf("arrows on nothing left %d rows, index %d", len(items), a.pal.index)
	}
}

// A browser pane is found by its site and the parts of its path.
func TestURLWords(t *testing.T) {
	got := urlWords("https://www.github.com/egoist/kero")
	for _, w := range []string{"github.com", "github", "egoist", "kero"} {
		if !strings.Contains(" "+got+" ", " "+w+" ") {
			t.Errorf("urlWords lacks %q: %q", w, got)
		}
	}
	if got := urlWords("http://localhost:5173/app"); !strings.Contains(" "+got+" ", " 5173 ") || !strings.Contains(" "+got+" ", " localhost ") {
		t.Errorf("urlWords lacks the port or host: %q", got)
	}
	if got := urlWords("https://docs.github.com/en"); !strings.Contains(" "+got+" ", " github ") {
		t.Errorf("urlWords lacks the site under a subdomain: %q", got)
	}
	if urlWords("") != "" || urlWords("not a url") != "not a url" {
		t.Errorf("urlWords changed what isn't an address")
	}
}

// Tab leaves the keyboard in the field, past the count of panes: ↓ still
// chooses and typing still searches.
func TestPaletteTabStaysInField(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Key(0, ui.KeyTab)
	tt.Frame()
	tt.Key(0, ui.KeyDown)
	tt.Frame()
	if a.pal.index != 1 {
		t.Errorf("↓ after Tab chose %d, want 1", a.pal.index)
	}
	tt.Type("zsh")
	tt.Frame()
	if a.pal.query != "zsh" {
		t.Errorf("typing after Tab left the query %q", a.pal.query)
	}
}

// A click on the count is acted on in order with the keys: → after it
// goes into the panes it showed.
func TestPaletteClickThenRight(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	a.pal.keys = []paletteInput{{toggle: "s1"}, {key: ui.KeyRight}}
	tt.Frame()
	if !a.pal.expanded["s1"] || a.pal.index != 1 {
		t.Errorf("click then → left index %d, expanded %v; want the first pane", a.pal.index, a.pal.expanded)
	}
}

// Going to a pane from the palette opens its group in the sidebar and
// shows the session's panes there.
func TestPaletteShowsPaneInSidebar(t *testing.T) {
	a := testApp(t)
	g := a.groups()[0]
	a.prefs.Collapsed[g.key()] = true
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Type("zsh")
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if a.prefs.Collapsed[g.key()] || !a.prefs.Expanded["s1"] {
		t.Errorf("collapsed %v, expanded %v", a.prefs.Collapsed, a.prefs.Expanded)
	}
}

// A pane is found by its command, as a server it runs.
func TestPaletteFindsPaneByCommand(t *testing.T) {
	a := testApp(t)
	b := a.session("s1").PaneByID("b")
	b.Command, b.Runtime = []string{"vite", "--port", "5173"}, "node"
	for _, q := range []string{"vite", "node"} {
		items := a.paletteMatches(q)
		a.pal.matches = nil
		if len(items) == 0 || items[0].pane == nil || items[0].pane.ID != "b" {
			t.Errorf("%s didn't find pane b first", q)
		}
	}
}

// Return after → in the same frame picks from the list → made, with the
// session's panes in it.
func TestPaletteReturnAfterExpandSameFrame(t *testing.T) {
	a := testApp(t)
	a.openPalette()
	a.pal.keys = []paletteInput{{key: ui.KeyRight}, {key: ui.KeyDown}, {key: ui.KeyDown}, {key: ui.KeyEnter}}
	items, chosen := a.paletteKeys()
	if chosen == nil || items[a.pal.index].pane == nil || items[a.pal.index].pane.ID != "b" {
		t.Fatalf("→ ↓ ↓ ↩ chose index %d, want pane b", a.pal.index)
	}
	chosen()
	if s := a.session("s1"); a.focusOf(s) != "b" {
		t.Errorf("in pane %q, want b", a.focusOf(s))
	}
}

// Typed, an open pane that matches comes before a conversation of the
// past that matches better.
func TestPalettePanesBeforeConversations(t *testing.T) {
	a := testApp(t)
	a.session("s1").PaneByID("b").ProcessDir = "/tmp/webapp"
	a.pal.convs = []hostConversation{{host: a.hosts[0], Conversation: proto.Conversation{ID: "c1", Agent: "claude", Name: "webapp"}}}
	items := a.paletteMatches("webapp")
	if len(items) < 2 || items[0].pane == nil || items[len(items)-1].conv == nil {
		t.Fatalf("webapp didn't find pane b before the conversation: %d rows, first %q", len(items), items[0].title)
	}
	a.pal.matches, a.pal.only = nil, true
	if items := a.paletteMatches("webapp"); len(items) != 1 || items[0].conv == nil {
		t.Errorf("Resume Conversation… didn't find the conversation alone")
	}
}

// Typed, a split session is found by its own name, not by the folder of
// the pane it shows, which is listed itself: that pane shows once.
func TestPaletteSplitSessionNotFoundByPane(t *testing.T) {
	a := testApp(t)
	s := a.session("s1")
	s.ProcessDir, s.PaneByID("a").ProcessDir = "/tmp/webapp", "/tmp/webapp" // its lead pane's
	items := a.paletteMatches("webapp")
	if len(items) != 1 || items[0].pane == nil || items[0].pane.ID != "a" {
		t.Fatalf("webapp found %d rows, want pane a alone", len(items))
	}
	a.pal.matches = nil
	if items := a.paletteMatches("demo"); len(items) == 0 || items[0].kind() != paletteSession {
		t.Errorf("demo didn't find its session")
	}
}

// The selection stays on its row as rows come and go above it, as a
// session's panes do while the palette is open.
func TestPaletteSelectionFollowsRow(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	a.pal.keys = []paletteInput{{key: ui.KeyRight}, {key: ui.KeyRight}, {key: ui.KeyDown}}
	tt.Frame()
	if a.pal.index != 2 {
		t.Fatalf("→ → ↓ chose %d, want pane b", a.pal.index)
	}
	s := a.session("s1")
	s.Panes = append([]proto.Pane{{ID: "c", Shell: "bash", Dir: "/tmp", Status: proto.Idle, Progress: -1}}, s.Panes...)
	tt.Frame()
	if it := a.paletteMatches(a.pal.query)[a.pal.index]; it.pane == nil || it.pane.ID != "b" {
		t.Errorf("a new pane above moved the selection to %q", it.title)
	}
}

// Going to panes from the palette saves the sidebar's prefs without
// the sessions that are gone.
func TestPaletteForgetsGoneSessions(t *testing.T) {
	a := testApp(t)
	a.prefs.Expanded = map[string]bool{"gone": true}
	a.showInSidebar("", "s1", func() {})
	if a.prefs.Expanded["gone"] || !a.prefs.Expanded["s1"] {
		t.Errorf("expanded %v, want s1 alone", a.prefs.Expanded)
	}
}
