package main

import (
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"

	"kero/locales"
)

// The Ports tab lists the TCP ports listening on the machine the selected
// session runs on, as its kerod tells (ports.list), while the tab shows: its
// panes' first, what the system and apps listen on folded away. A click on
// one opens it in a browser pane. A browser pane's page lives in the app, on
// this machine: a port of another host is forwarded here first, by this
// machine's kerod, which holds the forwards, so that they end as the app
// goes unless the CLI asked for them.

// portsEvery is how often the list is fetched while the tab shows.
const portsEvery = 3 * time.Second

// portsState is the Ports tab's.
type portsState struct {
	// lists are the lists fetched, by host, so that the session the user
	// comes to shows its host's at once.
	lists map[string]*portsList
	// forwards are this machine's kerod's, as its state last told, or as a
	// forward just asked for answered.
	forwards []proto.PortForward
	// starting are the forwards asked for, by forwardKey.
	starting map[string]bool
	// origins are the ports of hosts that forwards were on, by host and
	// port here: a page left on a forward that ended goes back to its own.
	origins map[string]int
	// system shows the ports of the system and of apps.
	system bool
	places map[string]*ui.ListState
}

// portsList is a host's ports, as its kerod last told.
type portsList struct {
	ports   []proto.Port
	err     string
	old     bool // kerod there knows no ports.list
	busy    bool
	fetched time.Time
}

// portItem is a row of the tab: a section's title, the system's title,
// which folds, or a port.
type portItem struct {
	head   string
	folder bool
	port   proto.Port
}

func forwardKey(h *host, port int) string { return h.addr.String() + "|" + strconv.Itoa(port) }

// setForwards takes this machine's kerod's forwards, as its state tells.
func (a *App) setForwards(list []proto.PortForward) {
	a.side.ports.forwards = list
	for _, f := range list {
		a.noteOrigin(f)
	}
}

// noteOrigin remembers which port of its host a forward brings here.
func (a *App) noteOrigin(f proto.PortForward) {
	ps := &a.side.ports
	if ps.origins == nil {
		ps.origins = map[string]int{}
	}
	ps.origins[f.Addr+"|"+strconv.Itoa(f.Local)] = f.Port
}

// forwardOf is the forward of a host's port, nil for none.
func (a *App) forwardOf(h *host, port int) *proto.PortForward {
	addr := h.addr.String()
	for i, f := range a.side.ports.forwards {
		if f.Addr == addr && f.Port == port {
			return &a.side.ports.forwards[i]
		}
	}
	return nil
}

// forwardAt is the forward of a host that comes to a port of this machine,
// nil for none.
func (a *App) forwardAt(h *host, local int) *proto.PortForward {
	addr := h.addr.String()
	for i, f := range a.side.ports.forwards {
		if f.Addr == addr && f.Local == local {
			return &a.side.ports.forwards[i]
		}
	}
	return nil
}

// portsSide is the Ports tab: the ports of the host of the session shown.
func (a *App) portsSide(c *ui.Context, pal *palette, s *proto.Session) {
	ps := &a.side.ports
	h := a.hostOf(s.ID)
	l := a.portsOf(c, h)
	a.portsHeader(c, pal, h)
	switch {
	case h.cl == nil && h.conn == connConnecting:
		ui.Column(c).Grow(1).Center().Children(func() { ui.Spinner(c) })
		return
	case h.cl == nil:
		a.sideMessage(c, pal, locales.PortsNotConnected(h.label()), h.err)
		return
	case l.old:
		a.portsOutdated(c, pal, h)
		return
	case l.err != "" && l.ports == nil && !l.busy:
		a.sideMessage(c, pal, locales.PortsCantList(), l.err)
		return
	case l.ports == nil:
		ui.Column(c).Grow(1).Center().Children(func() { ui.Spinner(c) })
		return
	}
	items := a.portItems(h, s, l.ports)
	if len(items) == 0 {
		a.sideMessage(c, pal, locales.PortsNone(), locales.PortsNoneDetail())
		return
	}
	if ps.places == nil {
		ps.places = map[string]*ui.ListState{}
	}
	ls := ps.places[h.name]
	if ls == nil {
		ls = &ui.ListState{}
		ps.places[h.name] = ls
	}
	ls.Key = func(i int) any {
		if it := items[i]; it.head != "" {
			return "head|" + it.head
		}
		return items[i].port.Port
	}
	sid := s.ID
	ui.List(c.Key("ports"), ls, len(items), func(i int) {
		switch it := items[i]; {
		case it.folder:
			a.portsFolder(c, pal, it.head)
		case it.head != "":
			ui.Text(c, it.head).FontSize(12).FontWeight(500).TextColor(pal.textFaint).SingleLine().Padding(8, 8, 4, 8)
		default:
			a.portRow(c, pal, h, sid, it.port)
		}
	}).Grow(1).MinHeight(0).Padding(0, 10, 16, 10)
}

