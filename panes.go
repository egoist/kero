package main

import (
	"math"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"

	"kero/locales"
)

const paneGap = 8 // between panes, where the divider is

// paneRef returns the handle a pane's terminal binds, which its focus
// follows.
func (a *App) paneRef(id string) *ui.Handle {
	if a.refs == nil {
		a.refs = map[string]*ui.Handle{}
	}
	h := a.refs[id]
	if h == nil {
		h = &ui.Handle{}
		a.refs[id] = h
	}
	return h
}

// focusOf returns the pane of a session the user is in.
func (a *App) focusOf(s *proto.Session) string {
	if id := a.focus[s.ID]; id != "" && s.PaneByID(id) != nil {
		return id
	}
	if p := s.FocusPane(); p != nil {
		return p.ID
	}
	return ""
}

// setFocus moves the user into a pane, and tells kerod, which remembers it.
func (a *App) setFocus(s *proto.Session, pane string) {
	if a.focus == nil {
		a.focus = map[string]string{}
	}
	if a.focus[s.ID] == pane && s.Focus == pane {
		return
	}
	a.focus[s.ID] = pane
	s.Focus = pane
	if s.Zoomed != "" {
		s.Zoomed = pane
	}
	a.ensureTerm(pane)
	a.touch(pane)
	a.call("focus", proto.FocusParams{Session: s.ID, Pane: pane}, nil)
}

// focusTerminal gives the keyboard to the pane the user is in.
func (a *App) focusTerminal() {
	if s := a.session(a.selected); s != nil {
		if id := a.focusOf(s); id != "" {
			a.paneRef(id).Focus()
		}
	}
}

// panes shows a session's panes in their layout: the zoomed one alone.
// right tells that they reach the window's right edge, which the side
// panel takes while it shows.
func (a *App) panes(c *ui.Context, pal *palette, bar ui.TitleBar, shown float32, s *proto.Session, right bool) {
	multi := len(s.Panes) > 1
	if z := s.PaneByID(s.Zoomed); z != nil || s.Layout == nil || !multi {
		p := z
		if p == nil {
			p = s.FocusPane()
		}
		if p != nil {
			a.paneCard(c, pal, bar, shown, s, p, true, true, right, multi)
		}
		return
	}
	a.layoutNode(c, pal, bar, shown, s, s.Layout, "", true, true, right)
}

func (a *App) layoutNode(c *ui.Context, pal *palette, bar ui.TitleBar, shown float32, s *proto.Session, l *proto.Layout, path string, top, left, right bool) {
	if l.Leaf() {
		if p := s.PaneByID(l.Pane); p != nil {
			a.paneCard(c, pal, bar, shown, s, p, top, left, right, true)
		}
		return
	}
	ratio := float32(l.Ratio)
	if ratio <= 0 || ratio >= 1 {
		ratio = 0.5
	}
	// Row and Column each build an element, so make only the one used: a
	// Row made and replaced would stay, an empty sibling under the key.
	key := "split-" + s.ID + path
	var box ui.Element
	if l.Row {
		box = ui.Row(c.Key(key))
	} else {
		box = ui.Column(c.Key(key))
	}
	box.Grow(1).Basis(0).MinWidth(0).MinHeight(0).AlignItems(ui.Stretch).Bind(a.paneRef(key))
	box.Children(func() {
		ui.Column(c.Key("a")).Grow(ratio).Basis(0).MinWidth(0).MinHeight(0).AlignItems(ui.Stretch).Children(func() {
			a.layoutNode(c, pal, bar, shown, s, l.A, path+"a", top, left, right && !l.Row)
		})
		a.divider(c, pal, s, l, key)
		ui.Column(c.Key("b")).Grow(1 - ratio).Basis(0).MinWidth(0).MinHeight(0).AlignItems(ui.Stretch).Children(func() {
			a.layoutNode(c, pal, bar, shown, s, l.B, path+"b", top && l.Row, left && !l.Row, right)
		})
	})
}

