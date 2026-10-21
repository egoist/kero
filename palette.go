package main

import (
	"slices"
	"strings"
	"unicode"

	"github.com/egoist/mygo/ui"

	"kero/internal/actions"

	"kero/internal/proto"

	"kero/locales"
)

// paletteState is the command palette's: a field that finds sessions and
// commands as one types.
type paletteState struct {
	open   bool
	query  string
	index  int
	scroll ui.ScrollState
}

// paletteItem is a session or a command the palette offers.
type paletteItem struct {
	session *proto.Session
	title   string
	detail  string
	keys    string
	run     func()
	score   int
	words   string // what finds it besides its title and detail, unshown
}

func (a *App) openPalette() {
	a.pal = paletteState{open: true}
}

func (a *App) paletteItems() []paletteItem {
	var items []paletteItem
	names := map[string]string{}
	for _, p := range a.st.Projects {
		names[p.ID] = p.Name
	}
	for _, g := range a.groups() {
		for _, s := range g.sessions {
			id := s.ID
			detail := names[s.Project]
			if s.Process != "" {
				detail += " · " + s.Process
			}
			items = append(items, paletteItem{session: s, title: s.DisplayName(a.set.SessionName), detail: detail + " · " + proto.ShortDir(s.WorkDir()),
				run: func() { delete(a.prefs.Collapsed, s.Project); a.selectSession(id) }})
		}
	}
	var cmds []paletteItem
	for _, act := range actions.All {
		id := act.ID
		cmds = append(cmds, paletteItem{title: strings.TrimSuffix(actionTitle(act.ID), "…"), keys: actions.Glyphs(actions.Keys(act, a.set.Shortcuts)),
			words: actionWords[id], run: func() { a.run(id, nil) }})
	}
	for _, page := range settingsPages {
		id := page.id
		cmds = append(cmds, paletteItem{title: locales.PaletteSettingsPage(page.title()), run: func() { a.openSettings(id) }})
	}
	cmds = append(cmds, paletteItem{title: locales.PaletteRestartService(), detail: locales.PaletteRestartServiceDetail(), run: a.restartDaemon})
	for _, p := range a.st.Projects {
		id := p.ID
		cmds = append(cmds, paletteItem{title: locales.NewSessionIn(p.Name), detail: proto.ShortDir(p.Dir), run: func() { a.newSession(id) }})
	}
	return append(items, cmds...)
}

// fuzzy scores how well query matches s, as its letters in order: higher
// is better, -1 no match. Starts of words and runs score more.
func fuzzy(query, s string) int {
	if query == "" {
		return 0
	}
	q := []rune(strings.ToLower(query))
	r := []rune(strings.ToLower(s))
	score, qi, run := 0, 0, 0
	for i := 0; i < len(r) && qi < len(q); i++ {
		if q[qi] == ' ' {
			qi++
			continue
		}
		if r[i] == q[qi] {
			bonus := 1
			if i == 0 || !unicode.IsLetter(r[i-1]) && !unicode.IsDigit(r[i-1]) {
				bonus += 6
			}
			run++
			score += bonus + run*2
			qi++
		} else {
			run = 0
		}
	}
	if qi < len(q) {
		return -1
	}
	return score*10 - len(r)
}