// portsOf is a host's list, fetched as it gets old, for as long as the tab
// shows, which is the only time this runs.
func (a *App) portsOf(c *ui.Context, h *host) *portsList {
	ps := &a.side.ports
	if ps.lists == nil {
		ps.lists = map[string]*portsList{}
	}
	l := ps.lists[h.name]
	if l == nil {
		l = &portsList{}
		ps.lists[h.name] = l
	}
	if cl := h.cl; cl != nil && !l.busy && time.Since(l.fetched) >= portsEvery {
		l.busy = true
		go func() {
			var res proto.PortList
			err := cl.Call("ports.list", nil, &res)
			a.update(func() {
				l.busy, l.fetched = false, time.Now()
				switch {
				case err == nil:
					l.err, l.old = "", false
					l.ports = res.Ports
					if l.ports == nil {
						l.ports = []proto.Port{}
					}
				case strings.Contains(err.Error(), "unknown method"):
					l.old, l.ports = true, nil
				default:
					l.err = err.Error()
				}
			})
		}()
	}
	c.After(portsEvery)
	return l
}

// portsHeader says whose ports the tab lists.
func (a *App) portsHeader(c *ui.Context, pal *palette, h *host) {
	ui.Row(c.Key("host")).Height(28).Shrink(0).Padding(0, 10, 6, 16).Gap(6).AlignItems(ui.Center).Children(func() {
		if h.remote() {
			a.hostTag(c, pal, h)
		} else {
			ui.Text(c, h.label()).FontSize(12.5).TextColor(pal.textFaint).SingleLine().Ellipsis("…").MinWidth(0)
		}
	})
}

// portsOutdated says that kerod knows no ports, with what the sidebar's
// chips offer: updating a host's Kero, or restarting this machine's kerod
// into the app's.
func (a *App) portsOutdated(c *ui.Context, pal *palette, h *host) {
	ui.Column(c.Key("outdated")).Grow(1).Center().Gap(6).Padding(24).Children(func() {
		title, detail := locales.PortsRestartTitle(), locales.PortsRestartDetail()
		if h.remote() {
			title, detail = locales.PortsUpdateTitle(h.name), a.hostVersionDetail(h)
		}
		ui.Text(c, title).FontSize(14).FontWeight(600).TextColor(pal.text).TextAlign(ui.Center)
		ui.Text(c, detail).FontSize(12.5).TextColor(pal.textMuted).MaxWidth(300).TextAlign(ui.Center).LineHeight(1.4)
		ui.Box(c).Height(6)
		if h.remote() {
			if smallButton(c, "update", locales.CommonUpdate(), true, pal) {
				a.offerHostUpdate(h)
			}
		} else if smallButton(c, "restart", locales.CommonRestart(), true, pal) {
			a.offerRestart()
		}
	})
}

// portItems are the tab's rows: the session's ports, the others', then what
// the system and apps listen on, folded. A forward whose port has no one
// listening has a row too, to stop it by.
func (a *App) portItems(h *host, s *proto.Session, ports []proto.Port) []portItem {
	ports = slices.Clone(ports)
	for _, f := range a.side.ports.forwards {
		if f.Addr == h.addr.String() && !slices.ContainsFunc(ports, func(p proto.Port) bool { return p.Port == f.Port }) {
			ports = append(ports, proto.Port{Port: f.Port})
		}
	}
	proto.SortPorts(ports, s.ID)
	var mine, rest, system []proto.Port
	for _, p := range ports {
		switch {
		case p.System && a.forwardOf(h, p.Port) == nil:
			system = append(system, p)
		case p.Session == s.ID:
			mine = append(mine, p)
		default:
			rest = append(rest, p)
		}
	}
	var items []portItem
	if len(mine) > 0 {
		items = append(items, portItem{head: locales.PortsThisSession()})
		for _, p := range mine {
			items = append(items, portItem{port: p})
		}
	}
	if len(rest) > 0 {
		if len(mine) > 0 {
			items = append(items, portItem{head: locales.PortsOthers()})
		}
		for _, p := range rest {
			items = append(items, portItem{port: p})
		}
	}
	if len(system) > 0 {
		items = append(items, portItem{head: locales.PortsSystem(), folder: true})
		if a.side.ports.system {
			for _, p := range system {
				items = append(items, portItem{port: p})
			}
		}
	}
	return items
}

