package main

import (
	"fmt"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/git"
	"kero/internal/proto"

	"kero/locales"
)

// The side panel stands at the right of a session's panes, a card of its
// own, with what the session's worktree is about. It has views, each a
// list whose item opens in the panel as a file: Changes, the files the
// session's agent or the user changed, each opening as its diff; a Files
// view, the worktree's tree, each file opening as its text, is to join it
// with the same header, list and file.

// sideChanges is the Changes view's id, as prefs.Side holds it.
const sideChanges = "changes"

const (
	defaultSide = 420 // the panel's width, as it first opens
	minSide     = 300
	minPanes    = 360 // the room the panel leaves the panes
	splitWidth  = 760 // past which diff-layout auto shows diffs side by side
)

// sideState is the panel's, beside the prefs that open it and size it.
type sideState struct {
	drag    float32 // the width as a drag of the edge began, 0 while none
	focused bool    // the panel has the keyboard: its Escape, its diff's find
	changes changesState
	// theme is the diffs' colors, made again only as the window's
	// appearance or the terminals' themes change.
	theme    *editor.Theme
	themeKey string
}

// changesState is the Changes view's: the files changed since a base,
// each with its diff, one after the other in one scroll.
type changesState struct {
	base string // the base chosen: git.BaseTurn, BaseHead or BaseBranch
	// scope is the pane and base the list is of, and stamp what of its
	// worktree it was fetched at; busy while a fetch is under way.
	scope   string
	stamp   string
	busy    bool
	since   time.Time
	fetched time.Time
	res     *proto.GitChanges
	err     string
	// lists are the lists fetched, by scope, which a base shows again at
	// once as the user comes back to it, while it is fetched anew; shown
	// is the scope the view last showed, and switched when it came to.
	lists    map[string]*proto.GitChanges
	shown    string
	switched time.Time
	// files are the files' diffs, by scope and path, kept as the list is
	// fetched anew; collapsed the files the user folded or unfolded, by
	// the same key; focus the file whose diff has the keyboard, for Find.
	files     map[string]*sideFile
	collapsed map[string]bool
	focus     *sideFile
	// places are the lists' places, by scope.
	places map[string]*ui.ListState
}

// sideFile is a changed file's diff since a base.
type sideFile struct {
	pane, base string
	f          proto.GitFile     // the file as listed when its text was asked for
	d          *editor.DiffState // nil until its text comes, or for a binary file
	patch      bool              // d shows a patch: a file too large to show whole
	hash       string            // the file's on disk, as d shows it
	text       proto.GitText     // what came of it last, but its text
	stamp      string            // the worktree's stamp it was fetched at
	busy       bool
	writing    bool
	err        string
}

// toggleSide shows a view of the panel, or hides the panel when it shows
// it.
func (a *App) toggleSide(view string) {
	if a.prefs.Side == view {
		a.prefs.Side = ""
		a.side.focused = false
		a.focusTerminal()
	} else {
		a.prefs.Side = view
	}
	a.savePrefs()
}

// sideWidth is the panel's width in a row of width w, leaving the panes
// their room.
func (a *App) sideWidth(w float32) float32 {
	sw := a.prefs.SideWidth
	if sw == 0 {
		sw = defaultSide
	}
	if w > 0 {
		sw = min(sw, w-minPanes)
	}
	return max(sw, minSide)
}

// sideEdge is the gap between the panes and the panel, which a drag moves.
func (a *App) sideEdge(c *ui.Context, pal *palette, row float32) {
	d := ui.Box(c.Key("side-edge")).Width(paneGap).Shrink(0).Cursor(ui.CursorResizeColumn)
	if d.Hovered() || d.Pressed() {
		d.Draw(func(p *ui.Painter, r ui.Rect) {
			p.Fill(ui.Rect{X: r.X + r.W/2 - 1.5, Y: r.Y + r.H/2 - 18, W: 3, H: 36}, pal.textFaint.Alpha(0.7), 1.5)
		})
	}
	if dx, _, ok := d.Dragged(); ok {
		if a.side.drag == 0 {
			a.side.drag = a.sideWidth(row)
		}
		a.side.drag -= dx
		a.prefs.SideWidth = min(max(a.side.drag, minSide), max(row-minPanes, minSide))
	} else if a.side.drag != 0 && !d.Pressed() {
		a.side.drag = 0
		a.savePrefs()
	}
	if d.DoubleClicked() {
		a.prefs.SideWidth = defaultSide
		a.savePrefs()
	}
}

