package main

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/locales"
)

// blockLabelFrom is how long a command takes for its marker to tell it: a
// quick ls adds nothing to read.
const blockLabelFrom = 2000 // ms

// paneBlocks is what the app knows of a pane's commands: kerod's blocks, as it
// last told them, and where they show in the terminal, which a block leaves
// to its line's text (proto.Block). kerod tells nothing to an app that doesn't
// ask, and an older kerod has nothing to tell: the list stays empty, and the
// pane is as it was.
type paneBlocks struct {
	list []proto.Block
	// located is list as it was last found in the terminal's text, which
	// the markers draw until it is found again, so that they stay as a
	// command ends. rows are the rows each of it starts its line on, lines
	// the lines of the text, -1 for one not found; checked those whose row
	// was checked against the screen, as WrappedRows counts near enough.
	located     []proto.Block
	rows, lines []int
	checked     []bool
	rev         uint64
	fetching    bool
	// total and cols are the terminal's rows and columns as last seen: a
	// narrower terminal, or fewer rows, moved the rows under the blocks.
	total, cols int
	dirty       bool
	resolving   bool
}

// fetchBlocks asks kerod for the blocks of a pane it says changed.
func (a *App) fetchBlocks(id string, e *termEntry, rev uint64) {
	cl := a.hostOf(id).cl
	if cl == nil {
		return
	}
	b := &e.blocks
	b.fetching = true
	// From the first still running, which comes again as it ended.
	since := uint64(1)
	if rev > b.rev {
		for i, bl := range b.list {
			since = bl.Seq + 1
			if bl.Ms < 0 {
				since = b.list[i].Seq
				break
			}
		}
	}
	go func() {
		var r proto.BlocksResult
		err := cl.Call("pane.blocks", proto.BlocksParams{ID: id, Since: since}, &r)
		a.update(func() {
			b.fetching = false
			if err != nil || a.terms[id] != e {
				return
			}
			// Into a list of its own: located may hold this one.
			b.list = append(slices.DeleteFunc(slices.Clone(b.list), func(bl proto.Block) bool { return bl.Seq >= since || bl.Seq < r.First }), r.Blocks...)
			b.rev, b.dirty = rev, true
			if a.win != nil {
				a.win.Invalidate()
			}
		})
	}()
}

// locate finds where the blocks show in the terminal's text.
func (b *paneBlocks) locate(text string, cols int) {
	lines := make([]string, len(b.list))
	for i, bl := range b.list {
		lines[i] = bl.Line
	}
	b.lines = proto.MatchBlocks(text, lines)
	var found []int
	for _, l := range b.lines {
		if l >= 0 {
			found = append(found, l)
		}
	}
	rows := proto.LocateRows(text, cols, found)
	b.rows = make([]int, len(lines))
	for i, k := 0, 0; i < len(lines); i++ {
		b.rows[i] = -1
		if b.lines[i] >= 0 {
			b.rows[i] = rows[k]
			k++
		}
	}
	b.checked = make([]bool, len(lines))
	b.located = b.list
	b.dirty = false
}

// resolveLater finds where the blocks show off the main thread: the text is
// as long as the scrollback.
func (a *App) resolveLater(id string, e *termEntry, cols int) {
	b := &e.blocks
	b.resolving = true
	list := b.list
	go func() {
		text := e.term.Text()
		a.update(func() {
			b.resolving = false
			if a.terms[id] != e || len(b.list) != len(list) || !sameBlocks(b.list, list) {
				return
			}
			b.locate(text, cols)
			if a.win != nil {
				a.win.Invalidate()
			}
		})
	}()
}

func sameBlocks(a, b []proto.Block) bool {
	return len(a) == 0 || a[0].Seq == b[0].Seq && a[len(a)-1].Seq == b[len(b)-1].Seq
}

// rowMatches tells whether a row of the viewport shows a block's line.
func rowMatches(t *terminal.Terminal, y int, line string) bool {
	shown, want := []rune(strings.TrimRight(t.RowText(y), " ")), []rune(line)
	n := min(len(shown), len(want))
	return n > 0 && slices.Equal(shown[:n], want[:n])
}

// checkRow corrects the row of a block in the viewport by what the screen
// shows, the nearest row that shows its line, or -1 when none does.
func checkRow(t *terminal.Terminal, line string, row int, v terminal.Viewport) int {
	if rowMatches(t, row-v.Top, line) {
		return row
	}
	for d := 1; d < v.Rows; d++ {
		for _, r := range []int{row - d, row + d} {
			if r >= v.Top && r < v.Top+v.Rows && rowMatches(t, r-v.Top, line) {
				return r
			}
		}
	}
	return -1
}