// portsFolder folds the ports of the system and of apps.
func (a *App) portsFolder(c *ui.Context, pal *palette, label string) {
	ps := &a.side.ports
	row := treeRow(c, pal, 0, false).Margin(6, 0, 0, 0)
	if row.Clicked() {
		ps.system = !ps.system
	}
	row.Children(func() {
		chev := ui.Icon(c, chevronIcon).Size(10, 10).TextColor(pal.textFaint).Shrink(0)
		chev.Rotate(chev.AnimateTo("turn", 90*b2f(ps.system), ui.Snappy))
		ui.Text(c, label).FontSize(12).FontWeight(500).TextColor(pal.textFaint).SingleLine().Ellipsis("…").MinWidth(0)
	})
}

// portRow is a port: its number and what it is forwarded to, what listens,
// and on hover what to do with it. A click opens it in a browser pane.
func (a *App) portRow(c *ui.Context, pal *palette, h *host, sid string, p proto.Port) {
	fw := a.forwardOf(h, p.Port)
	starting := a.side.ports.starting[forwardKey(h, p.Port)]
	// A forward stops, whether anything listens now or not.
	listens := len(p.Addrs) > 0
	reachable := p.Reachable() || !h.remote() && listens
	row := ui.Row(c.Key("row")).Height(42).Padding(0, 4, 0, 8).Gap(4).AlignItems(ui.Center).Radius(7)
	if pal.dark {
		row.Border(1, ui.Transparent)
	}
	hovered := row.Hovered()
	if hovered {
		row.Background(pal.rowHover)
	}
	row.Tooltip(a.portTip(h, p))
	if reachable && !starting && row.Clicked() {
		a.openPort(h, sid, p, a.openPortPane)
	}
	if p.System && fw == nil {
		row.Opacity(0.7)
	}
	row.ContextMenu(func(m *ui.Menu) {
		if m.Item(locales.PortsOpen()).Disabled(!reachable).Chosen() {
			a.openPort(h, sid, p, a.openPortPane)
		}
		if m.Item(locales.PortsOpenDefault()).Disabled(!reachable).Chosen() {
			a.openPort(h, sid, p, openPortExternal)
		}
		if m.Item(locales.PortsCopy()).Disabled(!reachable).Chosen() {
			a.openPort(h, sid, p, a.copyPortURL)
		}
		if fw != nil && m.Item(locales.PortsStop()).Chosen() {
			a.stopForward(h, p.Port)
		}
	})
	row.Children(func() {
		ui.Column(c.Key("text")).Grow(1).MinWidth(0).Gap(1).Children(func() {
			ui.Row(c.Key("top")).Gap(7).AlignItems(ui.Center).MinWidth(0).Children(func() {
				ui.Text(c, itoa(p.Port)).FontSize(13).FontWeight(500).FontFeatures("tnum").TextColor(pal.text).SingleLine().Shrink(0)
				a.portState(c, pal, p, fw, starting, hovered)
			})
			ui.Text(c, a.portDetail(p, sid)).FontSize(12).TextColor(pal.textFaint).SingleLine().Ellipsis("…").MinWidth(0)
		})
		if hovered && reachable {
			iconButton(c, "pane", globeIcon, locales.PortsOpen(), pal, func() { a.openPort(h, sid, p, a.openPortPane) })
			iconButton(c, "default", openFileIcon, locales.PortsOpenDefault(), pal, func() { a.openPort(h, sid, p, openPortExternal) })
			iconButton(c, "copy", copyIcon, locales.PortsCopy(), pal, func() { a.openPort(h, sid, p, a.copyPortURL) })
		}
		// Always there on a forward: what's open on this machine can be
		// closed at a glance.
		if fw != nil {
			iconButton(c, "stop", closeIcon, locales.PortsStop(), pal, func() { a.stopForward(h, p.Port) })
		}
	})
}