// divider is the gap between two panes, which a drag moves.
func (a *App) divider(c *ui.Context, pal *palette, s *proto.Session, l *proto.Layout, key string) {
	d := ui.Box(c.Key("div")).Shrink(0)
	if l.Row {
		d.Width(paneGap).Cursor(ui.CursorResizeColumn)
	} else {
		d.Height(paneGap).Cursor(ui.CursorResizeRow)
	}
	if d.Hovered() || d.Pressed() {
		// A short grip, so the gap shows it moves.
		d.Draw(func(p *ui.Painter, r ui.Rect) {
			if l.Row {
				p.Fill(ui.Rect{X: r.X + r.W/2 - 1.5, Y: r.Y + r.H/2 - 18, W: 3, H: 36}, pal.textFaint.Alpha(0.7), 1.5)
			} else {
				p.Fill(ui.Rect{X: r.X + r.W/2 - 18, Y: r.Y + r.H/2 - 1.5, W: 36, H: 3}, pal.textFaint.Alpha(0.7), 1.5)
			}
		})
	}
	if dx, dy, ok := d.Dragged(); ok {
		// The ratio shares out the room the panes take, the split's less
		// the divider's.
		b := a.paneRef(key).Bounds(c)
		size, delta := b.W-paneGap, dx
		if !l.Row {
			size, delta = b.H-paneGap, dy
		}
		if size > 0 {
			// The ratio goes on past its bounds, unclamped, so the divider
			// comes back as the pointer comes back to it.
			if a.layoutDrag.split != key {
				r := l.Ratio
				if r <= 0 || r >= 1 {
					r = 0.5
				}
				a.layoutDrag.session, a.layoutDrag.split, a.layoutDrag.ratio = s.ID, key, r
			}
			a.layoutDrag.ratio += float64(delta / size)
			l.Ratio = math.Min(math.Max(a.layoutDrag.ratio, 0.12), 0.88)
		}
	} else if a.layoutDrag.split == key && !d.Pressed() {
		// Only the divider dragged saves the layout: another of the same
		// session would save it every frame of the drag.
		a.layoutDrag.session, a.layoutDrag.split = "", ""
		a.call("layout", proto.LayoutParams{Session: s.ID, Layout: s.Layout.Clone()}, nil)
	}
	if d.DoubleClicked() {
		l.Ratio = 0.5
		a.call("layout", proto.LayoutParams{Session: s.ID, Layout: s.Layout.Clone()}, nil)
	}
}

// paneCard is a pane: a card with a header and the terminal. top, left and
// right tell that it touches the window's edges, where the header drags
// the window, keeps clear of the traffic lights on macOS, and holds the
// window controls elsewhere (windowControls).
func (a *App) paneCard(c *ui.Context, pal *palette, bar ui.TitleBar, shown float32, s *proto.Session, p *proto.Pane, top, left, right, multi bool) {
	focused := p.ID == a.focusOf(s)
	bg := pal.card
	if multi && !focused {
		bg = pal.cardDim
	}
	card := ui.Column(c.Key("pane-" + p.ID)).Grow(1).Basis(0).MinWidth(0).MinHeight(0).Radius(14).Clip().Bind(a.paneRef("card-" + p.ID))
	raised(card.Background(card.AnimateColor("bg", bg, ui.Animation{Duration: 140 * time.Millisecond})), pal)
	hovered := card.Hovered()
	if hovered && a.hoverPane != p.ID {
		a.hoverPane = p.ID
		if a.set.FocusFollowsMouse && multi && !focused {
			a.setFocus(s, p.ID)
			a.paneRef(p.ID).Focus()
		}
	} else if !hovered && a.hoverPane == p.ID {
		a.hoverPane = ""
	}
	// The card takes presses: one on its padding, beside the terminal,
	// focuses the pane, rather than going on to what drags the window.
	if card.Pressed() && !focused {
		a.setFocus(s, p.ID)
		a.paneRef(p.ID).Focus()
	}

	// Another pane dragged over this one: where it would go.
	zone := zoneNone
	if multi {
		if d, over := ui.DragOver[paneDrag](card); over && d.session == s.ID && d.pane != p.ID {
			if x, y, in := card.PointerPosition(); in {
				b := a.paneRef("card-" + p.ID).Bounds(c)
				zone = zoneAt(x/max(b.W, 1), y/max(b.H, 1))
			}
		}
		if d, ok := ui.Drop[paneDrag](card); ok && d.session == s.ID && d.pane != p.ID {
			sid, target := s.ID, p.ID
			drop := a.lastZone
			a.defer_(func() { a.movePane(sid, d.pane, target, drop) })
		}
	}
	if zone != zoneNone {
		a.lastZone = zone
	}

	dragging := false
	card.Children(func() {
		dragging = a.paneHeader(c, pal, bar, shown, s, p, top, left, right, multi, focused, hovered)
		a.paneTerminal(c, pal, s, p)
		if multi {
			// The panes the user is not in fade, text and all.
			v := ui.Box(c.Key("veil")).Absolute().Top(0).Left(0).Right(0).Bottom(0).PassThrough().Background(pal.veil)
			v.Opacity(v.Animate("on", b2f(!focused), 160*time.Millisecond))
		}
		if zone != zoneNone {
			a.dropPreview(c, pal, p.ID, zone)
		}
	})

	// The pane dragged sinks back where it was; one just moved springs in
	// at its new place.
	pose := ui.Pose{}
	switch {
	case dragging:
		pose = ui.Pose{Scale: 0.985, Fade: 0.45}
	case a.arrived[p.ID]:
		pose = ui.Pose{Scale: 0.94, Fade: 0.7}
		delete(a.arrived, p.ID)
		c.Invalidate()
	}
	card.AnimatePose(pose, ui.Animation{Spring: ui.SpringOptions{Duration: 420 * time.Millisecond, Bounce: 0.18}})
}

