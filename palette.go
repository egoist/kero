package main

import (
	"cmp"
	"math"
	"net/url"
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
	open         bool
	query        string
	resultsQuery string // query the current selection belongs to
	// chosen is the key of the item at index, which the selection stays
	// on as rows come and go above it, as a session's panes do.
	chosen any
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
	// peek aligns a newly expanded session at the top of the list.
	peek bool
	// picked is the row Return chose, run next frame; keys after it wait.
	picked func()
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
	// own, when set, finds it in place of its title and detail, as a split
	// session by its name, not its pane's folder, which finds that pane.
	own string
	top bool // what the query asks for outright, before any match
}

func (a *App) openPalette() {
	a.pal = paletteState{open: true, reveal: true, gen: a.pal.gen + 1, expanded: map[string]bool{}}
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
	names := a.projectNames()
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

func (a *App) paletteItems(query string) []paletteItem {
	if a.pal.only {
		return a.conversationItems()
	}
	items := a.sessionItems(query)
	var cmds []paletteItem
	// Commands are found by their English names too, in any language.
	en := locales.In("en")
	// An address typed opens in a browser beside the pane the user is in.
	if q := strings.TrimSpace(query); proto.IsAddress(q) && a.session(a.selected) != nil {
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
	if query == "" && len(convs) > recentConversations {
		convs = convs[:recentConversations]
	}
	items = append(items, convs...)
	return append(items, cmds...)
}

// sessionItems are the palette's sessions, in the sidebar's order, each
// with its panes under it when expanded, or once the user types.
func (a *App) sessionItems(query string) []paletteItem {
	var items []paletteItem
	names := a.projectNames()
	for _, g := range a.groups() {
		group := g.key()
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
			it := paletteItem{session: s, title: s.DisplayName(a.set.SessionName), detail: detail + " · " + h.shortDir(s.WorkDir()),
				run: func() { a.showInSidebar(group, "", func() { a.selectSession(id) }) }}
			if len(s.Panes) > 1 {
				// Its process and folder are a pane's, listed itself.
				it.own = it.title + " " + names[s.Project]
				if h.remote() {
					it.own += " " + h.name
				}
			}
			items = append(items, it)
			if len(s.Panes) > 1 && (query != "" || a.pal.expanded[id]) {
				items = append(items, a.paneItems(s, h, group)...)
			}
		}
	}
	return items
}

// projectNames are the projects' names by their ids.
func (a *App) projectNames() map[string]string {
	names := map[string]string{}
	for _, p := range a.st.Projects {
		names[p.ID] = p.Name
	}
	return names
}

// showInSidebar goes where goTo does, with the sidebar's group of that
// key open and, with sid, that session's panes shown under it. The prefs
// are saved once: by goTo, as a new session is selected, or else here.
func (a *App) showInSidebar(group, sid string, goTo func()) {
	changed := a.prefs.Collapsed[group]
	delete(a.prefs.Collapsed, group)
	if sid != "" && a.setSessionPanes(sid, true) {
		changed = true
	}
	selected := a.selected
	goTo()
	if changed && a.selected == selected {
		a.savePrefs()
	}
}

// paneItems are the palette's items for the panes of a session, in the
// sidebar's order. Each is found by its own name, program, folder and
// address, not its session's. group is the sidebar's group of the session.
func (a *App) paneItems(s *proto.Session, h *host, group string) []paletteItem {
	name := s.DisplayName(a.set.SessionName)
	var items []paletteItem
	for i := range s.Panes {
		p := &s.Panes[i]
		pid, dir := p.ID, p.WorkDir()
		detail := name
		if p.Process != "" {
			detail += " · " + p.Process
		}
		if p.Browser() {
			detail += " · " + p.URL
		} else if dir != "" {
			detail += " · " + h.shortDir(dir)
		}
		sid := s.ID
		words := strings.Join([]string{p.Title, p.Process, p.Agent, p.Runtime, p.Shell,
			strings.Join(p.Command, " "), urlWords(p.URL)}, " ")
		if dir != "" {
			words += " " + dir + " " + proto.DirName(dir)
		}
		items = append(items, paletteItem{session: s, pane: p, title: p.PaneName(), detail: detail, words: words,
			run: func() { a.showInSidebar(group, sid, func() { a.goToPane(sid, pid) }) }})
	}
	return items
}

// urlWords are an address and its parts, as a pane is found by its site
// or a part of its path: github.com/egoist/kero by github, egoist or kero,
// docs.github.com by docs or github, and localhost:5173 by localhost or
// 5173.
func urlWords(addr string) string {
	u, err := url.Parse(addr)
	if addr == "" || err != nil || u.Host == "" {
		return addr
	}
	host := proto.URLHost(addr)
	words := []string{addr, host}
	name, port, _ := strings.Cut(host, ":")
	if port != "" {
		words = append(words, name, port)
	}
	if labels := strings.Split(name, "."); len(labels) > 1 {
		words = append(words, labels...)
	}
	for _, part := range strings.Split(u.Path, "/") {
		if part != "" {
			words = append(words, part)
		}
	}
	return strings.Join(words, " ")
}

// paletteKey acts on navigation and Return as each comes, on the text the
// field has then. Left and Right navigate the list while it is empty.
func (a *App) paletteKey(k ui.TextKey) bool {
	key := k.Key
	query := k.Text()
	switch {
	case k.Mods == ui.Ctrl && key == ui.KeyN:
		key = ui.KeyDown
	case k.Mods == ui.Ctrl && key == ui.KeyP:
		key = ui.KeyUp
	case key == ui.KeyEnter && (k.Mods == 0 || k.Mods == ui.Shift):
	case k.Mods != 0:
		return false
	case key == ui.KeyDown || key == ui.KeyUp:
	case (key == ui.KeyLeft || key == ui.KeyRight) && query == "" && !a.pal.only:
	default:
		return false
	}
	a.paletteNav(key, query)
	return true
}

// expandPalette shows or hides the panes of a session under it.
func (a *App) expandPalette(sid string, open bool) {
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

// group is the group of the list an item heads or is in: a pane's is its
// session's.
func (it *paletteItem) group() int {
	if k := it.kind(); k != palettePane {
		return k
	}
	return paletteSession
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
func (a *App) paletteMatches(query string) []paletteItem {
	var items []paletteItem
	for _, it := range a.paletteItems(query) {
		// A pane's detail is its session's, which finds the session; a
		// pane is found by its name, scored as a title below, and words.
		sc := -1
		switch {
		case it.own != "":
			sc = fuzzy(query, it.own)
		case it.pane == nil:
			sc = fuzzy(query, it.title+" "+it.detail)
		}
		sc = max(sc, keywords(query, it.words))
		if t := fuzzy(query, it.title); t >= 0 {
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
	if query != "" {
		// Conversations of the past come after what is open, however well
		// they match, or they would bury the sessions and panes.
		past := func(it *paletteItem) int {
			if it.kind() == paletteConversation && !a.pal.only {
				return 1
			}
			return 0
		}
		slices.SortStableFunc(items, func(x, y paletteItem) int { return cmp.Or(past(&x)-past(&y), y.score-x.score) })
	}
	return items
}

func (a *App) paletteResults(query string) []paletteItem {
	items := a.paletteMatches(query)
	if a.pal.resultsQuery != query {
		a.pal.resultsQuery, a.pal.chosen = query, nil
		a.pal.index, a.pal.reveal, a.pal.peek = 0, true, false
	} else if a.pal.chosen != nil {
		if i := paletteIndex(items, a.pal.chosen); i >= 0 {
			a.pal.index = i
		}
	}
	a.pal.index = min(max(a.pal.index, 0), max(len(items)-1, 0))
	return items
}

// movePaletteSelection chooses the row at index of items.
func (a *App) movePaletteSelection(items []paletteItem, index int) {
	if a.pal.index != index {
		a.pal.peek = false
	}
	a.pal.index, a.pal.reveal = index, true
	if index < len(items) {
		a.pal.chosen = items[index].key(index)
	}
}

// paletteNav acts on a key of the list's, on the results for query.
func (a *App) paletteNav(key ui.Key, query string) {
	if a.pal.picked != nil {
		return
	}
	items := a.paletteResults(query)
	switch key {
	case ui.KeyEnter:
		if len(items) > 0 {
			a.pal.picked = items[a.pal.index].run
		}
		return
	case ui.KeyDown:
		a.movePaletteSelection(items, max(min(a.pal.index+1, len(items)-1), 0))
		return
	case ui.KeyUp:
		a.movePaletteSelection(items, max(a.pal.index-1, 0))
		return
	}
	if query != "" || a.pal.only || a.pal.index >= len(items) {
		return
	}
	it := items[a.pal.index]
	kind := it.kind()
	if kind != paletteSession && kind != palettePane {
		return
	}
	sid := it.session.ID
	switch {
	case key == ui.KeyRight && kind == paletteSession && len(it.session.Panes) > 1:
		if a.pal.expanded[sid] {
			a.movePaletteSelection(items, a.pal.index+1)
			return
		}
		a.expandPalette(sid, true)
		a.pal.reveal, a.pal.peek = true, true
	case key == ui.KeyLeft && kind == palettePane:
		a.expandPalette(sid, false)
		a.movePaletteSelection(a.paletteMatches(query), max(paletteIndex(items, "s/"+sid), 0))
	case key == ui.KeyLeft && kind == paletteSession && a.pal.expanded[sid]:
		a.expandPalette(sid, false)
		a.pal.peek = false
	}
}

// togglePalette shows or hides a session's panes, as a click on its count
// does, and chooses the session.
func (a *App) togglePalette(sid string) {
	open := !a.pal.expanded[sid]
	a.expandPalette(sid, open)
	items := a.paletteMatches(a.pal.resultsQuery)
	if i := paletteIndex(items, "s/"+sid); i >= 0 {
		a.movePaletteSelection(items, i)
		a.pal.peek = open
	}
}

// paletteIndex is the index of the item of that key, -1 for none.
func paletteIndex(items []paletteItem, key any) int {
	for i := range items {
		if items[i].key(i) == key {
			return i
		}
	}
	return -1
}

// key keeps a row's state, as its count's turn, with the row as it moves
// when a session above it shows or hides its panes.
func (it *paletteItem) key(i int) any {
	switch it.kind() {
	case paletteSession:
		return "s/" + it.session.ID
	case palettePane:
		return "p/" + it.session.ID + "/" + it.pane.ID
	}
	return i
}

func (a *App) paletteView(c *ui.Context, pal *palette) {
	if !a.pal.open {
		return
	}
	var items []paletteItem
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
				OnTextKey(a.paletteKey)
			// The field takes the keys as they come; away from it, as on a
			// click in the list, the window does.
			if !in.Focused() {
				for _, s := range []struct {
					mods ui.Modifiers
					key  ui.Key
					as   ui.Key
				}{{0, ui.KeyDown, ui.KeyDown}, {ui.Ctrl, ui.KeyN, ui.KeyDown}, {0, ui.KeyUp, ui.KeyUp}, {ui.Ctrl, ui.KeyP, ui.KeyUp}} {
					if c.Shortcut(s.mods, s.key) {
						a.paletteNav(s.as, a.pal.query)
					}
				}
			}
			if c.Shortcut(0, ui.KeyEnter) {
				a.paletteNav(ui.KeyEnter, a.pal.query)
			}
			items = a.paletteResults(a.pal.query)
			if a.pal.index < len(items) {
				a.pal.chosen = items[a.pal.index].key(a.pal.index)
			}
			chosen, a.pal.picked = a.pal.picked, nil
		})
		list := ui.Scroll(c.Key("results")).Grow(1).MinHeight(0).Padding(6).TrackScroll(&a.pal.scroll)
		reveal, peek := a.pal.reveal, a.pal.peek
		a.pal.reveal, a.pal.peek = false, false
		list.Children(func() {
			if len(items) == 0 {
				ui.Text(c, none).FontSize(13).TextColor(pal.textFaint).Padding(12, 12).LineHeight(1.4)
			}
			lastKind := paletteSession
			for i, it := range items {
				kind, group := it.kind(), it.group()
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
				row := ui.Row(c.Key(it.key(i))).Height(38).Padding(0, 10).Gap(10).AlignItems(ui.Center).Radius(8)
				if i == a.pal.index {
					row.Background(pal.accent.Alpha(0.12))
					switch {
					case reveal && peek:
						// A session just expanded heads the list, its
						// panes under it, as far as it scrolls.
						row.ScrollIntoView(ui.ScrollIntoViewOptions{Block: ui.ScrollStart})
					case reveal:
						row.ScrollIntoView()
					}
				} else if row.Hovered() {
					row.Background(pal.rowHover)
				}
				if kind == palettePane && a.pal.query == "" {
					row.Padding(0, 10, 0, 34) // under its session's name
				}
				clicked := row.Clicked()
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
					// A session of panes shows how many by its name, as in
					// the sidebar; a click shows or hides them under it.
					if kind == paletteSession && len(it.session.Panes) > 1 && a.pal.query == "" && !a.pal.only &&
						a.panesToggle(c, pal, it.session, a.pal.expanded[it.session.ID], true) {
						// The rows drawn are the old ones; the next frame's
						// show it.
						a.togglePalette(it.session.ID)
						c.Invalidate()
						toggled = true
					}
					ui.Text(c, it.detail).FontSize(12.5).TextColor(pal.textFaint).SingleLine().Ellipsis("…").Grow(1).MinWidth(0)
					if it.keys != "" {
						kbd(c, pal, it.keys)
					}
				})
				if clicked && !toggled { // the count's click is not the row's
					chosen = it.run
				}
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