// sidePanel is the panel's card: its header, then its view. top and right
// tell that it touches the window's top and right edges, where its header
// drags the window and holds the window's controls (windowControls).
func (a *App) sidePanel(c *ui.Context, pal *palette, s *proto.Session, width float32, right bool) {
	card := ui.Column(c.Key("side")).Width(width).Shrink(0).MinHeight(0).Radius(14).Clip().Background(pal.card).
		Focusable().Bind(a.paneRef("side-card"))
	raised(card, pal)
	a.side.focused = card.FocusWithin()
	card.Children(func() {
		ui.Row(c.Key("hdr")).Height(headerH).Shrink(0).AlignItems(ui.Center).Padding(0, 10, 0, 16).Gap(8).Children(func() {
			// What the view shows, as a pane's header shows its program.
			ui.Icon(c, diffIcon).Size(14, 14).TextColor(pal.textFaint)
			ui.Text(c, locales.SideChanges()).FontSize(14).FontWeight(600).TextColor(pal.text).SingleLine().Shrink(0)
			if dir := a.changesDir(s); dir != "" {
				ui.Text(c, a.hostOf(s.ID).shortDir(dir)).FontSize(13).TextColor(pal.textFaint).SingleLine().Ellipsis("…").Shrink(2).MinWidth(0).Tooltip(dir)
			}
			ui.Box(c.Key("drag")).Grow(1).AlignSelf(ui.Stretch).DragWindow()
			iconButton(c, "close-side", closeIcon, a.tip(locales.SideClose(), "changes.toggle"), pal, func() { a.defer_(func() { a.toggleSide(a.prefs.Side) }) })
			if right {
				windowControls(c, pal, a.win)
			}
		})
		ui.Column(c.Key("body")).Grow(1).MinHeight(0).AlignItems(ui.Stretch).Children(func() {
			a.changesView(c, pal, s, width)
		})
	})
	if card.Shortcut(0, ui.KeyEscape) {
		a.focusTerminal()
	}
}

// --- the Changes view ---

// changesPanes returns the panes the Changes view is of: the one the user
// is in, whose worktree it shows, and the one of the session whose agent
// last started a turn, the user's first, nil for none.
func (a *App) changesPanes(s *proto.Session) (here, turn *proto.Pane) {
	here = s.PaneByID(a.focusOf(s))
	if here == nil {
		return nil, nil
	}
	if here.Turn != nil {
		return here, here
	}
	for i := range s.Panes {
		p := &s.Panes[i]
		if p.Turn != nil && (turn == nil || p.Turn.At > turn.Turn.At) {
			turn = p
		}
	}
	return here, turn
}

// changesDir is the worktree the Changes view lists: the agent's where
// it shows its turn, else the one of the pane the user is in; "" for none.
func (a *App) changesDir(s *proto.Session) string {
	here, turn := a.changesPanes(s)
	switch {
	case turn != nil && (a.side.changes.base == git.BaseTurn || here.Git == nil):
		return turn.Turn.Root
	case here != nil && here.Git != nil:
		return here.Git.Root
	}
	return ""
}

// changesScope names what the Changes view lists for a pane since a
// base: its worktree's changes, or its turn's, which the list, its files'
// diffs, folds and scroll position are kept by.
func changesScope(p *proto.Pane, base string) string {
	if base == git.BaseTurn && p.Turn != nil {
		return p.Turn.Root + "|" + p.Turn.Tree + "|" + base
	}
	if p.Git != nil {
		return p.Git.Root + "|" + base
	}
	return p.ID + "|" + base
}

// gitStamp is what of a worktree's status changes its changes.
func gitStamp(g *proto.GitInfo) string {
	if g == nil {
		return ""
	}
	return fmt.Sprint(g.Root, g.Head, g.Branch, g.Files, g.Added, g.Removed)
}