// paneDrag is a pane dragged by its title to another place.
type paneDrag struct{ session, pane string }

// dropZone is where a pane dropped on another goes: beside it, on a side,
// or in its place, which the other takes (swap).
type dropZone int

const (
	zoneNone dropZone = iota
	zoneLeft
	zoneRight
	zoneUp
	zoneDown
	zoneSwap
)

// zoneAt returns the zone under the pointer, at u, v of a pane (0 to 1):
// its middle swaps, else the nearest edge.
func zoneAt(u, v float32) dropZone {
	if u > 0.3 && u < 0.7 && v > 0.3 && v < 0.7 {
		return zoneSwap
	}
	best, zone := u, zoneLeft
	for _, e := range []struct {
		d float32
		z dropZone
	}{{1 - u, zoneRight}, {v, zoneUp}, {1 - v, zoneDown}} {
		if e.d < best {
			best, zone = e.d, e.z
		}
	}
	return zone
}

func (z dropZone) side() string {
	return [...]string{"", "left", "right", "up", "down", ""}[z]
}

// dropPreview shows, over the pane under the pointer, the room the
// dragged pane would take, gliding from zone to zone, with what dropping
// does.
func (a *App) dropPreview(c *ui.Context, pal *palette, target string, zone dropZone) {
	key := target
	a.previewShown = true
	if a.previewKey != key {
		a.previewKey, a.previewSince = key, c.Now()
	}
	// left, top, width, height in percent of the pane
	r := [...][4]float32{
		zoneLeft:  {0, 0, 50, 100},
		zoneRight: {50, 0, 50, 100},
		zoneUp:    {0, 0, 100, 50},
		zoneDown:  {0, 50, 100, 50},
		zoneSwap:  {0, 0, 100, 100},
	}[zone]
	label, glyph := map[dropZone]string{
		zoneLeft: locales.PaneSplitLeft(), zoneRight: locales.ActionSplitRight(), zoneUp: locales.PaneSplitUp(), zoneDown: locales.ActionSplitDown(), zoneSwap: locales.PaneSwap(),
	}[zone], splitRightIcon
	if zone == zoneUp || zone == zoneDown {
		glyph = splitDownIcon
	}
	if zone == zoneSwap {
		glyph = swapIcon
	}
	fadeIn := min(float32(c.Now().Sub(a.previewSince))/float32(140*time.Millisecond), 1)
	if fadeIn < 1 {
		c.AnimationFrame()
	}
	spring := ui.Animation{Spring: ui.SpringOptions{Duration: 300 * time.Millisecond, Bounce: 0.12}}
	o := ui.Column(c.Key("drop")).Absolute().PassThrough().Padding(8).Opacity(fadeIn)
	o.LeftPercent(o.AnimateTo("l", r[0], spring)).TopPercent(o.AnimateTo("t", r[1], spring)).
		WidthPercent(o.AnimateTo("w", r[2], spring)).HeightPercent(o.AnimateTo("h", r[3], spring))
	o.Children(func() {
		room := ui.Column(c).Grow(1).Radius(10).AlignItems(ui.Center).
			Background(pal.accent.Alpha(0.10)).InsetShadow(0, 0, 28, 0, pal.accent.Alpha(0.22))
		room.Children(func() {
			// The label sits high in the room, clear of the title the
			// pointer carries through its middle.
			ui.Box(c).HeightPercent(22).Shrink(0)
			pill := ui.Row(c).Height(30).Padding(0, 12).Gap(7).Radius(15).AlignItems(ui.Center).
				Background(pal.accent).TextColor(ui.Hex("#ffffff"))
			floating(pill, pal).Children(func() {
				ui.Icon(c, glyph).Size(14, 14)
				ui.Text(c, label).FontSize(12.5).FontWeight(600).SingleLine()
			})
			pill.AnimatePose(ui.Pose{Scale: 0.9 + 0.1*fadeIn}, ui.Snappy)
		})
	})
}