// focusedTerm returns the terminal and entry of the pane the user is in, nil
// for none or a browser.
func (a *App) focusedTerm() (string, *termEntry) {
	s := a.session(a.selected)
	if s == nil {
		return "", nil
	}
	id := a.focusOf(s)
	e := a.terms[id]
	if e == nil || e.term == nil {
		return "", nil
	}
	return id, e
}

// starts returns the row each of the found blocks starts on, its prompt
// included, ascending, with their indexes in list.
func (b *paneBlocks) starts() (rows, of []int) {
	for i, r := range b.rows {
		if r >= 0 {
			rows = append(rows, max(r-b.list[i].Up, 0))
			of = append(of, i)
		}
	}
	return rows, of
}

// jumpPrompt scrolls the pane the user is in to the prompt before the one at
// the top of its viewport (dir -1), or after it (dir 1), as Ghostty's
// jump_to_prompt does; past the last, to the bottom.
func (a *App) jumpPrompt(dir int) {
	_, e := a.focusedTerm()
	if e == nil {
		return
	}
	v := e.term.Viewport()
	if v.Cols == 0 || v.Alt {
		return
	}
	b := &e.blocks
	if len(b.list) == 0 {
		a.toast(locales.ToastNoCommands())
		return
	}
	b.locate(e.term.Text(), v.Cols)
	rows, of := b.starts()
	target := -1
	if dir < 0 {
		for i := len(rows) - 1; i >= 0 && target < 0; i-- {
			if rows[i] < v.Top {
				target = i
			}
		}
	} else {
		for i := range rows {
			if rows[i] > v.Top {
				target = i
				break
			}
		}
		if target < 0 {
			e.term.ScrollToBottom()
			return
		}
	}
	if target < 0 {
		return
	}
	e.term.ScrollToRow(rows[target])
	// WrappedRows counts near enough: the screen tells where it is.
	i := of[target]
	if r := checkRow(e.term, b.list[i].Line, b.rows[i], e.term.Viewport()); r >= 0 && r != b.rows[i] {
		e.term.ScrollToRow(max(r-b.list[i].Up, 0))
	}
}

// blockAt returns the index of the block the user is looking at in the
// pane: the last finished one when the pane shows its end, else the first that
// starts in the top third of the viewport, else the one its top is in; -1 for
// none.
func (b *paneBlocks) blockAt(v terminal.Viewport) int {
	rows, of := b.starts()
	if v.AtBottom {
		for i := len(of) - 1; i >= 0; i-- {
			if b.list[of[i]].Ms >= 0 {
				return of[i]
			}
		}
		return -1
	}
	best := -1
	for i, r := range rows {
		if r >= v.Top && r <= v.Top+v.Rows/3 {
			return of[i]
		}
		if r < v.Top {
			best = of[i]
		}
	}
	if best < 0 && len(of) > 0 {
		best = of[0]
	}
	return best
}

// copyOutput copies the output of the command the user is looking at (blockAt)
// in the pane they are in.
func (a *App) copyOutput() {
	_, e := a.focusedTerm()
	if e == nil {
		return
	}
	b := &e.blocks
	v := e.term.Viewport()
	if v.Cols == 0 || v.Alt {
		return
	}
	if len(b.list) == 0 {
		a.toast(locales.ToastNoCommands())
		return
	}
	text := e.term.Text()
	b.locate(text, v.Cols)
	i := b.blockAt(v)
	if i < 0 {
		a.toast(locales.ToastCommandGone())
		return
	}
	// A count kerod couldn't tell, as of one that runs: up to the next
	// block.
	before := -1
	if i+1 < len(b.list) && b.lines[i+1] >= 0 {
		before = b.lines[i+1] - b.list[i+1].Up
	}
	out := proto.BlockOutput(text, b.lines[i], b.list[i].Output, before)
	if out == "" {
		a.toast(locales.ToastOutputEmpty())
		return
	}
	mygo.Clipboard.WriteText(out)
	a.toast(locales.ToastOutputCopied())
}

// formatDuration writes how long something took, as "3.2s", "2m 3s" or
// "1h 2m".
func formatDuration(ms int64) string {
	s := ms / 1000
	switch {
	case s < 10 && ms%1000 != 0:
		return strconv.FormatFloat(float64(ms)/1000, 'f', 1, 64) + "s"
	case s < 60:
		return strconv.FormatInt(s, 10) + "s"
	case s < 3600:
		if s%60 == 0 {
			return strconv.FormatInt(s/60, 10) + "m"
		}
		return fmt.Sprintf("%dm %ds", s/60, s%60)
	}
	if s%3600/60 == 0 {
		return strconv.FormatInt(s/3600, 10) + "h"
	}
	return fmt.Sprintf("%dh %dm", s/3600, s%3600/60)
}