func (a *App) paletteView(c *ui.Context, pal *palette) {
	if !a.pal.open {
		return
	}
	var items []paletteItem
	for _, it := range a.paletteItems() {
		sc := fuzzy(a.pal.query, it.title+" "+it.detail)
		if w := fuzzy(a.pal.query, it.words); w > sc && it.words != "" {
			sc = w
		}
		if t := fuzzy(a.pal.query, it.title); t >= 0 {
			sc = max(sc, t+50)
		}
		if sc < 0 {
			continue
		}
		it.score = sc
		items = append(items, it)
	}
	if a.pal.query != "" {
		slices.SortStableFunc(items, func(x, y paletteItem) int { return y.score - x.score })
	}
	a.pal.index = min(max(a.pal.index, 0), max(len(items)-1, 0))

	var chosen func()
	ui.DialogBase(c.Key("palette"), &a.pal.open, func(backdrop, panel ui.Element) {
		backdrop.Background(pal.overlay).Justify(ui.Start).Padding(84, 0, 0, 0)
		floating(panel.Width(600).MaxHeight(460).Radius(14).Background(pal.popover), pal).Clip().
			Label(locales.PaletteLabel())
		ui.Row(c).Height(50).Shrink(0).Padding(0, 16).Gap(10).AlignItems(ui.Center).Children(func() {
			ui.Icon(c, searchIcon).Size(16, 16).TextColor(pal.textMuted)
			in := ui.TextInputBase(c.Key("q"), &a.pal.query).Grow(1).FontSize(15).Placeholder(locales.PalettePlaceholder()).AutoFocus()
			if in.Changed() {
				a.pal.index = 0
			}
			if c.Shortcut(0, ui.KeyDown) || c.Shortcut(ui.Ctrl, ui.KeyN) {
				a.pal.index = min(a.pal.index+1, len(items)-1)
			}
			if c.Shortcut(0, ui.KeyUp) || c.Shortcut(ui.Ctrl, ui.KeyP) {
				a.pal.index = max(a.pal.index-1, 0)
			}
			if (in.Submitted() || c.Shortcut(0, ui.KeyEnter)) && len(items) > 0 {
				chosen = items[a.pal.index].run
			}
		})
		list := ui.Scroll(c.Key("results")).Grow(1).MinHeight(0).Padding(6).TrackScroll(&a.pal.scroll)
		list.Children(func() {
			if len(items) == 0 {
				ui.Text(c, locales.PaletteNoMatches()).FontSize(13).TextColor(pal.textFaint).Padding(12, 12)
			}
			lastKind := true
			for i, it := range items {
				isSession := it.session != nil
				if i > 0 && isSession != lastKind && a.pal.query == "" {
					ui.Text(c, locales.PaletteCommands()).FontSize(11.5).FontWeight(600).TextColor(pal.textFaint).Padding(10, 10, 4, 10)
				}
				lastKind = isSession
				row := ui.Row(c.Key(i)).Height(38).Padding(0, 10).Gap(10).AlignItems(ui.Center).Radius(8)
				if i == a.pal.index {
					row.Background(pal.accent.Alpha(0.12))
					row.ScrollIntoView()
				} else if row.Hovered() {
					row.Background(pal.rowHover)
				}
				if row.Clicked() {
					chosen = it.run
				}
				row.Children(func() {
					if isSession {
						statusIcon(c, pal, it.session.Status, it.session.Unread, 14)
					} else {
						ui.Icon(c, returnIcon).Size(14, 14).TextColor(pal.textFaint)
					}
					ui.Text(c, it.title).FontSize(13.5).TextColor(pal.text).SingleLine().Ellipsis("…").Shrink(0).MaxWidth(300)
					ui.Text(c, it.detail).FontSize(12.5).TextColor(pal.textFaint).SingleLine().Ellipsis("…").Grow(1).MinWidth(0)
					if it.keys != "" {
						kbd(c, pal, it.keys)
					}
				})
			}
		})
	})
	if chosen != nil {
		a.pal.open = false
		chosen()
	}
	if !a.pal.open && chosen == nil {
		a.focusTerminal()
	}
}

func (a *App) confirmView(c *ui.Context, pal *palette) {
	cf := a.confirm
	if cf == nil {
		return
	}
	run := false
	ui.DialogBase(c.Key("confirm"), &cf.open, func(backdrop, panel ui.Element) {
		backdrop.Background(pal.overlay)
		floating(panel.Width(380).Padding(22).Gap(8).Radius(14).Background(pal.popover), pal).Label(cf.title)
		ui.Text(c, cf.title).FontSize(15).FontWeight(650).TextColor(pal.text)
		ui.Text(c, cf.detail).FontSize(13).TextColor(pal.textMuted).LineHeight(1.4)
		ui.Row(c).Gap(8).Justify(ui.End).Margin(14, 0, 0, 0).Children(func() {
			if button(c, "cancel", locales.CommonCancel(), "esc", false, pal) {
				cf.open = false
			}
			if button(c, "ok", cf.action, "↩", true, pal) || c.Shortcut(0, ui.KeyEnter) {
				run = true
			}
		})
	})
	if run {
		cf.open = false
		cf.run()
	}
	if !cf.open {
		a.confirm = nil
		a.focusTerminal()
	}
}

// shortcuts are the window's keys that no menu item has.
func (a *App) shortcuts(c *ui.Context) {
	if a.pal.open || a.confirm != nil {
		return
	}
	keys := []ui.Key{ui.Key1, ui.Key2, ui.Key3, ui.Key4, ui.Key5, ui.Key6, ui.Key7, ui.Key8, ui.Key9}
	for i, k := range keys {
		if c.Shortcut(ui.Cmd, k) {
			ids := a.visibleOrder()
			if i < len(ids) {
				a.selectSession(ids[i])
			}
		}
	}
	if c.Shortcut(ui.Ctrl, ui.KeyTab) {
		a.selectOffset(1)
	}
	if c.Shortcut(ui.Ctrl|ui.Shift, ui.KeyTab) {
		a.selectOffset(-1)
	}
	if a.copyText != "" {
		c.WriteClipboard(a.copyText)
		c.Toast(locales.ToastCopied())
		a.copyText = ""
	}
}