// movePane puts a pane dropped on another beside it, or in its place.
func (a *App) movePane(sid, pane, target string, zone dropZone) {
	s := a.session(sid)
	if s == nil || s.Layout == nil || zone == zoneNone {
		return
	}
	if zone == zoneSwap {
		s.Layout = s.Layout.Swap(pane, target)
		a.arrived[target] = true
	} else {
		s.Layout = s.Layout.Move(pane, target, zone.side())
	}
	a.arrived[pane] = true
	s.Zoomed = ""
	a.setFocus(s, pane)
	a.paneRef(pane).Focus()
	a.call("layout", proto.LayoutParams{Session: sid, Layout: s.Layout.Clone()}, nil)
}

// paneHeader builds a pane's header, and reports whether its title is
// being dragged.
func (a *App) paneHeader(c *ui.Context, pal *palette, bar ui.TitleBar, shown float32, s *proto.Session, p *proto.Pane, top, left, right, multi, focused, hovered bool) (dragging bool) {
	pad := float32(16)
	if left {
		// With the sidebar hidden, the header starts after the traffic
		// lights and the sidebar's buttons, which come here.
		pad = a.chrome.headerPad
	}
	h := ui.Row(c.Key("hdr")).Height(headerH).Shrink(0).AlignItems(ui.Center).Padding(0, 10, 0, pad).Gap(8)
	if h.Pressed() && !focused {
		a.setFocus(s, p.ID)
		a.paneRef(p.ID).Focus()
	}
	h.Children(func() {
		if top && left && shown < 0.5 {
			ui.Row(c).Absolute().Left(a.chrome.buttonsLeft(bar)).Top(0).Bottom(0).AlignItems(ui.Center).Gap(2).Opacity(1 - 2*shown).Children(func() {
				iconButton(c, "show-sidebar", sidebarIcon, a.tip(locales.SidebarShow(), "sidebar.toggle"), pal, a.toggleSidebar)
				iconButton(c, "new-session-2", plusIcon, a.tip(locales.ActionNewSession(), "session.new"), pal, func() { a.newSession("") })
			})
		}
		// The title is the pane's handle: dragged, it takes the pane to
		// another place in the session.
		grip := ui.Row(c.Key("grip")).Gap(8).AlignItems(ui.Center).Shrink(1).MinWidth(0).Height(28).Padding(0, 8).Margin(0, 0, 0, -8).Radius(8)
		if multi {
			grip.Drag(paneDrag{s.ID, p.ID}).Tooltip(locales.PaneDragTip())
			dragging = grip.Dragging()
			switch {
			case dragging:
				// What follows the pointer is a copy of the grip: a chip.
				floating(grip.Background(pal.popover), pal)
			case grip.Hovered():
				grip.Background(pal.rowHover).Cursor(ui.CursorGrab)
			}
		}
		grip.Children(func() {
			if multi {
				if p.Status != proto.Idle || p.Unread {
					statusIconP(c, pal, p.Status, p.Unread, p.Progress, 13)
				} else {
					ui.Icon(c, programIcon(p)).Size(14, 14).TextColor(pal.textFaint)
				}
			}
			title, size := p.PaneName(), float32(13.5)
			if !multi {
				title, size = s.DisplayName(a.set.SessionName), 14
			}
			name := ui.Text(c, title).FontSize(size).FontWeight(600).TextColor(pal.text).SingleLine().Ellipsis("…").Shrink(1).MinWidth(30)
			if multi && !focused && !dragging {
				name.TextColor(pal.textMuted)
			}
			if !multi && name.DoubleClicked() {
				a.startRename(s.ID)
			}
			// The home directory names itself "~", which the title may
			// already say.
			if dir := proto.ShortDir(p.WorkDir()); dir != title {
				ui.Text(c, dir).FontSize(13).TextColor(pal.textFaint).SingleLine().Ellipsis("…").Shrink(2).MinWidth(0)
			}
		})
		if p.Git != nil {
			a.gitChip(c, pal, s, p)
		}
		// The header's empty stretch moves the window, as a title bar
		// does, and zooms it on a double click: the header around it
		// takes clicks, which focus the pane.
		gap := ui.Box(c.Key("drag")).Grow(1).AlignSelf(ui.Stretch)
		if top {
			gap.DragWindow()
		}
		a.paneChips(c, pal, p, !multi)
		show := (hovered || focused && multi) && !dragging
		ctl := ui.Row(c.Key("controls")).Gap(0).AlignItems(ui.Center)
		ctl.Opacity(ctl.Animate("shown", b2f(show), 120*time.Millisecond)).Children(func() {
			if !show {
				return
			}
			iconButton(c, "split-r", splitRightIcon, a.tip(locales.ActionSplitRight(), "pane.split.right"), pal, func() { a.splitPane(s, p.ID, "right") })
			iconButton(c, "split-d", splitDownIcon, a.tip(locales.ActionSplitDown(), "pane.split.down"), pal, func() { a.splitPane(s, p.ID, "down") })
			if multi {
				sid, pid := s.ID, p.ID
				zoom := func() { a.defer_(func() { a.zoomPane(a.session(sid), pid) }) }
				if s.Zoomed == p.ID {
					iconButton(c, "zoom", unzoomIcon, a.tip(locales.PaneShowAll(), "pane.zoom"), pal, zoom)
				} else {
					iconButton(c, "zoom", zoomIcon, a.tip(locales.ActionZoomPane(), "pane.zoom"), pal, zoom)
				}
				iconButton(c, "close", closeIcon, a.tip(locales.PaneClose(), "pane.close"), pal, func() { a.defer_(func() { a.closePane(a.session(sid), pid, true) }) })
			}
		})
		if top && right {
			windowControls(c, pal, a.win)
		}
	})
	return dragging
}

