package main

import (
	"cmp"
	"math"
	"slices"
	"strings"
	"time"
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
	reveal bool // the chosen item scrolls into view, once
	// convs are the conversations the hosts' kerods remember, the last to
	// run first, as they come; only shows them alone (Resume
	// Conversation…), and gen tells the palette they came for.
	convs []hostConversation
	only  bool
	gen   int
	// expanded are the sessions whose panes the list shows under them
	// before the user types; typed, every pane that matches shows.
	expanded map[string]bool
	// left and right tell which arrow keys the field gives the list, as
	// the frame before found them, and arrow the one it gave: -1 ←, 1 →.
	left, right bool
	arrow       int
}

// hostConversation is a conversation a host's kerod remembers.
type hostConversation struct {
	host *host
	proto.Conversation
}

// recentConversations is how many conversations the palette shows before
// the user types.
const recentConversations = 5

// paletteItem is a session or a command the palette offers.
type paletteItem struct {
	session *proto.Session
	pane    *proto.Pane // a pane of session's, which the item goes to
	conv    *hostConversation
	title   string
	detail  string
	keys    string
	run     func()
	score   int
	words   string // what finds it besides its title and detail, unshown
	top     bool   // what the query asks for outright, before any match
}

func (a *App) openPalette() {
	a.pal = paletteState{open: true, reveal: true, gen: a.pal.gen + 1}
	a.loadConversations()
}

// openConversations opens the palette on the conversations alone.
func (a *App) openConversations() {
	a.openPalette()
	a.pal.only = true
}

// loadConversations asks every host's kerod for the conversations it
// remembers. An older one knows of none.
func (a *App) loadConversations() {
	gen := a.pal.gen
	for _, h := range a.hosts {
		cl := h.cl
		if cl == nil {
			continue
		}
		go func() {
			var list []proto.Conversation
			if cl.Call("conversations", nil, &list) != nil {
				return
			}
			a.update(func() {
				if a.pal.gen != gen || !a.pal.open {
					return
				}
				for _, cv := range list {
					a.pal.convs = append(a.pal.convs, hostConversation{h, cv})
				}
				slices.SortStableFunc(a.pal.convs, func(x, y hostConversation) int { return cmp.Compare(y.Updated, x.Updated) })
			})
		}()
	}
}

// conversationItems are the palette's conversations: those no pane runs,
// as a session the palette has already shows them; all of them with only.
func (a *App) conversationItems() []paletteItem {
	var items []paletteItem
	names := map[string]string{}
	for _, p := range a.st.Projects {
		names[p.ID] = p.Name
	}
	now := time.Now()
	for i := range a.pal.convs {
		cv := &a.pal.convs[i]
		if cv.Session != "" && !a.pal.only {
			continue
		}
		detail := cmp.Or(proto.AgentNames[cv.Agent], cv.Agent)
		if cv.Name != "" && cv.Title != "" {
			detail = cv.Title + " · " + detail
		}
		if n := names[cv.Project]; n != "" {
			detail += " · " + n
		}
		if cv.host.remote() {
			detail = cv.host.name + " · " + detail
		}
		if cv.Session != "" {
			detail += " · " + locales.PaletteConversationRunning()
		} else {
			detail += " · " + ago(cv.Updated, now)
		}
		items = append(items, paletteItem{conv: cv, title: cv.Label(), detail: detail,
			words: cv.Title + " " + cv.Name + " " + cv.Dir + " " + cv.Agent + " " + cv.ID,
			run:   func() { a.resumeConversation(cv.host, cv.Conversation) }})
	}
	return items
}

// resumeConversation shows the session running a conversation of a
// host's, or starts one resuming it, beside the session shown.
func (a *App) resumeConversation(h *host, cv proto.Conversation) {
	cl := h.cl
	if cl == nil {
		a.toast(locales.HostNotConnected(h.name))
		return
	}
	p := proto.ConversationParams{Agent: cv.Agent, ID: cv.ID}
	if cur := a.session(a.selected); cur != nil && a.hostOf(cur.ID) == h {
		p.Cols, p.Rows = cur.Cols, cur.Rows
		if cur.Project == cv.Project {
			p.After = cur.ID
		}
	}
	go func() {
		var s proto.Session
		err := cl.Call("conversation.resume", p, &s)
		a.update(func() {
			if err != nil {
				a.toast(err.Error())
				return
			}
			delete(a.prefs.Collapsed, s.Project)
			a.addPending(h, s)
			a.selectSession(s.ID)
		})
	}()
}

