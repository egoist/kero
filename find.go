package main

import (
	"unicode/utf8"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"

	"kero/locales"
)

// findState is the find bar's: a search of a pane's output, its scrollback
// included, as Ghostty's find.
type findState struct {
	pane  string // the pane searched; "" while the bar is closed
	query string
	// focus has the field take the keyboard, its text selected, as the
	// bar opens.
	focus bool
	input ui.Handle
	// hist is the matches beyond what the pane's own terminal holds,
	// and the page of history shown for one of them.
	hist histSearch
}

// openFind opens the find bar over the pane the user is in, or gives the
// keyboard back to it, with the last query to type over.
func (a *App) openFind() {
	s := a.session(a.selected)
	if s == nil {
		return
	}
	id := a.focusOf(s)
	if id == "" {
		return
	}
	if a.find.pane != id {
		if t := a.findTerm(); t != nil {
			t.EndSearch()
		}
		a.stopHist()
	}
	a.find.pane, a.find.focus = id, true
}

// findStep goes to the next match, toward older output, or the previous
// one; with the bar closed it opens, the last query searched again.
func (a *App) findStep(back bool) {
	if a.find.pane == "" {
		a.openFind()
		return
	}
	if e := a.webs[a.find.pane]; e != nil {
		a.findInPage(e, true, back)
		return
	}
	t := a.findTerm()
	if t == nil {
		return
	}
	a.stepTermFind(t, back)
}

// closeFind closes the find bar, its highlights going, and gives the
// keyboard back to the pane.
func (a *App) closeFind() {
	if t := a.findTerm(); t != nil {
		t.EndSearch()
	}
	a.stopHist()
	pane := a.find.pane
	if e := a.webs[pane]; e != nil && e.view != nil {
		e.findText, e.found = "", mygo.FindResult{}
		e.findSeq++
		go e.view.Page().StopFindInPage()
	}
	a.find.pane = ""
	if pane != "" {
		a.focusPane(pane)
	}
}

// findTerm returns the terminal of the pane searched.
func (a *App) findTerm() *terminal.Terminal {
	if e := a.terms[a.find.pane]; e != nil {
		return e.term
	}
	return nil
}

// findBar floats over the top right of the pane searched: the query, how
// many matches it has, and the buttons going through them.
func (a *App) findBar(c *ui.Context, pal *palette, p *proto.Pane, t *terminal.Terminal) {
	f := &a.find
	// A terminal attached anew, as settings change, searches again.
	if f.query != "" && t.SearchStatus().Text != f.query {
		t.Search(f.query)
	}
	bar := ui.Row(c.Key("find")).Absolute().Top(8).Right(12).Height(36).Padding(0, 4, 0, 12).Gap(4).
		AlignItems(ui.Center).Radius(10).Background(pal.popover).Label(locales.FindLabel())
	floating(bar, pal).Children(func() {
		ui.Icon(c, searchIcon).Size(13, 13).TextColor(pal.textMuted).Shrink(0)
		in := ui.TextInputBase(c.Key("q"), &f.query).Width(180).FontSize(13).Placeholder(locales.FindPlaceholder()).Bind(&f.input)
		if f.focus {
			f.focus = false
			in.Focus().SetTextSelection(0, utf8.RuneCountInString(f.query))
		}
		if in.Changed() {
			t.Search(f.query)
		}
		// After the field, so a query typed this frame is the one searched.
		// What this terminal holds is its own find; the rest is kerod's.
		a.searchHist(t)
		switch {
		case in.Submitted() && c.Modifiers()&ui.Shift != 0:
			a.findStep(true)
		case in.Submitted():
			a.findStep(false)
		}
		st := t.SearchStatus()
		if f.query != "" && st.Total == 0 && !st.Searching {
			a.considerHist()
		}
		h := &f.hist
		total := st.Total + len(h.hits)
		selected := st.Selected
		if h.in && h.deep < len(h.hits) {
			selected = st.Total + h.deep + 1
		}
		searching := st.Searching || h.searching
		count := ""
		switch {
		case f.query == "":
		case total == 0 && !searching && h.err == "":
			count = locales.FindNoMatches()
		case total > 0:
			n := itoa(total)
			if h.clipped {
				n += "+"
			}
			count = locales.FindCount(itoa(selected), n)
		}
		ui.Text(c, count).FontSize(12).FontFeatures("tnum").TextColor(pal.textFaint).SingleLine().MinWidth(56).TextAlign(ui.End).Margin(0, 4, 0, 0)
		// Up goes back through the output, as Enter does, as in Ghostty.
		// Past what this terminal holds, that is the older history.
		iconButton(c, "next", chevronUpIcon, a.tip(locales.ActionFindNext(), "find.next"), pal, func() { a.findStep(false) })
		iconButton(c, "previous", chevronDownIcon, a.tip(locales.ActionFindPrevious(), "find.previous"), pal, func() { a.findStep(true) })
		iconButton(c, "close", closeIcon, locales.FindClose(), pal, func() { a.defer_(a.closeFind) })
	})
	// Escape closes it from its field and its buttons alike.
	if bar.Shortcut(0, ui.KeyEscape) {
		a.defer_(a.closeFind)
	}
}