// paneChips says what the pane is doing. With several panes the title
// already leads with the status icon, so the chips go without (icon false).
func (a *App) paneChips(c *ui.Context, pal *palette, p *proto.Pane, icon bool) {
	switch p.Status {
	case proto.Waiting:
		msg := p.Message
		if msg == "" {
			msg = map[string]string{"permission": locales.PaneNeedsPermission(), "question": locales.PaneHasQuestion(), "auth": locales.PaneNeedsSignIn()}[p.Kind]
		}
		if msg == "" {
			msg = locales.StatusNeedsYou()
		}
		chip(c, pal, pal.attnSoft, pal.attention, func() {
			if icon {
				statusIcon(c, pal, p.Status, p.Unread, 11)
			}
			ui.Text(c, msg).FontSize(12).FontWeight(500).SingleLine().Ellipsis("…").MaxWidth(320)
		})
	case proto.Working:
		chip(c, pal, pal.chip, pal.textMuted, func() {
			if icon {
				statusIconP(c, pal, p.Status, false, p.Progress, 11)
			}
			label := ago(p.Since, c.Now())
			if p.Progress >= 0 {
				label = itoa(p.Progress) + "%"
			}
			if p.Message != "" {
				label = p.Message + " · " + label
			}
			ui.Text(c, label).FontSize(12).FontFeatures("tnum").SingleLine().Ellipsis("…").MaxWidth(320)
		})
	case proto.Failed:
		chip(c, pal, pal.danger.Alpha(0.1), pal.danger, func() {
			if icon {
				statusIcon(c, pal, p.Status, true, 11)
			}
			msg := p.Message
			if msg == "" {
				msg = locales.StatusFailed()
			}
			ui.Text(c, msg).FontSize(12).FontWeight(500).SingleLine().Ellipsis("…").MaxWidth(320)
		})
	case proto.Exited:
		chip(c, pal, pal.danger.Alpha(0.1), pal.danger, func() {
			ui.Text(c, locales.PaneExited(itoa(p.ExitCode))).FontSize(12).FontWeight(500).SingleLine()
		})
		if button(c, "restart-"+p.ID, locales.CommonRestart(), "", false, pal) {
			a.restartSession(p.ID)
		}
	case proto.Idle:
		if p.Message != "" {
			chip(c, pal, pal.chip, pal.textMuted, func() {
				if icon {
					statusIcon(c, pal, p.Status, p.Unread, 11)
				}
				ui.Text(c, p.Message).FontSize(12).SingleLine().Ellipsis("…").MaxWidth(320)
			})
		}
	}
	if p.Process != "" && p.Status != proto.Exited {
		chip(c, pal, pal.chip, pal.textMuted, func() {
			ui.Text(c, p.Process).FontSize(12).SingleLine()
		}).Tooltip(locales.PaneForegroundTip())
	}
}