func (a *App) changesView(c *ui.Context, pal *palette, s *proto.Session, width float32) {
	ch := &a.side.changes
	here, turn := a.changesPanes(s)
	if !a.set.GitStatus {
		a.sideMessage(c, pal, locales.ChangesGitOff(), locales.ChangesGitOffDetail())
		return
	}
	if here == nil || here.Git == nil && turn == nil {
		a.sideMessage(c, pal, locales.ChangesNoRepo(), locales.ChangesNoRepoDetail())
		return
	}

	// The bases this worktree offers, and the one shown: the agent's turn
	// first, as the panel opens.
	var bases, labels, tips []string
	if turn != nil {
		bases, labels, tips = append(bases, git.BaseTurn), append(labels, locales.ChangesTurn()), append(tips, locales.ChangesTurnTip())
	}
	if here.Git != nil {
		bases, labels, tips = append(bases, git.BaseHead), append(labels, locales.ChangesUncommitted()), append(tips, locales.ChangesUncommittedTip())
		if d := here.Git.Default; d != "" {
			bases, labels, tips = append(bases, git.BaseBranch), append(labels, locales.ChangesBranch()), append(tips, locales.ChangesBranchTip(d))
		}
	}
	if !slices.Contains(bases, ch.base) {
		ch.base = bases[0]
	}
	pane := here
	if ch.base == git.BaseTurn {
		pane = turn
	}
	// The list is of a worktree, not of a pane: the panes the user moves
	// between in one show it as it was, scrolled where it was. A turn's is
	// of its snapshot.
	scope := changesScope(pane, ch.base)
	stamp := gitStamp(pane.Git)
	if pane.Turn != nil && ch.base == git.BaseTurn {
		stamp += "|" + pane.Turn.Tree
	}
	working := false
	for _, p := range s.Panes {
		working = working || p.Status == proto.Working
	}
	// The list follows the worktree: as its status changes, and every few
	// seconds while an agent works in the session, as a file can change
	// without its count of lines.
	stale := scope != ch.scope || stamp != ch.stamp || working && time.Since(ch.fetched) > 5*time.Second
	if stale && !ch.busy && a.hostOf(pane.ID).cl != nil {
		a.fetchChanges(scope, stamp, pane.ID, ch.base)
	}
	if working {
		c.After(5 * time.Second)
	}

	// The list of the base shown, else the one fetched last of it; one of
	// another base stays, faded, for the moment this one takes to come,
	// rather than blink away.
	if scope != ch.shown {
		ch.shown, ch.switched = scope, c.Now()
	}
	list, current := ch.res, ch.res != nil && ch.scope == scope
	if !current && ch.lists[scope] != nil {
		list, current = ch.lists[scope], true
	}
	held := !current && list != nil && c.Now().Sub(ch.switched) < 400*time.Millisecond
	if !current && !held {
		list = nil
	}

	ui.Column(c.Key("bases")).Shrink(0).Padding(2, 12, 6, 12).Gap(6).AlignItems(ui.Stretch).Children(func() {
		if len(bases) > 1 {
			ui.Row(c).Children(func() { segmented(c, "base", &ch.base, bases, labels) })
		}
		i := slices.Index(bases, ch.base)
		ui.Row(c).Height(28).Gap(8).AlignItems(ui.Center).Children(func() {
			if res := list; res != nil && len(res.Files) > 0 {
				added, removed := 0, 0
				for _, f := range res.Files {
					added, removed = added+f.Added, removed+f.Removed
				}
				ui.Text(c, locales.ChangesFiles(len(res.Files))).FontSize(12.5).TextColor(pal.textMuted).SingleLine().Shrink(0)
				a.lineCounts(c, pal, added, removed, 12.5)
				if ch.base == git.BaseBranch && res.BaseName != "" {
					ui.Text(c, locales.ChangesSince(res.BaseName)).FontSize(12.5).TextColor(pal.textFaint).SingleLine().Ellipsis("…").MinWidth(0)
				}
			} else {
				ui.Text(c, tips[i]).FontSize(12.5).TextColor(pal.textFaint).SingleLine().Ellipsis("…").MinWidth(0)
			}
			ui.Spacer(c)
			split := a.diffSplit(width)
			layoutIcon, layoutTip := splitRightIcon, locales.ChangesSplit()
			if split {
				layoutIcon, layoutTip = splitDownIcon, locales.ChangesUnified()
			}
			iconButton(c, "layout", layoutIcon, layoutTip, pal, func() {
				set := a.set
				set.DiffLayout = "split"
				if split {
					set.DiffLayout = "unified"
				}
				a.applySettings(set)
			})
		})
	})

	res := list
	if held {
		c.After(400 * time.Millisecond)
	}
	switch {
	case res == nil:
		if ch.err != "" && !ch.busy && ch.scope == scope {
			a.sideMessage(c, pal, locales.ChangesCantRead(), ch.err)
		} else if c.Now().Sub(ch.switched) > 250*time.Millisecond {
			ui.Column(c).Grow(1).Center().Children(func() { ui.Spinner(c) })
		} else {
			c.After(260 * time.Millisecond)
		}
	case len(res.Files) == 0 && held:
		// Another base's "no changes" would say the wrong thing.
	case len(res.Files) == 0:
		detail := map[string]string{git.BaseTurn: locales.ChangesNoneTurn(), git.BaseHead: locales.ChangesNoneUncommitted()}[ch.base]
		if ch.base == git.BaseBranch {
			detail = locales.ChangesNoneBranch(res.BaseName)
		}
		a.sideMessage(c, pal, locales.ChangesNone(), detail)
	default:
		if !held {
			a.syncFiles(c, scope, pane, res.Files)
		}
		if ch.places == nil {
			ch.places = map[string]*ui.ListState{}
		}
		ls := ch.places[scope]
		if ls == nil {
			ls = &ui.ListState{}
			ch.places[scope] = ls
		}
		// A file is two rows: its header, then its diff while unfolded,
		// which scrolls under the header as the list pins it at the top,
		// until the next file's header pushes it out, as the files of a
		// pull request do.
		var rows []changeRow
		for _, f := range res.Files {
			rows = append(rows, changeRow{f: f})
			if ch.files[scope+"|"+f.Path] != nil && !a.fileCollapsed(scope, f) {
				rows = append(rows, changeRow{f: f, diff: true})
			}
		}
		ls.Header = func(i int) bool { return !rows[i].diff }
		ls.Key = func(i int) any { return changeKey{rows[i].f.Path, rows[i].diff} }
		box := ui.Column(c.Key("files-" + scope)).Grow(1).MinHeight(0).AlignItems(ui.Stretch)
		box.Opacity(box.Animate("held", 1-0.45*b2f(held), 120*time.Millisecond))
		box.Children(func() {
			// The scroll bar runs below the header pinned at the top, not
			// under it.
			ui.List(c.Key("rows"), ls, len(rows), func(i int) {
				r := rows[i]
				if r.diff {
					a.fileDiff(c, pal, s, scope, r.f, width)
					return
				}
				// Opaque, over the diff scrolling under it; a folded file's
				// with the room below its section.
				gap := float32(sectionGap)
				if i+1 < len(rows) && rows[i+1].diff {
					gap = 0
				}
				ui.Column(c).FillWidth().AlignItems(ui.Stretch).Padding(0, 0, gap, 0).Background(pal.card).Children(func() {
					a.fileHeader(c, pal, scope, res.Root, r.f, func() {
						// Folding it as the list pins it brings it back where
						// it stays: at the top.
						ls.ScrollIntoView(i)
					})
				})
			}).Grow(1).MinHeight(0).Padding(0, 0, 16, 0).ScrollbarInsets(stickyH, 0, 0, 0)
		})
	}
}

