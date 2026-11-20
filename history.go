package main

import (
	"strings"
	"sync/atomic"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/client"
	"kero/internal/proto"

	"kero/locales"
)

// appScrollbackCap is how much history the app's own terminal keeps.
// kerod keeps the limit the user set; the copy here keeps at most this
// and asks kerod for anything older, so a long history is not held twice.
const appScrollbackCap = 256 << 10

// appScrollback is that cap applied to the limit kerod keeps. -1, kerod
// keeping none, passes through, and so does 0: the terminal reads 0 as
// its own default, 10 MB, which would keep more here than there.
func appScrollback(limit int) int {
	if limit <= 0 {
		return -1
	}
	return min(limit, appScrollbackCap)
}

// histPageLines is how many lines a search of the history asks for at a
// time. A read answers with fewer when they would not fit its bytes.
const histPageLines = 2000

// histHitCap bounds the matches kept. Past it the search stops: the
// indexes alone of a very common query, over a long history, would be
// the second copy of that history this exists not to keep.
const histHitCap = 10000

// histHit is one match in the history the app's own terminal does not
// hold. back is how many lines from the newest it is, the same count a
// read's offset uses, and n is which match on that line, 0 the leftmost.
// The line's text is not kept: the overlay asks kerod for it when the
// match is the one to show.
type histHit struct {
	back int
	n    int
}

// histSearch is a search of that older history, and the page of it the
// overlay shows. The pane's own find stays the search of what the app
// holds; this is the matches beyond it.
type histSearch struct {
	gen atomic.Int64

	pane, query string
	hits        []histHit
	// in selects a match of hits; otherwise the selection is the pane's
	// own. edge is the pane's own match that selection left, 1 the
	// newest, so coming back lands on it without walking the rest.
	in, searching, done, clipped bool
	deep, edge                   int
	err                          string

	// open shows the overlay. origin is how many lines back from the
	// newest the page it shows ends, rows and cols the page's size.
	open           bool
	origin         int
	rows, cols     int
	total          int
	term           *terminal.Terminal
	conn           *previewConn
	loadID         int
	loading, dirty bool
	// haveRows is the page last shown, 0 before the first: the real
	// size of the view, once it is known, centers that first page.
	haveRows int
}

func (h *histSearch) place() findCursor {
	return findCursor{in: h.in, deep: h.deep, edge: h.edge}
}

// findCursor is where a step through the matches starts.
type findCursor struct {
	in   bool
	deep int
	edge int
}

// findAction is one step. step asks the pane's own find to move, -1
// toward newer output and 1 toward older, 0 to leave it where it is.
type findAction struct {
	in         bool
	deep, edge int
	step       int
}

// moveFind steps through the matches, the pane's own first and then the
// older history, newest toward older as the pane's find does. While the
// history is still being searched, a step does not wrap around the end
// it has not reached yet.
func moveFind(c findCursor, localSel, localTotal, deepTotal int, searching, back bool) findAction {
	if !c.in {
		return moveLocalFind(localSel, localTotal, deepTotal, searching, back)
	}
	return moveDeepFind(c, localTotal, deepTotal, searching, back)
}

func moveLocalFind(localSel, localTotal, deepTotal int, searching, back bool) findAction {
	if !back {
		if localTotal > 0 && localSel < localTotal {
			return findAction{step: 1}
		}
		if deepTotal > 0 {
			edge := localSel
			if localTotal > 0 {
				edge = localTotal
			}
			return findAction{in: true, edge: edge}
		}
		if searching || localTotal == 0 {
			return findAction{}
		}
		return findAction{step: 1}
	}
	if localTotal > 0 && localSel > 1 {
		return findAction{step: -1}
	}
	if deepTotal > 0 && !searching {
		return findAction{in: true, deep: deepTotal - 1, edge: localSel}
	}
	if localTotal > 0 && !searching {
		return findAction{step: -1}
	}
	return findAction{}
}

func moveDeepFind(c findCursor, localTotal, deepTotal int, searching, back bool) findAction {
	stay := findAction{in: true, deep: c.deep, edge: c.edge}
	if !back {
		if c.deep+1 < deepTotal {
			return findAction{in: true, deep: c.deep + 1, edge: c.edge}
		}
		if searching {
			return stay
		}
		if localTotal > 0 {
			step := 0
			if c.edge != 1 {
				step = 1
			}
			return findAction{step: step}
		}
		if deepTotal > 0 {
			return findAction{in: true, edge: c.edge}
		}
		return findAction{}
	}
	if c.deep > 0 {
		return findAction{in: true, deep: c.deep - 1, edge: c.edge}
	}
	if localTotal > 0 {
		step := 0
		if c.edge != localTotal {
			step = -1
		}
		return findAction{step: step}
	}
	if searching {
		return stay
	}
	if deepTotal > 0 {
		return findAction{in: true, deep: deepTotal - 1, edge: c.edge}
	}
	return findAction{}
}