func (a *App) paletteItems() []paletteItem {
	if a.pal.only {
		return a.conversationItems()
	}
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
			h := a.hostOf(id)
			if h.remote() {
				detail = h.name + " · " + detail
			}
			items = append(items, paletteItem{session: s, title: s.DisplayName(a.set.SessionName), detail: detail + " · " + h.shortDir(s.WorkDir()),
				run: func() { delete(a.prefs.Collapsed, s.Project); a.selectSession(id) }})
			if len(s.Panes) > 1 && (a.pal.query != "" || a.pal.expanded[id]) {
				items = append(items, a.paneItems(s, h)...)
			}
		}
	}
	var cmds []paletteItem
	// Commands are found by their English names too, in any language.
	en := locales.In("en")
	// An address typed opens in a browser beside the pane the user is in.
	if q := strings.TrimSpace(a.pal.query); proto.IsAddress(q) && a.session(a.selected) != nil {
		cmds = append(cmds, paletteItem{title: locales.PaletteOpenInBrowser(), detail: proto.BrowserURL(q), top: true,
			run: func() { a.openBrowser(q) }})
	}
	for _, act := range actions.All {
		id := act.ID
		cmds = append(cmds, paletteItem{title: strings.TrimSuffix(actionTitle(act.ID), "…"), keys: actions.Glyphs(actions.Keys(act, a.set.Shortcuts)),
			words: act.Title + " " + actionWords[id], run: func() { a.run(id, nil) }})
	}
	for _, page := range settingsPages {
		id := page.id
		cmds = append(cmds, paletteItem{title: locales.PaletteSettingsPage(page.title()), words: "settings preferences " + id + " " + pageWords[id], run: func() { a.openSettings(id) }})
	}
	cmds = append(cmds, a.awakeCommands()...)
	cmds = append(cmds, paletteItem{title: locales.PaletteRestartService(), detail: locales.PaletteRestartServiceDetail(),
		words: en.PaletteRestartService() + " " + en.PaletteRestartServiceDetail(), run: a.restartDaemon})
	for _, p := range a.st.Projects {
		id := p.ID
		h := a.hostOf(id)
		detail := h.shortDir(p.Dir)
		if h.remote() {
			detail = h.name + " · " + detail
		}
		cmds = append(cmds, paletteItem{title: locales.NewSessionIn(p.Name), detail: detail, words: en.NewSessionIn(p.Name), run: func() { a.newSession(id) }})
	}
	for _, h := range a.hosts[1:] {
		cmds = append(cmds,
			paletteItem{title: locales.NewSessionIn(h.name), detail: h.addr.String(), words: en.NewSessionIn(h.name), run: func() { a.newSessionOn(h, "") }},
			paletteItem{title: locales.PickerTitle(h.name), detail: h.addr.String(), words: en.PickerTitle(h.name), run: func() { a.openProjectOn(h) }},
			paletteItem{title: locales.HostReconnectTo(h.name), detail: h.addr.String(), words: en.HostReconnectTo(h.name), run: func() { a.reconnectHost(h) }})
	}
	convs := a.conversationItems()
	if a.pal.query == "" && len(convs) > recentConversations {
		convs = convs[:recentConversations]
	}
	items = append(items, convs...)
	return append(items, cmds...)
}

// paneItems are the palette's items for the panes of a session, in its
// layout's order, each found by its own name, program and directory.
func (a *App) paneItems(s *proto.Session, h *host) []paletteItem {
	order := s.Layout.Panes()
	if len(order) != len(s.Panes) {
		order = order[:0]
		for _, p := range s.Panes {
			order = append(order, p.ID)
		}
	}
	name := s.DisplayName(a.set.SessionName)
	var items []paletteItem
	for _, pid := range order {
		p := s.PaneByID(pid)
		if p == nil {
			continue
		}
		detail := name
		if p.Process != "" {
			detail += " · " + p.Process
		}
		if p.Browser() {
			detail += " · " + p.URL
		} else if p.Dir != "" {
			detail += " · " + h.shortDir(p.Dir)
		}
		sid := s.ID
		items = append(items, paletteItem{session: s, pane: p, title: p.PaneName(), detail: detail,
			words: p.Title + " " + p.Process + " " + p.Agent + " " + p.Dir + " " + p.URL,
			run:   func() { a.goToPane(sid, pid) }})
	}
	return items
}