// changeRow is a row of the list of changes: a file's header, or its
// diff; changeKey what it is, as the list keeps a row's state by.
type changeRow struct {
	f    proto.GitFile
	diff bool
}

type changeKey struct {
	path string
	diff bool
}

// stickyH is the height of a file's header, which the list pins at its
// top; sectionGap the room below each file's section.
const (
	stickyH    = 32
	sectionGap = 6
)

// syncFiles keeps the diffs of a list's files: it asks for the text of
// each file shown that has none yet, a few at a time, and again of one
// whose change the list counts anew (Known, so that kerod sends only what
// changed), or of every one as the worktree's HEAD moves.
func (a *App) syncFiles(c *ui.Context, scope string, pane *proto.Pane, files []proto.GitFile) {
	ch := &a.side.changes
	if ch.files == nil || len(ch.files) > 400 {
		ch.files = map[string]*sideFile{}
	}
	stamp := gitStamp(pane.Git)
	asking := 0
	for _, sf := range ch.files {
		if sf.busy {
			asking++
		}
	}
	for _, f := range files {
		key := scope + "|" + f.Path
		sf := ch.files[key]
		if sf == nil {
			sf = &sideFile{pane: pane.ID, base: ch.base, f: f}
			ch.files[key] = sf
		}
		if a.fileCollapsed(scope, f) || sf.busy || sf.writing || a.hostOf(pane.ID).cl == nil {
			continue
		}
		known := sf.hash
		switch {
		case sf.d == nil && !sf.text.Binary && !sf.text.Large && sf.err == "":
			known = "" // never shown
		case sf.stamp != stamp && sf.base != git.BaseTurn:
			known = "" // HEAD moved: the base's text too
		case sf.f != f:
		default:
			continue
		}
		if asking >= 4 {
			c.After(50 * time.Millisecond)
			return
		}
		asking++
		sf.f, sf.stamp = f, stamp
		a.fetchFile(sf, known)
	}
}

