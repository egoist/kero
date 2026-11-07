package main

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/client"
	"kero/internal/proto"

	"kero/locales"
)

const (
	// searchDebounce is how long a search waits for more of what is typed.
	searchDebounce = 120 * time.Millisecond
	// searchWait is how long a host gets to answer before it is left out.
	searchWait = 20 * time.Second
	// jumpWait is how long a match chosen gets to show in its pane, whose
	// terminal may have its scrollback yet to come, over a slow link.
	jumpWait = 10 * time.Second
	// jumpSettle is how long a match selected stays looked after.
	jumpSettle = 1500 * time.Millisecond
	// The bounds of a search of the palette: of a host's matches, a pane's,
	// and all it lists.
	searchHostLimit = 150
	searchPaneLimit = 10
	searchShownMost = 300
	// hitContext is how many characters of a line show before the match.
	hitContext = 24
)

// paneSearch is a search of the panes' text, of every host at once, as the
// palette's search mode runs it. Its hits are in the order they come: a host
// that answers late adds its own below, moving none.
type paneSearch struct {
	query  string
	timer  *time.Timer
	cancel context.CancelFunc
	hosts  []*hostSearch
	hits   []searchHit
	more   bool
}

// hostSearch is how a search goes on a host.
type hostSearch struct {
	h     *host
	state hostSearchState
	err   string
}

type hostSearchState int

const (
	searchGoing hostSearchState = iota
	searchDone
	searchOld      // its kerod is of a Kero that can't search
	searchNoAnswer // it left the search to wait
	searchLost     // the app has no connection to it
	searchFailed
)

// searchHit is a match of a search.
type searchHit struct {
	host  *host
	query string
	proto.SearchMatch
}

// findJump is a match the find bar goes to as it can: its pane's terminal
// searches for it as the bar does, then selects it.
type findJump struct {
	pane     string
	query    string
	match    proto.SearchMatch
	deadline time.Time
	// newer is how many matches are newer than it in the terminal, -1 until
	// found there; locating tells that it's looked for, next when to again;
	// size is how much the terminal held then, still how often no different.
	newer    int
	locating bool
	next     time.Time
	size     int
	still    int
	// selected tells that it is, older how many matches lie below it then,
	// and until how long the jump looks after it.
	selected bool
	older    int
	until    time.Time
}

// openPaneSearch opens the palette on its search of every pane's text.
func (a *App) openPaneSearch(query string) {
	a.openPalette()
	a.pal.search, a.pal.query = true, query
	a.paneSearchChanged()
}

// stopPaneSearch stops the search going; what it found still shows.
func (a *App) stopPaneSearch() {
	run := a.pal.run
	if run == nil {
		return
	}
	a.pal.run = nil
	if run.timer != nil {
		run.timer.Stop()
	}
	if run.cancel != nil {
		run.cancel()
	}
}

// paneSearchChanged follows the query: the search going stops at once, and
// another starts once the typing pauses. The hits of the last stay until
// those of the next come, rather than the list emptying at each key.
func (a *App) paneSearchChanged() {
	a.stopPaneSearch()
	q := a.pal.query
	if strings.TrimSpace(q) == "" || len(q) > proto.MaxQuery {
		a.pal.shown = nil
		return
	}
	run := &paneSearch{query: q}
	a.pal.run = run
	run.timer = time.AfterFunc(searchDebounce, func() {
		a.update(func() {
			if a.pal.run == run {
				a.startPaneSearch(run)
			}
		})
	})
}

// startPaneSearch asks every host, each on its own, so that none holds up
// another, and one gone only says so.
func (a *App) startPaneSearch(run *paneSearch) {
	ctx, cancel := context.WithTimeout(context.Background(), searchWait)
	run.cancel = cancel
	p := proto.SearchParams{Query: run.query, Limit: searchHostLimit, PerPane: searchPaneLimit}
	for _, h := range a.hosts {
		hs := &hostSearch{h: h}
		run.hosts = append(run.hosts, hs)
		cl := h.cl
		if cl == nil {
			hs.state = searchLost
			if h.conn == connVersion {
				hs.state = searchOld
			}
			continue
		}
		go func() {
			res, err := cl.Search(ctx, p, func(ms []proto.SearchMatch) {
				a.update(func() { a.takeHits(run, h, ms) })
			})
			a.update(func() { a.hostSearched(run, hs, res, err) })
		}()
	}
	a.searchSettled(run)
}

// takeHits adds what a host found to the list.
func (a *App) takeHits(run *paneSearch, h *host, ms []proto.SearchMatch) {
	if a.pal.run != run {
		return
	}
	a.showRun(run)
	for _, m := range ms {
		if len(run.hits) == searchShownMost {
			run.more = true
			break
		}
		run.hits = append(run.hits, searchHit{host: h, query: run.query, SearchMatch: m})
	}
}