// goToPane shows a session and moves the user into one of its panes.
func (a *App) goToPane(sid, pid string) {
	s := a.session(sid)
	if s == nil {
		return
	}
	delete(a.prefs.Collapsed, s.Project)
	a.selectSession(sid)
	if s.PaneByID(pid) == nil {
		return
	}
	a.setFocus(s, pid)
	a.focusPane(pid)
}

// paletteArrow takes → and ← from the palette's field for its list, when
// the list has a use for them, for the next frame to act on.
func (a *App) paletteArrow(k ui.TextKey) bool {
	switch {
	case k.Mods != 0:
		return false
	case k.Key == ui.KeyRight && a.pal.right:
		a.pal.arrow = 1
	case k.Key == ui.KeyLeft && a.pal.left:
		a.pal.arrow = -1
	default:
		return false
	}
	return true
}

// expandPalette shows or hides the panes of a session under it.
func (a *App) expandPalette(sid string, open bool) {
	if a.pal.expanded == nil {
		a.pal.expanded = map[string]bool{}
	}
	if open {
		a.pal.expanded[sid] = true
	} else {
		delete(a.pal.expanded, sid)
	}
}

// What a palette's item is, which its group in the list goes by.
const (
	paletteSession = iota
	palettePane
	paletteConversation
	paletteCommand
)

func (it *paletteItem) kind() int {
	switch {
	case it.pane != nil:
		return palettePane
	case it.session != nil:
		return paletteSession
	case it.conv != nil:
		return paletteConversation
	}
	return paletteCommand
}

// fuzzy scores how well query matches s, as its letters in order: higher
// is better, -1 no match. Starts of words and runs score more. A space
// of the query is no letter: it takes none of the item's, which it did,
// and an item whose words are further apart was not found.
func fuzzy(query, s string) int {
	if query == "" {
		return 0
	}
	q := []rune(strings.ToLower(query))
	r := []rune(strings.ToLower(s))
	score, qi, run := 0, 0, 0
	for i := 0; i < len(r) && qi < len(q); {
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
		i++
	}
	if qi < len(q) {
		return -1
	}
	return score*10 - len(r)
}

// keywords scores how well query finds words, a list of them: each of its
// terms the start of one. Too many to match as letters in order, which
// any query would.
func keywords(query, words string) int {
	terms := strings.Fields(strings.ToLower(query))
	if len(terms) == 0 {
		return -1
	}
	score := 0
	for _, t := range terms {
		best := -1
		for _, w := range strings.Fields(strings.ToLower(words)) {
			if strings.HasPrefix(w, t) {
				best = max(best, fuzzy(t, w))
			}
		}
		if best < 0 {
			return -1
		}
		score += best
	}
	return score
}