// fileCollapsed tells whether a file's diff is folded: as the user left
// it, else folded for a binary file or one of very many lines changed.
func (a *App) fileCollapsed(scope string, f proto.GitFile) bool {
	if v, ok := a.side.changes.collapsed[scope+"|"+f.Path]; ok {
		return v
	}
	return f.Binary || f.Added+f.Removed > 600
}

// fileDiff is a changed file's diff, under its header, or why it shows
// none.
func (a *App) fileDiff(c *ui.Context, pal *palette, s *proto.Session, scope string, f proto.GitFile, width float32) {
	ch := &a.side.changes
	sf := ch.files[scope+"|"+f.Path]
	ui.Column(c).FillWidth().AlignItems(ui.Stretch).Padding(4, 0, sectionGap, 0).Children(func() {
		switch {
		case sf.err != "" && sf.d == nil:
			a.sectionNote(c, pal, locales.ChangesCantRead()+": "+sf.err)
		case sf.text.Binary:
			a.sectionNote(c, pal, locales.ChangesBinary())
		case sf.text.Large && sf.d == nil:
			a.sectionNote(c, pal, locales.ChangesTooLarge())
		case sf.d == nil:
			ui.Column(c.Key("loading")).Height(48).Center().Children(func() { ui.Spinner(c) })
		default:
			a.diffOptions(c, pal, s, sf, width)
			diff := editor.DiffView(c.Key("diff"), sf.d)
			if diff.FocusWithin() {
				ch.focus = sf
			}
		}
	})
}

// fileHeader is a changed file's header: its change, its name and folder
// and the lines it adds and removes, which a click folds or unfolds,
// running folding first when set.
func (a *App) fileHeader(c *ui.Context, pal *palette, scope, root string, f proto.GitFile, folding func()) {
	ch := &a.side.changes
	key := scope + "|" + f.Path
	collapsed := a.fileCollapsed(scope, f)
	// Across the panel, edge to edge, its content in line with the bases'.
	hdr := ui.Row(c.Key("hdr")).Height(stickyH).Padding(0, 10, 0, 12).Gap(8).AlignItems(ui.Center).Background(pal.chip)
	if hdr.Hovered() {
		hdr.Background(pal.rowHover.Mix(pal.chip, 0.5))
	}
	tip := f.Path
	if f.OldPath != "" {
		tip = f.OldPath + " → " + f.Path
	}
	hdr.Tooltip(tip)
	if hdr.Clicked() {
		if folding != nil {
			folding()
		}
		if ch.collapsed == nil {
			ch.collapsed = map[string]bool{}
		}
		ch.collapsed[key] = !collapsed
	}
	hdr.Children(func() {
		chev := ui.Icon(c, chevronIcon).Size(10, 10).TextColor(pal.textFaint).Shrink(0)
		chev.Rotate(chev.AnimateTo("turn", 90*(1-b2f(collapsed)), ui.Snappy))
		a.statusBadge(c, pal, f.Status)
		dir, name := path.Split(f.Path)
		fg := pal.text
		if f.Status == "deleted" {
			fg = pal.textMuted
		}
		ui.Text(c, name).FontSize(13).FontWeight(600).TextColor(fg).SingleLine().Ellipsis("…").Shrink(0).MaxWidth(260)
		ui.Text(c, strings.TrimSuffix(dir, "/")).FontSize(12).TextColor(pal.textFaint).SingleLine().Ellipsis("…").Grow(1).MinWidth(0)
		if f.Binary {
			ui.Text(c, locales.ChangesBinary()).FontSize(11.5).TextColor(pal.textFaint).SingleLine()
		} else {
			a.lineCounts(c, pal, f.Added, f.Removed, 12)
		}
		if f.Status != "deleted" {
			full := filepath.Join(root, filepath.FromSlash(f.Path))
			iconButton(c, "open", openFileIcon, locales.ChangesOpenFile(), pal, func() { openPath(full) })
		}
	})
}