func (a *App) paneTerminal(c *ui.Context, pal *palette, s *proto.Session, p *proto.Pane) {
	e := a.terms[p.ID]
	if e == nil {
		a.ensureTerm(p.ID)
		e = a.terms[p.ID]
	}
	// The terminal fills the card under the header: its own padding
	// takes the colors of the cells beside it, so that a full-screen
	// program's background reaches the card's edges.
	ui.Box(c.Key("body")).Grow(1).MinHeight(0).Children(func() {
		switch {
		case e != nil && e.term != nil:
			ref := a.paneRef(p.ID)
			terminal.View(c.Key("term"), e.term).Fill().Bind(ref)
			if link, isPath, at := e.term.HoveredLink(); isPath {
				a.imagePeek(p.ID, link, at, ref.Bounds(c))
			}
			if ref.Focused(c) && a.focusOf(s) != p.ID {
				a.setFocus(s, p.ID)
			}
			if a.find.pane == p.ID {
				a.findBar(c, pal, p, e.term)
			}
		case e != nil && e.err != "":
			a.message(c, pal, locales.PaneCantShow(), e.err, locales.CommonTryAgain(), func() {
				a.dropTerm(p.ID)
				a.ensureTerm(p.ID)
			})
		default:
			// Attaching takes a moment for a long scrollback: a spinner
			// only once it is a noticeable one.
			if e != nil && time.Since(e.started) > 250*time.Millisecond {
				ui.Column(c).Fill().Center().Children(func() { ui.Spinner(c).Label(locales.PaneAttaching()) })
			} else {
				c.After(260 * time.Millisecond)
			}
		}
	})
}

// --- pane actions ---

func (a *App) splitPane(s *proto.Session, at, direction string) {
	if a.cl == nil || s == nil {
		return
	}
	if at == "" {
		at = a.focusOf(s)
	}
	p := proto.CreateParams{Split: at, Direction: direction}
	if pane := s.PaneByID(at); pane != nil {
		p.Cols, p.Rows = pane.Cols, pane.Rows
		if direction == "down" || direction == "up" {
			p.Rows = max(p.Rows/2, 4)
		} else {
			p.Cols = max(p.Cols/2, 10)
		}
	}
	cl := a.cl
	go func() {
		var ns proto.Session
		err := cl.Call("split", p, &ns)
		a.update(func() {
			if err != nil {
				a.toast(err.Error())
				return
			}
			a.replaceSession(ns)
			if cur := a.session(ns.ID); cur != nil {
				if a.focus == nil {
					a.focus = map[string]string{}
				}
				a.focus[ns.ID] = ns.Focus
				a.ensureTerm(ns.Focus)
				a.touch(ns.Focus)
				a.paneRef(ns.Focus).Focus()
			}
		})
	}()
}

