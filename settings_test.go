package main

import (
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/actions"
	"kero/internal/settings"
)

// Every page builds, and shows its settings.
func TestSettingsPages(t *testing.T) {
	a := testApp(t)
	a.ss.draft = map[string]string{}
	tt := ui.NewTester(a.settingsView, 820, 900)
	want := map[string]string{
		"general": "Restore sessions after a restart", "appearance": "Translucent window", "terminal": "Line height",
		"shell": "Scrollback", "notifications": "A session needs me", "keyboard": "Split Right",
		"agents": "Let commands drive this window", "advanced": "Background service",
	}
	for _, p := range settingsPages {
		if p.id == "notifications" {
			continue // asks the system whether it can notify: needs the app
		}
		a.ss.page = p.id
		tt.Frame()
		if !tt.HasText(want[p.id]) {
			t.Errorf("page %s: no %q; texts %q", p.id, want[p.id], tt.Texts())
		}
		shot(t, tt, "settings-"+p.id)
	}
}

// A shortcut is typed into its chip, saved, and takes the keys from the
// action that had them.
func TestRecordShortcut(t *testing.T) {
	a := testApp(t)
	a.ss.draft = map[string]string{}
	a.ss.page = "keyboard"
	tt := ui.NewTester(a.settingsView, 820, 1100)
	tt.Frame()
	if err := tt.Click("Shortcut for Split Right"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	// Split Down's keys.
	mods, key, accel := ui.Super|ui.Shift, ui.KeyD, "CmdOrCtrl+Shift+D"
	if runtime.GOOS != "darwin" {
		mods, key, accel = ui.Alt|ui.Shift, ui.KeyMinus, "Alt+Shift+-"
	}
	tt.Key(mods, key)
	tt.Frame()
	tt.Frame()
	if got := a.set.Shortcuts["pane.split.right"]; got != accel {
		t.Fatalf("Split Right's shortcut %q", got)
	}
	if got, ok := a.set.Shortcuts["pane.split.down"]; !ok || got != "" {
		t.Errorf("Split Down kept its keys: %q", got)
	}
	if !tt.HasText(actions.Glyphs(accel) + " was Split Down’s: it has none now.") {
		t.Errorf("no word of the conflict; texts %q", tt.Texts())
	}
	if saved := settings.Load(); saved.Shortcuts["pane.split.right"] != accel {
		t.Errorf("not saved: %v", saved.Shortcuts)
	}
	shot(t, tt, "settings-keyboard-recorded")
}

// A choice made in a segmented control stays, and is saved.
func TestSegmentedChoiceSticks(t *testing.T) {
	a := testApp(t)
	a.ss.page = "appearance"
	tt := ui.NewTester(a.settingsView, 820, 640)
	tt.Frame()
	if err := tt.Click("Light"); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if a.set.Appearance != "light" {
		t.Fatalf("appearance %q after choosing Light", a.set.Appearance)
	}
	if got := settings.Load().Appearance; got != "light" {
		t.Fatalf("saved appearance %q", got)
	}
	if err := tt.Click("System"); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if a.set.Appearance != "system" || settings.Load().Appearance != "system" {
		t.Fatalf("appearance %q, saved %q, after choosing System", a.set.Appearance, settings.Load().Appearance)
	}
}

// Dark pages, and the plain background, for a look ($KERO_SHOTS).
func TestDarkShots(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.settingsView, 820, 640)
	tt.SetDark(true)
	for _, p := range []string{"advanced", "terminal", "appearance"} {
		a.ss.page = p
		tt.Frame()
		shot(t, tt, "dark-"+p)
	}
	a.set.Background = "plain"
	a.applied = a.set.Clone()
	main := ui.NewTester(a.view, 1000, 560)
	main.SetDark(true)
	main.Frame()
	main.Advance(time.Second) // colors ease from the light frame's
	main.Frame()
	shot(t, main, "dark-plain-main")
}

