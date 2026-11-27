package main

import (
	"testing"

	"github.com/egoist/mygo/i18n"
	"github.com/egoist/mygo/ui"

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
		for _, it := range a.paletteItems() {
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
	r, ok := tt.Find(a.paletteItems()[3].title)
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
	for _, it := range a.paletteItems() {
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

// An arrow given while the list was of sessions, then acted on once the
// user typed and the row chosen is a command, does nothing.
func TestPaletteStaleArrow(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Type("settings")
	tt.Key(0, ui.KeyRight)
	tt.Frame()
	a.pal.query, a.pal.arrow, a.pal.index = "", 1, 99
	tt.Frame()
	a.pal.arrow, a.pal.only = -1, true
	tt.Frame()
	if a.pal.expanded["s1"] {
		t.Error("a stale arrow expanded a session")
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
	for _, it := range a.paletteMatches() {
		if it.pane != nil {
			t.Errorf("pane %q found by its session's name", it.title)
		}
	}
}