// replaceSession puts a session as kerod answered into the state, before
// the state that has it comes.
func (a *App) replaceSession(ns proto.Session) {
	for i := range a.st.Sessions {
		if a.st.Sessions[i].ID == ns.ID {
			a.st.Sessions[i] = ns
			return
		}
	}
	a.addPending(ns)
}

func (a *App) closePane(s *proto.Session, pane string, ask bool) {
	if s == nil {
		return
	}
	if len(s.Panes) <= 1 {
		a.closeSession(s.ID, ask)
		return
	}
	p := s.PaneByID(pane)
	if p == nil {
		return
	}
	if ask && a.set.ConfirmClose && p.Status != proto.Exited && p.Process != "" {
		sid := s.ID
		a.confirm = &confirmation{
			open:    true,
			title:   locales.ConfirmClosePaneTitle(),
			detail:  locales.ConfirmClosePaneDetail(p.Process),
			action:  locales.PaneClose(),
			destroy: true,
			run: func() {
				if s := a.session(sid); s != nil {
					a.closePane(s, pane, false)
				}
			},
		}
		return
	}
	// The neighbor taking the room takes the focus, as kerod does.
	if a.focusOf(s) == pane && s.Layout != nil {
		for _, dir := range []string{"left", "up", "right", "down"} {
			if n := s.Layout.Neighbor(pane, dir); n != "" {
				a.focus[s.ID] = n
				break
			}
		}
	}
	s.Layout = s.Layout.Remove(pane)
	if s.Layout.Leaf() {
		s.Layout = nil
	}
	if s.Zoomed == pane {
		s.Zoomed = ""
	}
	for i := range s.Panes {
		if s.Panes[i].ID == pane {
			s.Panes = append(s.Panes[:i], s.Panes[i+1:]...)
			break
		}
	}
	a.dropTerm(pane)
	a.call("pane.close", proto.IDParams{ID: pane}, nil)
	a.focusTerminal()
}

func (a *App) zoomPane(s *proto.Session, pane string) {
	if s == nil || len(s.Panes) < 2 {
		return
	}
	if pane == "" {
		pane = a.focusOf(s)
	}
	if s.Zoomed == pane {
		s.Zoomed = ""
	} else {
		s.Zoomed = pane
		a.setFocus(s, pane)
	}
	a.call("zoom", proto.FocusParams{Session: s.ID, Pane: pane}, nil)
	a.paneRef(pane).Focus()
}

// focusDirection moves into the pane next to the focused one.
func (a *App) focusDirection(dir string) {
	s := a.session(a.selected)
	if s == nil || s.Layout == nil || s.Zoomed != "" {
		return
	}
	if n := s.Layout.Neighbor(a.focusOf(s), dir); n != "" {
		a.setFocus(s, n)
		a.paneRef(n).Focus()
	}
}

// cyclePane moves to the next or previous pane, in the layout's order.
func (a *App) cyclePane(d int) {
	s := a.session(a.selected)
	if s == nil || len(s.Panes) < 2 {
		return
	}
	order := s.Layout.Panes()
	i := 0
	for j, id := range order {
		if id == a.focusOf(s) {
			i = j
		}
	}
	n := order[(i+d+len(order))%len(order)]
	a.setFocus(s, n)
	a.paneRef(n).Focus()
}

func itoa(n int) string {
	if n < 0 {
		return "-" + itoa(-n)
	}
	if n < 10 {
		return string(rune('0' + n))
	}
	return itoa(n/10) + string(rune('0'+n%10))
}

// defer_ runs fn once the view is built: for actions that change the
// panes or sessions being built.
func (a *App) defer_(fn func()) { a.later = append(a.later, fn) }

func chip(c *ui.Context, pal *palette, bg, fg ui.Color, fn func()) ui.Element {
	return ui.Row(c).Height(22).Padding(0, 9).Gap(6).Radius(11).AlignItems(ui.Center).Background(bg).TextColor(fg).Children(fn)
}

// closeFocused closes the pane the user is in, or the session with its
// last pane.
func (a *App) closeFocused() {
	if s := a.session(a.selected); s != nil {
		a.closePane(s, a.focusOf(s), true)
	}
}