// paletteMatches are the palette's items that match what the user typed,
// the best first.
func (a *App) paletteMatches() []paletteItem {
	var items []paletteItem
	for _, it := range a.paletteItems() {
		sc := fuzzy(a.pal.query, it.title+" "+it.detail)
		sc = max(sc, keywords(a.pal.query, it.words))
		if t := fuzzy(a.pal.query, it.title); t >= 0 {
			sc = max(sc, t+50)
		}
		if it.top {
			sc = math.MaxInt32
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
	return items
}

// paletteArrows acts on the arrow the field gave the list, and reports
// whether the list changed: before the user types, → shows a session's
// panes and goes into them, and ← goes back out and hides them.
func (a *App) paletteArrows(items []paletteItem) bool {
	arrow := a.pal.arrow
	a.pal.arrow = 0
	if arrow == 0 || a.pal.index < 0 || a.pal.index >= len(items) {
		return false
	}
	it := items[a.pal.index]
	switch {
	case arrow > 0 && a.pal.right:
		if a.pal.expanded[it.session.ID] {
			a.pal.index, a.pal.reveal = a.pal.index+1, true
			return false
		}
		a.expandPalette(it.session.ID, true)
	case arrow < 0 && a.pal.left:
		a.expandPalette(it.session.ID, false)
		for i, p := range items {
			if p.kind() == paletteSession && p.session.ID == it.session.ID {
				a.pal.index, a.pal.reveal = i, true
			}
		}
	default:
		return false
	}
	return true
}

func (a *App) paletteView(c *ui.Context, pal *palette) {
	if !a.pal.open {
		return
	}
	items := a.paletteMatches()
	if a.paletteArrows(items) {
		items = a.paletteMatches()
	}
	a.pal.index = min(max(a.pal.index, 0), max(len(items)-1, 0))

	var chosen func()
	label, placeholder, none := locales.PaletteLabel(), locales.PalettePlaceholder(), locales.PaletteNoMatches()
	if a.pal.only {
		label, placeholder = locales.PaletteConversationsLabel(), locales.PaletteConversationsPlaceholder()
		if a.pal.query == "" {
			none = locales.PaletteNoConversations()
		}
	}
	ui.DialogBase(c.Key("palette"), &a.pal.open, func(backdrop, panel ui.Element) {
		backdrop.Background(pal.overlay).Justify(ui.Start).Padding(84, 0, 0, 0)
		floating(panel.Width(600).MaxHeight(460).Radius(14).Background(pal.popover), pal).Clip().
			Label(label)
		ui.Row(c).Height(50).Shrink(0).Padding(0, 16).Gap(10).AlignItems(ui.Center).Children(func() {
			ui.Icon(c, searchIcon).Size(16, 16).TextColor(pal.textMuted)
			in := ui.TextInputBase(c.Key("q"), &a.pal.query).Grow(1).FontSize(15).Placeholder(placeholder).AutoFocus().
				OnTextKey(a.paletteArrow)
			if in.Changed() {
				a.pal.index, a.pal.reveal = 0, true
			}
			if c.Shortcut(0, ui.KeyDown) || c.Shortcut(ui.Ctrl, ui.KeyN) {
				a.pal.index, a.pal.reveal = min(a.pal.index+1, len(items)-1), true
			}
			if c.Shortcut(0, ui.KeyUp) || c.Shortcut(ui.Ctrl, ui.KeyP) {
				a.pal.index, a.pal.reveal = max(a.pal.index-1, 0), true
			}
			if (in.Submitted() || c.Shortcut(0, ui.KeyEnter)) && len(items) > 0 {
				chosen = items[a.pal.index].run
			}
		})
		list := ui.Scroll(c.Key("results")).Grow(1).MinHeight(0).Padding(6).TrackScroll(&a.pal.scroll)
		reveal := a.pal.reveal
		a.pal.reveal = false
		list.Children(func() {
			if len(items) == 0 {
				ui.Text(c, none).FontSize(13).TextColor(pal.textFaint).Padding(12, 12).LineHeight(1.4)
			}
			lastKind := paletteSession
			for i, it := range items {
				kind := it.kind()
				group := kind
				if group == palettePane {
					group = paletteSession
				}
				// Conversations head their group even first, as with no
				// sessions, or they would read as sessions.
				if (i > 0 || kind == paletteConversation) && group != lastKind && a.pal.query == "" && !a.pal.only {
					title := locales.PaletteCommands()
					if kind == paletteConversation {
						title = locales.PaletteConversations()
					}
					ui.Text(c, title).FontSize(11.5).FontWeight(600).TextColor(pal.textFaint).Padding(10, 10, 4, 10)
				}
				lastKind = group
				row := ui.Row(c.Key(i)).Height(38).Padding(0, 10).Gap(10).AlignItems(ui.Center).Radius(8)
				if i == a.pal.index {
					row.Background(pal.accent.Alpha(0.12))
					if reveal {
						row.ScrollIntoView()
					}
				} else if row.Hovered() {
					row.Background(pal.rowHover)
				}
				if kind == palettePane && a.pal.query == "" {
					row.Padding(0, 10, 0, 34) // under its session's name
				}
				if row.Clicked() {
					chosen = it.run
				}
				toggled := false
				row.Children(func() {
					switch kind {
					case paletteSession:
						statusIcon(c, pal, it.session.Status, it.session.Unread, 14)
					case palettePane:
						if p := it.pane; p.Status != proto.Idle || p.Unread {
							statusIconP(c, pal, p.Status, p.Unread, p.Progress, 14)
						} else {
							ui.Icon(c, programIcon(p)).Size(14, 14).TextColor(pal.textFaint)
						}
					case paletteConversation:
						ui.Icon(c, programIcon(&proto.Pane{Agent: it.conv.Agent})).Size(14, 14).TextColor(pal.textFaint)
					default:
						ui.Icon(c, returnIcon).Size(14, 14).TextColor(pal.textFaint)
					}
					ui.Text(c, it.title).FontSize(13.5).TextColor(pal.text).SingleLine().Ellipsis("…").Shrink(0).MaxWidth(300)
					ui.Text(c, it.detail).FontSize(12.5).TextColor(pal.textFaint).SingleLine().Ellipsis("…").Grow(1).MinWidth(0)
					if it.keys != "" {
						kbd(c, pal, it.keys)
					}
					// A session of panes says so, and shows them on a
					// click, or with → before the user types.
					if kind == paletteSession && len(it.session.Panes) > 1 && a.pal.query == "" && !a.pal.only {
						open := a.pal.expanded[it.session.ID]
						label := locales.PaletteShowPanes(len(it.session.Panes))
						icon := chevronIcon
						if open {
							label, icon = locales.PaletteHidePanes(), chevronDownIcon
						}
						b := ui.ButtonBase(c.Key("panes")).Height(22).Padding(0, 6).Gap(4).Radius(6).AlignItems(ui.Center).
							TextColor(pal.textFaint).Label(label).Tooltip(label)
						if b.Hovered() || b.Pressed() {
							b.Background(pal.rowHover).TextColor(pal.text)
						}
						b.Children(func() {
							ui.Text(c, itoa(len(it.session.Panes))).FontSize(11.5)
							ui.Icon(c, icon).Size(11, 11)
						})
						if b.Clicked() {
							a.expandPalette(it.session.ID, !open)
							toggled = true
						}
					}
				})
				if toggled {
					chosen = nil
					a.pal.index = i
				}
			}
		})
	})
	// The arrows the field gives the list are those that the row chosen
	// now has a use for.
	a.pal.left, a.pal.right = false, false
	if a.pal.query == "" && !a.pal.only && a.pal.index < len(items) {
		it := items[a.pal.index]
		a.pal.right = it.kind() == paletteSession && len(it.session.Panes) > 1
		a.pal.left = it.kind() == palettePane || it.kind() == paletteSession && a.pal.expanded[it.session.ID]
	}
	if chosen != nil {
		a.pal.open = false
		chosen()
	}
	if !a.pal.open && chosen == nil {
		a.focusTerminal()
	}
}

func (a *App) confirmView(c *ui.Context, pal *palette) {
	if a.confirm != nil && confirmDialog(c, pal, &a.confirm) {
		a.focusTerminal()
	}
}

// confirmDialog asks *pending's question in c's window, and clears it once
// answered, which it reports.
func confirmDialog(c *ui.Context, pal *palette, pending **confirmation) bool {
	cf := *pending
	run, alt := false, false
	ui.DialogBase(c.Key("confirm"), &cf.open, func(backdrop, panel ui.Element) {
		backdrop.Background(pal.overlay)
		width := float32(380)
		if cf.alt != "" {
			width = 460 // room for a third button
		}
		floating(panel.Width(width).Padding(22).Gap(8).Radius(14).Background(pal.popover), pal).Label(cf.title)
		ui.Text(c, cf.title).FontSize(15).FontWeight(650).TextColor(pal.text)
		ui.Text(c, cf.detail).FontSize(13).TextColor(pal.textMuted).LineHeight(1.4)
		ui.Row(c).Gap(8).Justify(ui.End).Margin(14, 0, 0, 0).Children(func() {
			if button(c, "cancel", locales.CommonCancel(), "esc", false, pal) {
				cf.open = false
			}
			if cf.alt != "" && button(c, "alt", cf.alt, "", false, pal) {
				alt = true
			}
			if defaultButton(c, "ok", cf.action, "↩", true, pal) || c.Shortcut(0, ui.KeyEnter) {
				run = true
			}
		})
	})
	if run {
		cf.open = false
		cf.run()
	} else if alt {
		cf.open = false
		cf.altRun()
	}
	if cf.open {
		return false
	}
	*pending = nil
	return true
}

// shortcuts are the window's keys that no menu item has.
func (a *App) shortcuts(c *ui.Context) {
	if a.pal.open || a.picker.open || a.confirm != nil || a.wtAsk != nil {
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