// showRun lists a search's hits in place of the last's.
func (a *App) showRun(run *paneSearch) {
	if a.pal.shown != run {
		a.pal.shown, a.pal.index, a.pal.reveal = run, 0, true
	}
}

// hostSearched takes how a host's search ended.
func (a *App) hostSearched(run *paneSearch, hs *hostSearch, res proto.SearchResult, err error) {
	if a.pal.run != run {
		return
	}
	switch {
	case err == nil:
		hs.state = searchDone
		run.more = run.more || res.Truncated
	case errors.Is(err, client.ErrNoSearch):
		hs.state = searchOld
	case errors.Is(err, context.DeadlineExceeded):
		hs.state = searchNoAnswer
	default:
		hs.state, hs.err = searchFailed, err.Error()
	}
	a.searchSettled(run)
}

// searchSettled ends a search all of whose hosts answered.
func (a *App) searchSettled(run *paneSearch) {
	for _, hs := range run.hosts {
		if hs.state == searchGoing {
			return
		}
	}
	a.showRun(run)
	if run.cancel != nil {
		run.cancel()
	}
}

// searching reports whether the palette's search has more to come.
func (a *App) searching() bool {
	run := a.pal.run
	if run == nil {
		return false
	}
	if a.pal.shown != run {
		return true
	}
	for _, hs := range run.hosts {
		if hs.state == searchGoing {
			return true
		}
	}
	return false
}

// searchItems are the palette's hits: of panes still there.
func (a *App) searchItems() []paletteItem {
	run := a.pal.shown
	if run == nil {
		return nil
	}
	items := make([]paletteItem, 0, len(run.hits))
	for i := range run.hits {
		hit := &run.hits[i]
		s := a.session(hit.Session)
		if s == nil {
			continue
		}
		p := s.PaneByID(hit.Pane)
		if p == nil {
			continue
		}
		detail := s.DisplayName(a.set.SessionName) + " · " + p.PaneName()
		if hit.host.remote() {
			detail += " · " + hit.host.name
		}
		items = append(items, paletteItem{hit: hit, pane: p, title: hit.Line, detail: detail, run: func() { a.jumpToHit(*hit) }})
	}
	return items
}

// hitText is a hit's line as its row shows it: from a little before the
// match, which then shows however far along the line it is, split around
// the match.
func hitText(line string, start, end int) (before, match, after string) {
	before, match, after = line[:start], line[start:end], line[end:]
	before = strings.TrimLeft(before, " \t")
	if r := []rune(before); len(r) > hitContext {
		before = "…" + string(r[len(r)-hitContext:])
	}
	return before, match, after
}

// hitRow shows a hit: its line, the match standing out, and where it is.
func (a *App) hitRow(c *ui.Context, pal *palette, it *paletteItem) {
	statusIcon(c, pal, it.pane.Status, it.pane.Unread, 14)
	ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
		before, match, after := hitText(it.hit.Line, it.hit.Start, it.hit.End)
		ui.RichText(c,
			ui.Span{Text: before},
			ui.Span{Text: match, Background: pal.accent.Alpha(0.28), Radius: 3},
			ui.Span{Text: after},
		).Font(a.termFamily()).FontSize(12.5).TextColor(pal.text).SingleLine().Ellipsis("…")
		ui.Text(c, it.detail).FontSize(12).TextColor(pal.textFaint).SingleLine().Ellipsis("…")
	})
}

// searchNotes says, under the hits, which hosts the search left out or waits
// for, and that it found more than it lists.
func (a *App) searchNotes(c *ui.Context, pal *palette) {
	// Those of the search going, once it asked the hosts: until then the
	// last's still hold, rather than blink away at each key.
	run := a.pal.shown
	if r := a.pal.run; r != nil && len(r.hosts) > 0 {
		run = r
	}
	if run == nil {
		return
	}
	note := func(key int, text string, h *host) {
		ui.Row(c.Key("note-"+itoa(key))).Height(30).Padding(0, 10).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.Text(c, text).FontSize(12.5).TextColor(pal.textFaint).SingleLine().Ellipsis("…").Grow(1).MinWidth(0)
			if h != nil && (h.behind() || h.conn == connVersion) && smallButton(c, "update", locales.CommonUpdate(), false, pal) {
				a.pal.open = false
				a.offerHostUpdate(h)
			}
		})
	}
	for i, hs := range run.hosts {
		switch hs.state {
		case searchGoing:
			if a.pal.shown == run && hs.h.remote() {
				note(i, locales.PaletteSearchingHost(hs.h.name), nil)
			}
		case searchOld:
			if hs.h.remote() {
				note(i, locales.PaletteSearchHostOld(hs.h.name), hs.h)
			} else {
				note(i, locales.PaletteSearchLocalOld(), nil)
			}
		case searchNoAnswer:
			note(i, locales.PaletteSearchNoAnswer(hs.h.label()), nil)
		case searchLost:
			note(i, locales.HostNotConnected(hs.h.label()), nil)
		case searchFailed:
			note(i, locales.PaletteSearchFailed(hs.h.label(), hs.err), nil)
		}
	}
	if run.more && a.pal.shown == run {
		note(len(run.hosts), locales.PaletteSearchMore(), nil)
	}
}