// The segmented control, light and dark, for a look ($KERO_SHOTS).
func TestSegmentedShots(t *testing.T) {
	for _, dark := range []bool{false, true} {
		a := testApp(t)
		a.ss.page = "appearance"
		a.set.Appearance = "light"
		a.applied = a.set.Clone()
		tt := ui.NewTester(a.settingsView, 820, 240)
		tt.SetDark(dark)
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		name := "segmented-light"
		if dark {
			name = "segmented-dark"
		}
		shot(t, tt, name)
	}
}

// The pop-up button with its menu open, and a focused field, light and
// dark ($KERO_SHOTS).
func TestControlShots(t *testing.T) {
	for _, dark := range []bool{false, true} {
		a := testApp(t)
		a.ss.page = "shell"
		tt := ui.NewTester(a.settingsView, 820, 520)
		tt.SetDark(dark)
		tt.Frame()
		tt.Advance(time.Second)
		if err := tt.Click("4 MB"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		if !tt.HasText("64 MB") {
			t.Fatalf("the scrollback menu did not open; texts %q", tt.Texts())
		}
		name := map[bool]string{false: "light", true: "dark"}[dark]
		shot(t, tt, "controls-menu-"+name)
		tt.Key(0, ui.KeyDown)
		tt.Key(0, ui.KeyEnter)
		tt.Frame()
		if a.set.Scrollback != 16 {
			t.Errorf("chose scrollback %d, want 16", a.set.Scrollback)
		}
		if err := tt.Click("NAME=value"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		shot(t, tt, "controls-field-"+name)
	}
}

// The line height slider: a click on its track sets it ($KERO_SHOTS).
func TestSlider(t *testing.T) {
	for _, dark := range []bool{false, true} {
		a := testApp(t)
		a.ss.page = "terminal"
		tt := ui.NewTester(a.settingsView, 820, 640)
		tt.SetDark(dark)
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		shot(t, tt, "slider-"+map[bool]string{false: "light", true: "dark"}[dark])
		label, ok := tt.Find("1.22×")
		if !ok {
			t.Fatalf("no line height; texts %q", tt.Texts())
		}
		// The slider ends 8 DIPs left of its label: near its end, 2×.
		tt.ClickAt(label.X-16, label.Y+label.H/2)
		tt.Frame()
		tt.Frame()
		if a.set.LineHeight < 1.85 {
			t.Errorf("line height %v after a click near the slider's end", a.set.LineHeight)
		}
		// Held, the knob is a lens of glass. (The taller lines moved
		// the slider down.)
		label, _ = tt.Find("2.00×")
		tt.Press(label.X-16, label.Y+label.H/2)
		tt.Frame()
		tt.Advance(400 * time.Millisecond)
		tt.Frame()
		shot(t, tt, "slider-held-"+map[bool]string{false: "light", true: "dark"}[dark])
		tt.Release(label.X-16, label.Y+label.H/2)
		tt.Frame()
	}
}

// kero's font registers from the source tree, and the terminals take it
// by default ($KERO_SHOTS shows the preview in it).
func TestBundledFont(t *testing.T) {
	loadFonts()
	if !fontsLoaded {
		t.Fatal("the bundled fonts did not register")
	}
	a := testApp(t)
	if got := a.termFont().Family; got != bundledFont {
		t.Errorf("default terminal font %q, want %q", got, bundledFont)
	}
	a.set.FontFamily = "monospace"
	if got := a.termFont().Family; got != "monospace" {
		t.Errorf("System picked, terminal font %q", got)
	}
	a.set.FontFamily = ""
	a.ss.page = "terminal"
	tt := ui.NewTester(a.settingsView, 820, 320)
	tt.Frame()
	if !tt.HasText("JetBrains Mono Nerd Font") {
		t.Errorf("the picker does not show the bundled font; texts %q", tt.Texts())
	}
	shot(t, tt, "font-preview")
}

// A page scrolled under its header frosts there ($KERO_SHOTS).
func TestScrollEdgeShots(t *testing.T) {
	for _, dark := range []bool{false, true} {
		a := testApp(t)
		a.ss.page = "keyboard"
		tt := ui.NewTester(a.settingsView, 820, 520)
		tt.SetDark(dark)
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		// The bar's bottom edge, over the card: no hairline at the top of
		// the page, one once scrolled.
		edgeRow := func() [3]uint8 {
			c := tt.Image().RGBAAt(600, cardGap+headerH-1)
			return [3]uint8{c.R, c.G, c.B}
		}
		top := edgeRow()
		card := tt.Image().RGBAAt(600, cardGap+headerH+2)
		if top != [3]uint8{card.R, card.G, card.B} {
			t.Errorf("dark %v: a hairline at the top of the page: %v over a card of %v", dark, top, card)
		}
		tt.Scroll(500, 300, 0, 130)
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		if edgeRow() == top {
			t.Errorf("dark %v: no edge once scrolled", dark)
		}
		shot(t, tt, "scroll-edge-"+map[bool]string{false: "light", true: "dark"}[dark])
	}
}

// The sidebar's search finds settings by label, by their keys in the
// configuration file, and by other words; it shows only the pages with
// finds, the first of them when the page shown has none.
func TestSettingsSearch(t *testing.T) {
	a := testApp(t)
	a.ss.draft = map[string]string{}
	a.ss.page = "general"
	tt := ui.NewTester(a.settingsView, 820, 640)
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyF)
	tt.Frame()
	tt.Type("font-size")
	for range 3 {
		tt.Frame()
	}
	if a.ss.query != "font-size" {
		t.Fatalf("⌘F then typing: query %q", a.ss.query)
	}
	if a.ss.page != "terminal" || !searchHits["Size"] || searchHits["Font"] {
		t.Errorf("font-size: page %s, hits %v", a.ss.page, searchHits)
	}
	if tt.HasText("General") || !tt.HasText("Terminal") {
		t.Errorf("sidebar of pages without finds; texts %q", tt.Texts())
	}
	shot(t, tt, "settings-search-font-size")

	// Not the notifications page: it asks the system, which needs the app.
	for q, page := range map[string]string{"vibrancy": "appearance", "osc 52": "terminal", "split right": "keyboard", "kerod": "advanced", "remote-control": "agents", "fish": "shell"} {
		a.ss.query = q
		tt.Frame()
		if a.ss.page != page {
			t.Errorf("%q: page %s, want %s", q, a.ss.page, page)
		}
	}
	a.ss.page = "agents"
	a.ss.query = "vibe"
	tt.Frame()
	if a.ss.page != "agents" || !searchHits["Codex, OpenCode, Pi, Vibe"] || !tt.HasText("Codex, OpenCode, Pi, Vibe") {
		t.Errorf("Vibe skill not found: page %s, hits %v, texts %q", a.ss.page, searchHits, tt.Texts())
	}
	tt.Advance(time.Second)
	tt.Frame()
	shot(t, tt, "settings-search-vibe")

	a.ss.page = "general"
	tt.Frame()
	if !searchHits["Resume agents"] || !tt.HasText("Resume agents") {
		t.Errorf("Vibe resume not found: hits %v, texts %q", searchHits, tt.Texts())
	}
	tt.Advance(time.Second)
	tt.Frame()
	shot(t, tt, "settings-search-vibe-resume")

	a.ss.query = "split right"
	tt.Frame()
	if !tt.HasText("Split Right") || tt.HasText("Split Down") {
		t.Errorf("keyboard page unfiltered; texts %q", tt.Texts())
	}
	shot(t, tt, "settings-search-keyboard")

	a.ss.query = "zzzz"
	tt.Frame()
	if !tt.HasText("No Results") {
		t.Errorf("no word of no results; texts %q", tt.Texts())
	}
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	if a.ss.query != "" || !tt.HasText("General") {
		t.Errorf("Escape: query %q", a.ss.query)
	}
}

// Pop-up buttons open their menu over themselves; the font and theme
// pickers search theirs ($KERO_SHOTS).
func TestPopupButtons(t *testing.T) {
	for _, dark := range []bool{false, true} {
		name := map[bool]string{false: "light", true: "dark"}[dark]
		a := testApp(t)
		a.ss.page = "terminal"
		tt := ui.NewTester(a.settingsView, 820, 900)
		tt.SetDark(dark)
		tt.Frame()
		tt.Advance(time.Second)
		shot(t, tt, "popup-rest-"+name)
		r, ok := tt.Find("Regular")
		if !ok {
			t.Fatalf("no weight button; texts %q", tt.Texts())
		}
		tt.Move(r.X+r.W/2, r.Y+r.H/2)
		tt.Advance(time.Second)
		tt.Frame()
		shot(t, tt, "popup-hover-"+name)
		tt.ClickAt(r.X+r.W/2, r.Y+r.H/2)
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		if !tt.HasText("Semibold") {
			t.Fatalf("the weight menu did not open; texts %q", tt.Texts())
		}
		// The current item lies on the button.
		if got, ok := tt.Find("Medium"); !ok || got.Y > r.Y+r.H+menuItemH || got.Y < r.Y-r.H {
			t.Errorf("Medium at %v, the button at %v: the menu is not over it", got, r)
		}
		shot(t, tt, "popup-open-"+name)
		tt.Key(0, ui.KeyDown)
		tt.Key(0, ui.KeyEnter)
		tt.Frame()
		if a.set.FontWeight != 500 {
			t.Errorf("chose weight %d, want 500", a.set.FontWeight)
		}

		// The theme picker: typing filters, Return chooses.
		if err := tt.Click("kero"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		tt.Type("catppuccin mocha")
		tt.Frame()
		shot(t, tt, "popup-search-"+name)
		tt.Key(0, ui.KeyEnter)
		tt.Frame()
		if a.set.LightTheme != "Catppuccin Mocha" {
			t.Errorf("light theme %q, want Catppuccin Mocha", a.set.LightTheme)
		}
		if a.ss.menus["light"].open {
			t.Error("the theme menu stayed open")
		}

		// The font picker takes a font it does not list.
		if err := tt.Click("JetBrains Mono Nerd Font"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Type("Iosevka Term, Symbols Nerd Font")
		tt.Frame()
		if !tt.HasText("Use “Iosevka Term, Symbols Nerd Font”") {
			t.Errorf("no custom font offered; texts %q", tt.Texts())
		}
		tt.Key(0, ui.KeyEnter)
		tt.Frame()
		if a.set.FontFamily != "Iosevka Term, Symbols Nerd Font" {
			t.Errorf("font %q", a.set.FontFamily)
		}
	}
}

// A pop-up button's menu opens over it, its current item on the button,
// and stays in the window: near the window's bottom it moves up, where
// it once went above the button, and further up, cut off by the top.
func TestPopupMenuStaysInWindow(t *testing.T) {
	for _, h := range []int{900, 400} {
		a := testApp(t)
		a.ss.page = "terminal"
		a.set.FontSize = 15
		tt := ui.NewTester(a.settingsView, 820, h)
		tt.Frame()
		r, ok := tt.Find("15 pt")
		if !ok {
			t.Fatalf("h %d: no size button; texts %q", h, tt.Texts())
		}
		tt.ClickAt(r.X+r.W/2, r.Y+r.H/2)
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		shot(t, tt, fmt.Sprintf("popup-size-%d", h))
		for _, item := range []string{"10 pt", "28 pt"} {
			got, ok := tt.Find(item)
			if !ok || got.Y < 0 || got.Y+got.H > float32(h) {
				t.Errorf("h %d: %s at %v, out of the window", h, item, got)
			}
		}
		items := 0
		for _, txt := range tt.Texts() {
			if txt == "15 pt" {
				items++
			}
		}
		if items < 2 {
			t.Fatalf("h %d: the menu did not open; texts %q", h, tt.Texts())
		}
		at, _ := tt.Find("12 pt")
		if h == 900 {
			// Room enough: 15 pt lies on the button, three items under 12 pt.
			if d := r.Y - (at.Y + 3*menuItemH); d < -4 || d > 4 {
				t.Errorf("h %d: 12 pt at %v, the button at %v: 15 pt is not on the button", h, at, r)
			}
		}
		tt.Key(0, ui.KeyEscape)
		tt.Frame()
	}
}

// The font menu stays in the window, however little room the window has
// below its button.
func TestSearchMenuStaysInWindow(t *testing.T) {
	for _, h := range []int{900, 420} {
		a := testApp(t)
		a.ss.page = "terminal"
		tt := ui.NewTester(a.settingsView, 820, h)
		tt.Frame()
		if err := tt.Click("JetBrains Mono Nerd Font"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		shot(t, tt, fmt.Sprintf("search-menu-%d", h))
		for _, txt := range []string{"Search", "System"} {
			r, ok := tt.Find(txt)
			if !ok || r.Y < 0 || r.Y+r.H > float32(h) {
				t.Errorf("h %d: %s at %v, out of the window", h, txt, r)
			}
		}
		// The menu's bottom: the last item shown is inside the window.
		var low float32
		for _, f := range fontChoices {
			if r, ok := tt.Find(f); ok && r.Y > low {
				low = r.Y + r.H
			}
		}
		if low > float32(h) {
			t.Errorf("h %d: the menu runs to %g, past the window", h, low)
		}
	}
}

// Moving the pointer along a search menu highlights one item at a time,
// on the line between two items too.
func TestSearchMenuOneHighlight(t *testing.T) {
	a := testApp(t)
	a.ss.page = "terminal"
	tt := ui.NewTester(a.settingsView, 820, 900)
	tt.Frame()
	if err := tt.Click("JetBrains Mono Nerd Font"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	for _, f := range []string{"Monaco", "JetBrains Mono", "Fira Code", "Cascadia Code", "SF Mono"} {
		r, ok := tt.Find(f)
		if !ok {
			t.Fatalf("no %s; texts %q", f, tt.Texts())
		}
		// On the line between f and the item above it, which both rows
		// take for theirs.
		tt.Move(r.X+r.W/2, r.Y-(menuItemH-r.H)/2)
		for range 3 {
			tt.Frame()
		}
		if tt.FramePending() {
			t.Errorf("pointer by %s: the menu keeps building", f)
		}
		// One accent row: count the accent's pixels down the menu's left.
		lit, in := 0, false
		img := tt.Image()
		x := int(r.X) - 8
		for y := 0; y < img.Bounds().Dy(); y++ {
			cr, cg, cb, _ := img.At(x, y).RGBA()
			acc := cb>>8 > 200 && cr>>8 < 140 && cg>>8 < 160
			if acc && !in {
				lit++
			}
			in = acc
		}
		if lit != 1 {
			t.Errorf("pointer on %s: %d rows lit", f, lit)
		}
	}
}

// A search menu holds the window as macOS's do: the page does not scroll
// under it, and a press outside it closes it, going no further.
func TestSearchMenuIsModal(t *testing.T) {
	a := testApp(t)
	a.ss.page = "terminal"
	tt := ui.NewTester(a.settingsView, 820, 600)
	tt.Frame()
	open := func() {
		t.Helper()
		if err := tt.Click("JetBrains Mono Nerd Font"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
		if !a.ss.menus["font"].open {
			t.Fatal("the font menu did not open")
		}
	}
	open()
	tt.Scroll(400, 500, 0, 120)
	tt.Frame()
	if y := a.ss.scrolls["terminal"].Y; y != 0 {
		t.Errorf("the page scrolled %g under the menu", y)
	}
	if !a.ss.menus["font"].open {
		t.Error("the wheel closed the menu")
	}
	// The menu's own list still scrolls.
	before, _ := tt.Find("System")
	tt.Scroll(before.X+20, before.Y, 0, 120)
	tt.Frame()
	if after, ok := tt.Find("System"); ok && after.Y == before.Y {
		t.Error("the menu's list does not scroll")
	}
	// A press on the sidebar's General: the menu closes, the page stays.
	r, _ := tt.Find("General")
	tt.ClickAt(r.X+r.W/2, r.Y+r.H/2)
	tt.Frame()
	if a.ss.menus["font"].open {
		t.Error("a press outside left the menu open")
	}
	if a.ss.page != "terminal" {
		t.Errorf("the press outside the menu went on: page %s", a.ss.page)
	}
	// Closed, the page scrolls again.
	tt.Scroll(400, 500, 0, 120)
	tt.Frame()
	if a.ss.scrolls["terminal"].Y == 0 {
		t.Error("the page does not scroll once the menu closed")
	}
}