// portState shows a port's forward: what it comes to here, in the accent's
// color, or in the color of what needs noticing when that is another port
// than the host's; shorter with the row's buttons beside it.
func (a *App) portState(c *ui.Context, pal *palette, p proto.Port, fw *proto.PortForward, starting, hovered bool) {
	switch {
	case starting:
		ui.Text(c, locales.PortsForwarding()).FontSize(12).TextColor(pal.textMuted).SingleLine().Ellipsis("…").MinWidth(0)
	case fw != nil:
		col := pal.accent
		if fw.Local != p.Port {
			col = pal.attention
		}
		to := "→ localhost:" + itoa(fw.Local)
		if hovered {
			to = "→ :" + itoa(fw.Local)
		}
		ui.Text(c, to).FontSize(12).FontFeatures("tnum").TextColor(col).SingleLine().Ellipsis("…").MinWidth(0)
	}
}

// portDetail says what listens: the process, and the session of another
// session's port.
func (a *App) portDetail(p proto.Port, sid string) string {
	if len(p.Addrs) == 0 {
		return locales.PortsNoListener()
	}
	name := p.Process
	if name == "" {
		name = locales.PortsUnknownProcess()
	}
	if p.Session != "" && p.Session != sid {
		if s := a.session(p.Session); s != nil {
			name += " · " + s.DisplayName(a.set.SessionName)
		}
	}
	return name
}

// portTip tells the rest: where it listens, the process's id, and what a
// forward came to be.
func (a *App) portTip(h *host, p proto.Port) string {
	var lines []string
	if len(p.Addrs) > 0 {
		line := locales.PortsListensOn(strings.Join(p.Addrs, ", "))
		if p.PID != 0 {
			line += " · pid " + itoa(p.PID)
		}
		lines = append(lines, line)
	}
	if h.remote() && len(p.Addrs) > 0 && !p.Reachable() {
		lines = append(lines, locales.PortsUnreachable(h.name))
	}
	if fw := a.forwardOf(h, p.Port); fw != nil && fw.Local != p.Port {
		lines = append(lines, locales.PortsMoved(itoa(p.Port), itoa(fw.Local)))
	}
	return strings.Join(lines, "\n")
}

// openPort finds the URL of a port from here, forwarding it first when it is
// on another machine, as the user just asked, then does what they asked
// with it.
func (a *App) openPort(h *host, sid string, p proto.Port, then func(sid, url string)) {
	if !h.remote() {
		then(sid, localPortURL(p))
		return
	}
	if fw := a.forwardOf(h, p.Port); fw != nil {
		then(sid, fw.URL())
		return
	}
	a.startForward(h, p.Port, 0, func(fw proto.PortForward) { then(sid, fw.URL()) })
}

// localPortURL is a port of this machine's URL: localhost, unless it listens
// only on some other address.
func localPortURL(p proto.Port) string {
	if p.Reachable() || len(p.Addrs) == 0 {
		return proto.PortURL("localhost", p.Port, p.Port)
	}
	return proto.PortURL(p.Addrs[0], p.Port, p.Port)
}

// startForward has this machine's kerod forward a host's port here, on local
// or, when 0, on the same port if it is free, saying so if not.
func (a *App) startForward(h *host, port, local int, then func(proto.PortForward)) {
	ps := &a.side.ports
	cl := a.local().cl
	if cl == nil {
		a.toast(locales.HostNotConnected(a.local().label()))
		return
	}
	key := forwardKey(h, port)
	if ps.starting[key] {
		return
	}
	if ps.starting == nil {
		ps.starting = map[string]bool{}
	}
	ps.starting[key] = true
	params := proto.PortForwardParams{Host: h.name, Addr: h.addr.String(), Port: port, Local: local}
	go func() {
		var res proto.PortForwarded
		err := cl.Call("ports.forward", params, &res)
		a.update(func() {
			delete(ps.starting, key)
			switch {
			case err != nil && strings.Contains(err.Error(), "unknown method"):
				a.toast(locales.PortsRestartTitle() + ": " + locales.PortsRestartDetail())
				return
			case err != nil:
				a.toast(locales.PortsForwardFailed(h.name, itoa(port), err.Error()))
				return
			}
			fw := res.PortForward
			// The app forwards what listens: a port that stopped since it
			// was listed, or a page's that was another, is no use open.
			if res.Refused {
				a.stopForward(h, port)
				a.toast(locales.PortsNothingListens(itoa(port), h.name))
				return
			}
			if !slices.ContainsFunc(ps.forwards, func(f proto.PortForward) bool { return f.Addr == fw.Addr && f.Port == fw.Port }) {
				ps.forwards = append(ps.forwards, fw)
			}
			if fw.Local != port {
				a.toast(locales.PortsMoved(itoa(port), itoa(fw.Local)))
			}
			a.noteOrigin(fw)
			if then != nil {
				then(fw)
			}
		})
	}()
}