// histLines are the lines of a pane's text, counted as a read counts
// them: no blank lines off the end, no trailing spaces.
func histLines(text string) []string {
	text = strings.TrimRight(text, "\n ")
	if text == "" {
		return nil
	}
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " ")
	}
	return lines
}

// foldASCII folds A-Z so a match ignores the case of ASCII letters, as
// the pane's own find does, and no other letters.
func foldASCII(s string) string {
	var b []byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			if b == nil {
				b = []byte(s)
			}
			b[i] = c + ('a' - 'A')
		}
	}
	if b == nil {
		return s
	}
	return string(b)
}

// countFolded counts the non-overlapping matches of query, already
// folded, in line.
func countFolded(line, query string) int {
	if query == "" || len(line) < len(query) {
		return 0
	}
	n := 0
	for i := 0; i+len(query) <= len(line); {
		if foldedEq(line[i:i+len(query)], query) {
			n++
			i += len(query)
			continue
		}
		i++
	}
	return n
}

func foldedEq(chunk, query string) bool {
	for i := 0; i < len(query); i++ {
		c := chunk[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != query[i] {
			return false
		}
	}
	return true
}

// pageHits are the matches on lines, newest first. offset is how many
// lines back from the newest the newest of these lines is.
func pageHits(lines []string, query string, offset int) []histHit {
	if query == "" {
		return nil
	}
	var hits []histHit
	for i := len(lines) - 1; i >= 0; i-- {
		n := countFolded(lines[i], query)
		back := offset + (len(lines) - 1 - i)
		for k := n - 1; k >= 0; k-- {
			hits = append(hits, histHit{back: back, n: k})
		}
	}
	return hits
}

// histOrigin is where a page ends, in lines back from the newest, so
// that the match on hitBack sits about the middle of a page rows tall.
func histOrigin(hitBack, rows int) int {
	if rows < 1 {
		return hitBack
	}
	if o := hitBack - rows/2; o > 0 {
		return o
	}
	return 0
}

// searchHist searches the pane's history beyond what its own terminal
// holds. The part the app holds is the pane's own find, unchanged; the
// matches here are only the older lines. A query already searched is
// not searched again, and one still being searched is left to finish.
func (a *App) searchHist(t *terminal.Terminal) {
	f := &a.find
	if f.query == "" || t == nil {
		if f.hist.query != "" || f.hist.open || f.hist.searching {
			a.stopHist()
		}
		return
	}
	h := &f.hist
	q := f.query
	if h.pane == f.pane && h.query == q && (h.searching || h.done) {
		return
	}
	cl := a.hostOf(f.pane).cl
	if cl == nil {
		return
	}
	gen := h.gen.Add(1)
	h.pane, h.query = f.pane, q
	h.hits = nil
	h.in, h.deep, h.edge = false, 0, 0
	h.searching, h.done, h.clipped = true, false, false
	h.err = ""
	a.closeHistView()
	// The newest lines are the ones this terminal already searched. The
	// cut falls between lines, so a match that straddles it is missed.
	skip := len(histLines(t.Text()))
	go a.runHistSearch(cl, f.pane, foldASCII(q), skip, gen)
}

// runHistSearch pages through the history. It keeps the matches' indexes
// only, and drops them when the query has since changed.
func (a *App) runHistSearch(cl *client.Client, pane, query string, skip int, gen int64) {
	offset := skip
	var hits []histHit
	for {
		if a.find.hist.gen.Load() != gen {
			return
		}
		var res proto.ReadResult
		err := cl.Call("read", proto.ReadParams{
			ID: pane, Scrollback: true, Lines: histPageLines, Offset: offset,
		}, &res)
		if a.find.hist.gen.Load() != gen {
			return
		}
		if err != nil {
			a.publishHist(gen, hits, res.Total, true, false, err)
			return
		}
		lines := histLines(res.Text)
		before := len(hits)
		hits = append(hits, pageHits(lines, query, offset)...)
		clipped := false
		if len(hits) > histHitCap {
			hits = hits[:histHitCap]
			clipped = true
		}
		// A page that came back empty cannot be advanced past, even
		// when the read says older lines remain: one line larger than
		// a read may answer would otherwise be asked for forever.
		done := clipped || !res.More || len(lines) == 0
		if len(hits) != before || done {
			a.publishHist(gen, hits, res.Total, done, clipped, nil)
		}
		if done {
			return
		}
		offset += len(lines)
	}
}

func (a *App) publishHist(gen int64, hits []histHit, total int, done, clipped bool, err error) {
	cp := append([]histHit(nil), hits...)
	a.update(func() {
		h := &a.find.hist
		if h.gen.Load() != gen {
			return
		}
		h.hits = cp
		h.total = total
		h.clipped = clipped
		h.searching = !done
		h.done = done
		if err != nil {
			h.err = err.Error()
			h.searching, h.done = false, true
		} else {
			h.err = ""
		}
		if h.in && h.deep >= len(h.hits) && len(h.hits) > 0 {
			h.deep = len(h.hits) - 1
		}
	})
}

// considerHist opens the history on its newest match when the pane's own
// find has none: a match that lives only in the older history is still
// the one a search lands on.
func (a *App) considerHist() {
	h := &a.find.hist
	if h.in || len(h.hits) == 0 {
		return
	}
	t := a.findTerm()
	if t == nil {
		return
	}
	st := t.SearchStatus()
	if st.Total > 0 || st.Searching {
		return
	}
	h.in, h.deep, h.edge = true, 0, 0
	a.showHistHit()
}

// stepTermFind moves the selection one match, the pane's own or the
// older history's.
func (a *App) stepTermFind(t *terminal.Terminal, back bool) {
	st := t.SearchStatus()
	h := &a.find.hist
	act := moveFind(h.place(), st.Selected, st.Total, len(h.hits), h.searching, back)
	was, wasIn := h.deep, h.in
	h.in, h.deep, h.edge = act.in, act.deep, act.edge
	switch act.step {
	case 1:
		t.SearchNext()
	case -1:
		t.SearchPrevious()
	}
	switch {
	case h.in:
		if !wasIn || h.deep != was || !h.open {
			a.showHistHit()
		}
	case h.open:
		a.closeHistView()
	}
}

// showHistHit shows the selected match in the overlay, about the middle
// of the page.
func (a *App) showHistHit() {
	h := &a.find.hist
	if !h.in || h.deep < 0 || h.deep >= len(h.hits) {
		return
	}
	if h.rows < 1 || h.cols < 1 {
		h.cols, h.rows = a.paneGrid(a.find.pane)
	}
	origin := histOrigin(h.hits[h.deep].back, h.rows)
	// The same page, already on show: another match on it does not
	// fetch the page again.
	if h.open && h.term != nil && origin == h.origin {
		return
	}
	h.origin = origin
	h.open = true
	a.loadHist()
}

// paneGrid is the pane's size in cells, or a stand-in before one is known.
func (a *App) paneGrid(id string) (cols, rows int) {
	if s := a.session(a.selected); s != nil {
		if p := s.PaneByID(id); p != nil && p.Cols > 0 && p.Rows > 0 {
			return p.Cols, p.Rows
		}
	}
	return 80, 24
}

// scrollHistory moves the overlay's page by delta lines, toward older
// output when delta is positive.
func (a *App) scrollHistory(delta int) {
	h := &a.find.hist
	if !h.open || delta == 0 {
		return
	}
	next := h.origin + delta
	if next < 0 {
		next = 0
	}
	if h.total > 0 && next > h.total-1 {
		next = h.total - 1
	}
	if next == h.origin {
		return
	}
	h.origin = next
	a.loadHist()
}

// loadHist asks kerod for the page the overlay shows. A page already on
// its way is left to arrive; the one wanted then is asked for next, so
// a fling of the wheel is not a request per notch.
func (a *App) loadHist() {
	h := &a.find.hist
	if !h.open {
		return
	}
	if h.loading {
		h.dirty = true
		return
	}
	rows, cols := h.rows, h.cols
	if rows < 1 {
		rows = 24
	}
	if cols < 1 {
		cols = 80
	}
	if h.total > 0 && h.origin > h.total-1 {
		h.origin = h.total - 1
	}
	origin := h.origin
	h.loadID++
	id := h.loadID
	gen := h.gen.Load()
	h.loading, h.dirty = true, false
	pane := a.find.pane
	cl := a.hostOf(pane).cl
	if cl == nil {
		h.loading = false
		return
	}
	go func() {
		if a.find.hist.gen.Load() != gen {
			a.finishHistLoad(id)
			return
		}
		var res proto.ReadResult
		err := cl.Call("read", proto.ReadParams{
			ID: pane, Scrollback: true, Styled: true, Lines: rows, Offset: origin,
		}, &res)
		a.update(func() {
			h := &a.find.hist
			if h.loadID != id {
				return
			}
			h.loading = false
			if h.gen.Load() != gen || !h.open {
				return
			}
			switch {
			case err != nil:
				h.err = err.Error()
			case h.origin == origin && h.rows == rows && h.cols == cols:
				h.total = res.Total
				h.err = ""
				a.feedHist(res.VT, rows)
			default:
				h.dirty = true
			}
			if h.dirty && h.open {
				a.loadHist()
			}
		})
	}()
}

func (a *App) finishHistLoad(id int) {
	a.update(func() {
		if a.find.hist.loadID == id {
			a.find.hist.loading = false
		}
	})
}

// feedHist shows vt in the overlay, a page at a time. The terminal keeps
// no scrollback of its own: the wheel asks kerod for the neighboring page
// instead, which is the history the app does not hold.
func (a *App) feedHist(vt string, rows int) {
	h := &a.find.hist
	if h.term == nil {
		conn := &previewConn{done: make(chan struct{})}
		light, dark := a.termThemes()
		term, err := terminal.New(terminal.Options{
			Conn: conn, Font: a.termFont(), Theme: light, DarkTheme: dark,
			Padding:    terminal.Padding{X: 16, Y: 6},
			Scrollback: -1,
			OnScroll: func(rows int) bool {
				d := -rows
				a.defer_(func() { a.scrollHistory(d) })
				return true
			},
		})
		if err != nil {
			conn.Close()
			h.err = err.Error()
			return
		}
		h.term, h.conn = term, conn
	}
	// The view sizes the terminal. Resizing here too fights that, and
	// the next frame then asks for the page all over again.
	b := make([]byte, 0, len(vt)+8)
	b = append(b, "\x1bc\x1b[?25l"...)
	b = append(b, vt...)
	h.term.Feed(b)
	h.haveRows = rows
}

// historyOverlay covers the pane with the page of history on show, under
// the find bar, which is drawn after it.
func (a *App) historyOverlay(c *ui.Context, pal *palette) {
	h := &a.find.hist
	if !h.open {
		return
	}
	box := ui.Box(c.Key("history")).Absolute().Top(0).Left(0).Right(0).Bottom(0).Label(locales.FindHistory())
	if box.Shortcut(0, ui.KeyEscape) {
		a.defer_(a.closeFind)
	}
	box.Children(func() {
		switch {
		case h.term != nil:
			terminal.View(c.Key("hterm"), h.term).Fill()
			cols, rows := h.term.Size()
			if rows > 1 && cols > 1 && (cols != h.cols || rows != h.rows) {
				h.cols, h.rows = cols, rows
				if h.in && h.deep >= 0 && h.deep < len(h.hits) && h.haveRows < 1 {
					h.origin = histOrigin(h.hits[h.deep].back, rows)
				}
				a.loadHist()
			}
		case h.err != "":
			ui.Column(c).Fill().Center().Padding(24).Children(func() {
				ui.Text(c, h.err).FontSize(12.5).TextColor(pal.textMuted)
			})
		default:
			ui.Column(c).Fill().Center().Children(func() { ui.Spinner(c) })
		}
		ui.Row(c.Key("htag")).Absolute().Top(8).Left(12).Height(22).Padding(0, 9).Radius(11).
			AlignItems(ui.Center).Background(pal.chip).TextColor(pal.textMuted).Children(func() {
			ui.Text(c, locales.FindHistory()).FontSize(12).FontWeight(500)
		})
	})
}

// stopHist drops the search and its overlay. A read still on its way
// then has nothing to deliver to.
func (a *App) stopHist() {
	h := &a.find.hist
	h.gen.Add(1)
	h.pane, h.query = "", ""
	h.hits = nil
	h.in, h.searching, h.done, h.clipped = false, false, false, false
	h.deep, h.edge = 0, 0
	h.err = ""
	h.loadID++
	h.loading, h.dirty = false, false
	a.closeHistView()
}

// closeHistView closes the overlay's terminal, keeping the matches.
func (a *App) closeHistView() {
	h := &a.find.hist
	h.open = false
	h.loadID++
	h.loading, h.dirty = false, false
	if h.term != nil {
		h.term.Close()
		h.term = nil
	}
	if h.conn != nil {
		h.conn.Close()
		h.conn = nil
	}
	h.haveRows = 0
}