// blockLabel is what a block's marker says beside its row, "" for one with
// nothing to say: a command that went well, quickly.
func blockLabel(b proto.Block) string {
	if b.Ms < 0 {
		return ""
	}
	took := ""
	if b.Ms >= blockLabelFrom {
		took = formatDuration(b.Ms)
	}
	if !b.Failed() {
		return took
	}
	exit := locales.BlockExit(strconv.Itoa(*b.Exit))
	if took != "" {
		return exit + " · " + took
	}
	return exit
}

// blockMarkers draws, over a pane's terminal, the markers of the commands in
// its viewport: a failed one's icon in the padding left of its row, and what
// it took, at its row's right, where the row leaves room. They ask for no
// input, and draw only what the theme colors.
func (a *App) blockMarkers(c *ui.Context, pal *palette, p *proto.Pane, e *termEntry) {
	b := &e.blocks
	// Asked for once it is shown: a pane no one looks at needs none.
	if p.Commands != nil && p.Commands.Rev != b.rev && !b.fetching {
		a.fetchBlocks(p.ID, e, p.Commands.Rev)
	}
	if len(b.list) == 0 {
		return
	}
	v := e.term.Viewport()
	if v.Cols == 0 || v.Alt {
		return
	}
	if v.Cols != b.cols || v.Total < b.total {
		b.dirty = true
	}
	b.cols, b.total = v.Cols, v.Total
	if b.dirty && !b.resolving {
		a.resolveLater(p.ID, e, v.Cols)
	}
	rowH, top, ok := e.term.RowMetrics()
	if !ok {
		return
	}
	red := lookFor(c).term.Palette[1]
	for i, bl := range b.located {
		label := blockLabel(bl)
		if label == "" && !bl.Failed() {
			continue
		}
		row := b.rows[i]
		if row < v.Top || row >= v.Top+v.Rows {
			continue
		}
		if !b.checked[i] {
			b.checked[i] = true
			if row = checkRow(e.term, bl.Line, row, v); row < 0 {
				b.rows[i] = -1
				continue
			}
			b.rows[i] = row
		}
		y := top + float32(row-v.Top)*rowH
		key := "block" + strconv.FormatUint(bl.Seq, 10)
		if bl.Failed() {
			ui.Row(c.Key(key + "i")).Absolute().Top(y).Left(0).Width(16).Height(rowH).Center().PassThrough().Children(func() {
				ui.Icon(c, failedIcon).Size(10, 10).TextColor(red)
			})
		}
		if label == "" || proto.WrappedRows(bl.Line, v.Cols) > 1 || proto.LineCells(bl.Line)+len(label)+3 > v.Cols {
			continue
		}
		color := pal.textFaint
		if bl.Failed() {
			color = red
		}
		ui.Row(c.Key(key + "l")).Absolute().Top(y).Right(16).Height(rowH).AlignItems(ui.Center).PassThrough().Children(func() {
			ui.Text(c, label).FontSize(11).FontFeatures("tnum").TextColor(color).SingleLine()
		})
	}
}

// notifyCommands tells about commands that ran long and ended while the user
// was elsewhere. A coding agent's end is told by notify, by its status.
func (a *App) notifyCommands(first bool) {
	seen := make(map[string]uint64, len(a.commandEnds))
	for i := range a.st.Sessions {
		s := &a.st.Sessions[i]
		if h := a.hostOf(s.ID); h.remote() && h.conn != connReady {
			continue
		}
		for j := range s.Panes {
			p := &s.Panes[j]
			if p.Commands == nil {
				continue
			}
			seen[p.ID] = p.Commands.Last
			prev, known := a.commandEnds[p.ID]
			if first || !known || prev == p.Commands.Last || p.Commands.Last == 0 {
				continue
			}
			if !commandWorthTelling(p.Commands, a.set.NotifyLongCommand, a.set.LongCommandSeconds) || a.watching(s.ID) {
				continue
			}
			name := p.Commands.Name
			if name == "" {
				name = locales.NotifyCommandUnnamed()
			}
			took := formatDuration(p.Commands.Ms)
			body := locales.NotifyCommandDoneBody(name, took)
			if p.Commands.ExitKnown && p.Commands.Exit != 0 {
				body = locales.NotifyCommandFailedBody(name, strconv.Itoa(p.Commands.Exit), took)
			}
			a.showNotification(s.ID, a.hostedName(s), body)
		}
	}
	a.commandEnds = seen
}

// commandWorthTelling tells whether a command's end is worth a notification.
func commandWorthTelling(c *proto.Commands, on bool, seconds int) bool {
	return on && !c.Quiet && c.Ms >= time.Duration(seconds*int(time.Second)).Milliseconds()
}