// sectionNote says why a file shows no diff.
func (a *App) sectionNote(c *ui.Context, pal *palette, text string) {
	ui.Text(c, text).FontSize(12.5).TextColor(pal.textMuted).Padding(10, 12).LineHeight(1.4)
}

// fetchChanges asks kerod for the list of a pane's changes since a base.
func (a *App) fetchChanges(scope, stamp, pane, base string) {
	ch := &a.side.changes
	ch.busy, ch.since = true, time.Now()
	if ch.scope != scope {
		ch.err = ""
	}
	cl := a.hostOf(pane).cl
	if cl == nil {
		ch.busy = false
		return
	}
	go func() {
		var res proto.GitChanges
		err := cl.Call("git.changes", proto.GitParams{Pane: pane, Base: base}, &res)
		a.update(func() {
			ch.busy, ch.fetched = false, time.Now()
			ch.scope, ch.stamp = scope, stamp
			if err != nil {
				ch.res, ch.err = nil, err.Error()
				delete(ch.lists, scope)
				return
			}
			ch.res, ch.err = &res, ""
			if ch.lists == nil || len(ch.lists) > 12 {
				ch.lists = map[string]*proto.GitChanges{}
			}
			ch.lists[scope] = &res
		})
	}()
}

// statusBadge is a file's change as a letter in its color: A added, M
// modified, D deleted, R renamed, T a change of type.
func (a *App) statusBadge(c *ui.Context, pal *palette, status string) {
	added, removed, modified := a.diffColors(pal)
	letter, col := "M", modified
	switch status {
	case "added":
		letter, col = "A", added
	case "deleted":
		letter, col = "D", removed
	case "renamed":
		letter, col = "R", modified
	case "type":
		letter = "T"
	}
	ui.Box(c).Size(18, 18).Radius(5).Shrink(0).Center().Background(col.Alpha(0.14)).Children(func() {
		ui.Text(c, letter).FontSize(11).FontWeight(650).TextColor(col).SingleLine()
	})
}

// lineCounts shows lines added and removed, as +12 −3, in the diffs'
// colors; nothing for none.
func (a *App) lineCounts(c *ui.Context, pal *palette, added, removed int, size float32) {
	if added == 0 && removed == 0 {
		return
	}
	plus, minus, _ := a.diffColors(pal)
	ui.Row(c).Gap(5).Shrink(0).Children(func() {
		if added > 0 {
			ui.Text(c, "+"+itoa(added)).FontSize(size).FontFeatures("tnum").TextColor(plus).SingleLine()
		}
		if removed > 0 {
			ui.Text(c, "−"+itoa(removed)).FontSize(size).FontFeatures("tnum").TextColor(minus).SingleLine()
		}
	})
}

// diffColors are the colors of lines added, removed and modified: the
// terminals' green, red and yellow, so that a diff reads as one printed in
// the pane beside it.
func (a *App) diffColors(pal *palette) (added, removed, modified ui.Color) {
	light, dark := a.termThemes()
	t := light
	if pal.dark {
		t = dark
	}
	return t.Palette[2], t.Palette[1], t.Palette[3]
}

// codeTheme is the diffs' colors: the card's, with the diff colors.
func (a *App) codeTheme(c *ui.Context, pal *palette) *editor.Theme {
	added, removed, modified := a.diffColors(pal)
	key := fmt.Sprint(pal.dark, added, removed, modified)
	if a.side.theme == nil || a.side.themeKey != key {
		t := editor.DefaultTheme(c.Theme())
		t.Background, t.Text = pal.card, pal.text
		t.Added, t.Deleted, t.Modified = added, removed, modified
		a.side.theme, a.side.themeKey = t, key
	}
	return a.side.theme
}

// sideMessage says why the view shows nothing.
func (a *App) sideMessage(c *ui.Context, pal *palette, title, detail string) {
	ui.Column(c).Grow(1).Center().Gap(6).Padding(24).Children(func() {
		ui.Text(c, title).FontSize(14).FontWeight(600).TextColor(pal.text).TextAlign(ui.Center)
		if detail != "" {
			ui.Text(c, detail).FontSize(12.5).TextColor(pal.textMuted).MaxWidth(300).TextAlign(ui.Center).LineHeight(1.4)
		}
	})
}

// --- a file's diff ---