// jumpToHit shows a hit's session and pane, and has the find bar go to the
// match, which it highlights as it does any: the bar then goes on through
// the pane's other matches.
func (a *App) jumpToHit(hit searchHit) {
	s := a.session(hit.Session)
	if s == nil || s.PaneByID(hit.Pane) == nil {
		a.toast(locales.SearchPaneGone())
		return
	}
	if a.find.pane != "" && a.find.pane != hit.Pane {
		a.closeFind()
	}
	delete(a.prefs.Collapsed, s.Project)
	a.setFocus(s, hit.Pane)
	a.selectSession(s.ID)
	a.find.pane, a.find.query, a.find.focus = hit.Pane, hit.query, true
	a.find.jump = &findJump{pane: hit.Pane, query: hit.query, match: hit.SearchMatch, newer: -1, deadline: time.Now().Add(jumpWait)}
}

// jumpLocated takes what looking for the match in the terminal found. Not
// there, it is looked for again while the terminal's scrollback may have yet
// to come: until what it holds stays as it is.
func (a *App) jumpLocated(j *findJump, newer int, ok bool, size int) {
	j.locating = false
	if ok {
		j.newer = newer
		return
	}
	j.next = time.Now().Add(200 * time.Millisecond)
	if size > 0 && size == j.size {
		j.still++
	} else {
		j.size, j.still = size, 0
	}
	if j.still >= 2 && a.find.jump == j {
		a.jumpFailed()
	}
}

// jumpFailed ends a jump to a match no longer there, the keyboard in the bar,
// which a terminal that attached since took as it came.
func (a *App) jumpFailed() {
	a.find.jump, a.find.focus = nil, true
	a.toast(locales.SearchMatchGone())
}

// stepJump goes on with the jump of the find bar, in its frames: once the
// terminal's search is through, it finds the match in what the terminal holds
// now, as output went on since the search, and selects it. A terminal just
// attached starts over as it takes its window's size, its selection with it,
// so the jump stays a moment to select it again. A match no longer there,
// gone from the scrollback or from the screen as a program redrew it, leaves
// the bar on the pane's newest match, saying so.
func (a *App) stepJump(c *ui.Context, p *proto.Pane, t *terminal.Terminal) {
	f := &a.find
	j := f.jump
	if j.pane != p.ID || j.query != f.query {
		f.jump = nil
		return
	}
	now := time.Now()
	if j.selected && now.After(j.until) {
		f.jump = nil
		return
	}
	if !j.selected && now.After(j.deadline) {
		a.jumpFailed()
		return
	}
	st := t.SearchStatus()
	if st.Text != j.query || st.Searching || j.locating {
		c.After(30 * time.Millisecond)
		return
	}
	if j.selected {
		// Output moves its place among the newest, never among the oldest.
		if st.Selected == 0 || st.Total-st.Selected != j.older {
			j.selected, j.newer = false, -1
		}
		c.After(50 * time.Millisecond)
		return
	}
	if j.newer < 0 {
		if now.Before(j.next) {
			c.After(j.next.Sub(now))
			return
		}
		j.locating = true
		go func() {
			text := t.Text()
			newer, ok := proto.LocateMatch(text, j.query, j.match)
			a.update(func() { a.jumpLocated(j, newer, ok, len(text)) })
		}()
		return
	}
	if st.Total <= j.newer {
		c.After(30 * time.Millisecond)
		return
	}
	for n := j.newer + 1 - st.Selected; n > 0; n-- {
		t.SearchNext()
	}
	for n := st.Selected - j.newer - 1; n > 0; n-- {
		t.SearchPrevious()
	}
	j.selected, j.older = true, st.Total-j.newer-1
	if j.until.IsZero() {
		j.until = now.Add(jumpSettle)
		// A terminal that attached since took the keyboard as it came.
		f.focus = true
	}
	c.After(50 * time.Millisecond)
}