// stopForward stops forwarding a host's port.
func (a *App) stopForward(h *host, port int) {
	cl := a.local().cl
	if cl == nil {
		return
	}
	ps := &a.side.ports
	addr := h.addr.String()
	ps.forwards = slices.DeleteFunc(slices.Clone(ps.forwards), func(f proto.PortForward) bool { return f.Addr == addr && f.Port == port })
	cl.Go("ports.stop", proto.PortStopParams{Addr: addr, Port: port}, func(err error) {
		if err != nil {
			a.update(func() { a.toast(err.Error()) })
		}
	})
}

// stopForwards stops forwarding a host's ports, as the app lets go of it.
func (a *App) stopForwards(h *host) {
	for _, f := range slices.Clone(a.side.ports.forwards) {
		if f.Addr == h.addr.String() {
			a.stopForward(h, f.Port)
		}
	}
}

// openPortPane shows a URL in a browser pane of the session: the one
// showing that server, if any, else a new one beside the pane the user is in.
func (a *App) openPortPane(sid, url string) {
	s := a.session(sid)
	if s == nil {
		return
	}
	for i := range s.Panes {
		if p := &s.Panes[i]; p.Browser() && proto.URLHost(p.URL) == proto.URLHost(url) {
			a.setFocus(s, p.ID)
			a.paneRef(p.ID).Focus()
			return
		}
	}
	a.split(s, proto.CreateParams{Split: a.focusOf(s), Direction: "right", URL: url})
}

// openPortExternal opens a URL in the user's default browser.
func openPortExternal(_, url string) { mygo.Shell.OpenExternal(url) }

// copyPortURL copies a URL.
func (a *App) copyPortURL(_, url string) {
	a.copyText = url
	a.toast(locales.PortsCopied(url))
}

// browserPortNote says, over a remote session's browser pane on a page of
// localhost, that it is this machine's: a pane's page lives in the app, not
// on the host. It offers the forward that makes it the host's, and tells
// whether it shows, which the page's own error then gives way to.
func (a *App) browserPortNote(c *ui.Context, pal *palette, p *proto.Pane, e *webEntry) bool {
	h := a.hostOf(p.ID)
	if !h.remote() || e.portNoteClosed == e.url {
		return false
	}
	local, ok := proto.LoopbackPort(e.url)
	if !ok || a.forwardAt(h, local) != nil {
		return false
	}
	port := local
	if o, ok := a.side.ports.origins[forwardKey(h, local)]; ok {
		port = o
	}
	address := proto.URLHost(e.url)
	// Over the page's top, in a pane however narrow: its words wrap.
	bar := ui.Column(c.Key("port-note")).Absolute().Top(8).Left(12).Right(12).Padding(10, 8, 8, 12).Gap(6).Radius(10).Background(pal.popover)
	floating(bar, pal).Children(func() {
		ui.Text(c, locales.PortsPageHere(address, h.name)).FontSize(12.5).TextColor(pal.textMuted).LineHeight(1.35)
		ui.Row(c.Key("buttons")).Gap(4).AlignItems(ui.Center).Children(func() {
			if a.side.ports.starting[forwardKey(h, port)] {
				ui.Spinner(c).Size(14, 14)
			} else if button(c, "forward", locales.PortsForwardFrom(itoa(port), h.name), "", false, pal) {
				a.forwardPage(h, p.ID, e, port)
			}
			ui.Spacer(c)
			iconButton(c, "dismiss", closeIcon, locales.FindClose(), pal, func() { e.portNoteClosed = e.url })
		})
	})
	return true
}

// forwardPage forwards the host's port a page was on, keeping the port here
// the page names if it can, and loads it through the forward.
func (a *App) forwardPage(h *host, id string, e *webEntry, port int) {
	a.startForward(h, port, 0, func(fw proto.PortForward) {
		if a.webs[id] != e {
			return
		}
		if u, err := url.Parse(e.url); err == nil && u.Port() != itoa(fw.Local) {
			u.Host = "localhost:" + itoa(fw.Local)
			e.load(u.String())
			a.tellPage(id, e)
			return
		}
		e.load(e.url)
	})
}