// fetchFile asks kerod for a file's text in the base and now; known is
// the hash of the text shown, which kerod then sends again only when it
// changed.
func (a *App) fetchFile(sf *sideFile, known string) {
	cl := a.hostOf(sf.pane).cl
	if cl == nil {
		return
	}
	sf.busy = true
	go func() {
		var t proto.GitText
		err := cl.Call("git.file", proto.GitParams{Pane: sf.pane, Base: sf.base, Path: sf.f.Path, OldPath: sf.f.OldPath, Known: known}, &t)
		a.update(func() {
			sf.busy = false
			if err != nil {
				sf.err = err.Error()
				return
			}
			sf.err = ""
			if !t.Same {
				a.showText(sf, t)
			}
		})
	}()
}

// showText puts a file's text in its diff: anew for its first, else as
// edits, so that the diff keeps where it was scrolled.
func (a *App) showText(sf *sideFile, t proto.GitText) {
	sf.hash = t.Hash
	sf.text = proto.GitText{Binary: t.Binary, Large: t.Large}
	switch {
	case t.Binary || t.Large && t.Patch == "":
		sf.d, sf.patch = nil, false
	case t.Large:
		sf.d, sf.patch = &editor.DiffState{}, true
		if files, err := editor.ParsePatch(t.Patch); err == nil && len(files) > 0 {
			sf.d.SetPatch(files[0])
		}
	case sf.d == nil || sf.patch:
		lang := editor.LanguageFor(path.Base(sf.f.Path))
		old, now := editor.NewBuffer(t.Old), editor.NewBuffer(t.New)
		old.SetLanguage(lang)
		now.SetLanguage(lang)
		sf.d, sf.patch = &editor.DiffState{Old: old, New: now}, false
	default:
		replaceText(sf.d.Old, t.Old)
		replaceText(sf.d.New, t.New)
	}
}

// replaceText makes a buffer's text text by one edit of what differs
// between them, on whole characters.
func replaceText(b *editor.Buffer, text string) {
	cur := b.String()
	if cur == text {
		return
	}
	p := 0
	for p < len(cur) && p < len(text) && cur[p] == text[p] {
		p++
	}
	for p > 0 && p < len(cur) && !utf8.RuneStart(cur[p]) {
		p--
	}
	q := 0
	for q < len(cur)-p && q < len(text)-p && cur[len(cur)-1-q] == text[len(text)-1-q] {
		q++
	}
	for q > 0 && !utf8.RuneStart(cur[len(cur)-q]) {
		q--
	}
	b.Edit(editor.Edit{Start: p, End: len(cur) - q, Text: text[p : len(text)-q]})
}

// diffSplit tells whether diffs show side by side in a panel this wide.
func (a *App) diffSplit(width float32) bool {
	switch a.set.DiffLayout {
	case "split":
		return true
	case "unified":
		return false
	}
	return width >= splitWidth
}

// diffOptions sets a file's diff's looks and actions for this frame: in a
// turn, Revert and Keep on each change while no agent of the session
// works, as the user reviews what the agent did.
func (a *App) diffOptions(c *ui.Context, pal *palette, s *proto.Session, sf *sideFile, width float32) {
	d := sf.d
	d.FitContent = true
	d.Font = ui.Font{Family: a.termFamily(), Size: max(a.set.FontSize-1, 10)}
	d.Theme = a.codeTheme(c, pal)
	d.Layout = editor.DiffUnified
	if a.diffSplit(width) {
		d.Layout = editor.DiffSplit
	}
	working := false
	for _, p := range s.Panes {
		working = working || p.Status == proto.Working
	}
	d.RenderSeparator = func(c *ui.Context, sep ui.Element, s *editor.DiffSeparator) { a.separator(c, pal, sep, s) }
	d.HunkActions = sf.base == git.BaseTurn && !sf.patch && !working && !sf.writing
	d.RenderHunkActions = func(c *ui.Context, bar ui.Element, h *editor.DiffHunkActions) {
		floating(bar.Gap(2).Padding(3).Radius(8).Background(pal.popover).AlignItems(ui.Center), pal)
		bar.Children(func() {
			if hunkButton(c, "revert", revertIcon, locales.ChangesRevert(), locales.ChangesRevertTip(), pal) {
				h.Revert()
				a.writeBack(sf)
			}
			if hunkButton(c, "keep", checkIcon, locales.ChangesKeep(), locales.ChangesKeepTip(), pal) {
				h.Keep()
			}
		})
	}
}

// separator is a diff's unchanged lines collapsed between its changes:
// chevrons that show more of them, up or down, and "N unmodified lines",
// which shows them all, on the diff's own background, with no bar; or a
// patch's hunk's header. Shift shows them all from any of them.
func (a *App) separator(c *ui.Context, pal *palette, sep ui.Element, s *editor.DiffSeparator) {
	sep.Children(func() {
		// Its chevron under the file's header's: the header's starts 12 in,
		// 10 wide, and the button's icon, 11 wide, sits in 24.
		ui.Row(c).Grow(1).AlignSelf(ui.Stretch).AlignItems(ui.Center).Gap(2).Padding(0, 12, 0, 5).Children(func() {
			if s.Lines == 0 {
				ui.Text(c, s.Header).Font(s.Font().Family).FontSize(s.Font().Size-1).TextColor(pal.textFaint).SingleLine().Shrink(1).Padding(0, 7)
				return
			}
			expand := func(fn func()) func() {
				return func() {
					if c.Modifiers()&ui.Shift != 0 {
						fn = s.ExpandAll
					}
					fn()
				}
			}
			chevron := func(key string, svg *ui.SVG, label string, fn func()) {
				b := ui.ButtonBase(c.Key(key)).Size(24, 24).Radius(6).Center().TextColor(pal.textMuted).Label(label).Tooltip(label)
				if b.Hovered() || b.Pressed() {
					b.Background(pal.rowHover).TextColor(pal.text)
				}
				b.Children(func() { ui.Icon(c, svg).Size(11, 11) })
				if b.Clicked() {
					expand(fn)()
				}
			}
			switch {
			case s.First:
				chevron("up", chevronUpIcon, locales.ChangesExpandUp(), s.ExpandUp)
			case s.Last:
				chevron("down", chevronDownIcon, locales.ChangesExpandDown(), s.ExpandDown)
			case s.Lines <= s.Step:
				chevron("all", chevronIcon, locales.ChangesExpandAll(), s.ExpandAll)
			default:
				chevron("down", chevronDownIcon, locales.ChangesExpandDown(), s.ExpandDown)
				chevron("up", chevronUpIcon, locales.ChangesExpandUp(), s.ExpandUp)
			}
			label := locales.ChangesUnmodified(s.Lines)
			b := ui.ButtonBase(c.Key("lines")).Height(24).Padding(0, 4).Radius(6).AlignItems(ui.Center).Label(label).Tooltip(locales.ChangesExpandAll())
			b.Children(func() {
				fg := pal.textFaint
				if b.Hovered() {
					fg = pal.textMuted
				}
				ui.Text(c, label).FontSize(12).TextColor(fg).SingleLine()
			})
			if b.Clicked() {
				s.ExpandAll()
			}
		})
	})
}

// hunkButton is a small button of a change's actions, an icon and a
// label.
func hunkButton(c *ui.Context, key string, svg *ui.SVG, label, tip string, pal *palette) bool {
	b := ui.ButtonBase(c.Key(key)).Height(24).Padding(0, 8).Gap(5).Radius(6).AlignItems(ui.Center).
		TextColor(pal.textMuted).Label(label).Tooltip(tip)
	if b.Hovered() || b.Pressed() {
		b.Background(pal.rowHover).TextColor(pal.text)
	}
	b.Children(func() {
		ui.Icon(c, svg).Size(13, 13)
		ui.Text(c, label).FontSize(12).FontWeight(500).SingleLine()
	})
	return b.Clicked()
}

// writeBack writes a file's diff's new text, which a change reverted
// changed, to the file, through kerod, which writes it only as the file
// was shown: one changed meanwhile is shown anew instead.
func (a *App) writeBack(sf *sideFile) {
	cl := a.hostOf(sf.pane).cl
	if cl == nil {
		return
	}
	text := sf.d.New.String()
	sf.writing = true
	go func() {
		var hash string
		err := cl.Call("git.revert", proto.GitWriteParams{Pane: sf.pane, Base: sf.base, Path: sf.f.Path, Hash: sf.hash, Text: text}, &hash)
		a.update(func() {
			sf.writing = false
			if err != nil {
				a.toast(locales.ChangesRevertFailed(err.Error()))
				a.fetchFile(sf, "")
				return
			}
			sf.hash = hash
		})
	}()
}
