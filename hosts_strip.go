package main

import (
	"hash/fnv"
	"runtime"
	"strconv"
	"strings"

	"github.com/egoist/mygo/ui"

	"kero/internal/actions"
	"kero/internal/proto"
	"kero/internal/settings"

	"kero/locales"
)

// The sidebar shows every host's sessions, as one list, or one host's,
// as the host strip at its foot picks: a space of Arc's, but for the
// sessions that need the user, which the strip counts on each host's
// button, so that none goes unseen.

var allIcon = glyph("f7-rectangle-stack")

// spaceLocal is the space of this machine, whose host has no name; no
// host can be named so (remote.ValidName).
const spaceLocal = "local"

// space is a host's key in prefs.Space and prefs.LastSelected.
func space(h *host) string {
	if !h.remote() {
		return spaceLocal
	}
	return h.name
}

// spaceHost is the host the sidebar shows alone, nil while it shows all,
// or the host it showed is gone.
func (a *App) spaceHost() *host {
	if a.prefs.Space == "" || len(a.hosts) < 2 {
		return nil
	}
	for _, h := range a.hosts {
		if space(h) == a.prefs.Space {
			return h
		}
	}
	return nil
}

// shows reports whether the sidebar shows a host's sessions.
func (a *App) shows(h *host) bool {
	sh := a.spaceHost()
	return sh == nil || sh == h
}

// showSpace shows one host's sessions in the sidebar, nil every host's,
// and the session the user looked at last there, as a space of Arc's
// brings its tab back.
func (a *App) showSpace(h *host) {
	if cur := a.session(a.selected); cur != nil {
		a.prefs.LastSelected[space(a.hostOf(cur.ID))] = cur.ID
	}
	a.prefs.Space = ""
	if h != nil {
		a.prefs.Space = space(h)
		if cur := a.session(a.selected); cur == nil || a.hostOf(cur.ID) != h {
			id := a.prefs.LastSelected[space(h)]
			if a.session(id) == nil || a.hostOf(id) != h {
				id = ""
				if ids := a.visibleOrder(); len(ids) > 0 {
					id = ids[0]
				}
			}
			if id != "" {
				a.selectSession(id)
			}
		}
	}
	a.savePrefs()
}

// followSelection shows the host of the session selected, should the
// sidebar show another alone: what the user looks at is in it.
func (a *App) followSelection() {
	if sh := a.spaceHost(); sh != nil && a.selected != "" {
		if h := a.hostOf(a.selected); h != sh && a.session(a.selected) != nil {
			a.prefs.Space = space(h)
		}
	}
}

// spaceKeys is the shortcut of the strip's nth button, 0 for All: Control
// and the digit on macOS, Alt and the digit elsewhere, where Control and
// the digit go to the nth session, as Command does on macOS.
func spaceKeys(n int) string {
	if runtime.GOOS == "darwin" {
		return "Ctrl+" + strconv.Itoa(n)
	}
	return "Alt+" + strconv.Itoa(n)
}

func spaceMods() ui.Modifiers {
	if runtime.GOOS == "darwin" {
		return ui.Ctrl
	}
	return ui.Alt
}

// spaceShortcuts are the strip's keys: 0 for All, then 1–9 for the hosts
// in order, this machine first.
func (a *App) spaceShortcuts(c *ui.Context) {
	if len(a.hosts) < 2 {
		return
	}
	digits := []ui.Key{ui.Key0, ui.Key1, ui.Key2, ui.Key3, ui.Key4, ui.Key5, ui.Key6, ui.Key7, ui.Key8, ui.Key9}
	for i, k := range digits {
		if !c.Shortcut(spaceMods(), k) {
			continue
		}
		switch {
		case i == 0:
			a.showSpace(nil)
		case i <= len(a.hosts):
			a.showSpace(a.hosts[i-1])
		}
	}
}

// waitingOn counts a host's sessions that need the user.
func (a *App) waitingOn(h *host) int {
	n := 0
	for i := range a.st.Sessions {
		if s := &a.st.Sessions[i]; s.Status == proto.Waiting && a.hostOf(s.ID) == h {
			n++
		}
	}
	return n
}

// hostStrip is the row of the sidebar's spaces: All, then each host.
func (a *App) hostStrip(c *ui.Context, pal *palette) {
	if len(a.hosts) < 2 {
		return
	}
	sh := a.spaceHost()
	ui.Row(c.Key("host-strip")).Shrink(0).Padding(6, 12, 2, 12).Gap(4).AlignItems(ui.Center).Children(func() {
		b := a.spaceButton(c, pal, "space-all", sh == nil, a.spaceTip(nil, 0))
		b.Children(func() { ui.Icon(c, allIcon).Size(14, 14).TextColor(pal.textMuted) })
		if b.Clicked() {
			a.showSpace(nil)
		}
		for i, h := range a.hosts {
			waiting := a.waitingOn(h)
			b := a.spaceButton(c, pal, "space-"+space(h), sh == h, a.spaceTip(h, i+1))
			// A host the app lost shows faded, as its sessions do.
			if h.remote() && h.conn != connReady {
				b.Opacity(0.5)
			}
			col := pal.hostColor(h)
			b.Children(func() {
				if !h.remote() {
					ui.Icon(c, hostIcon).Size(14, 14).TextColor(pal.textMuted)
				} else {
					ui.Text(c, initial(h.name)).FontSize(12.5).FontWeight(700).TextColor(col).SingleLine()
				}
				if waiting > 0 {
					badge := ui.Row(c.Key("badge")).Absolute().Top(-3).Right(-3).Height(14).MinWidth(14).Padding(0, 4).Radius(7).
						Center().Background(pal.attention)
					badge.Children(func() {
						ui.Textf(c, "%d", min(waiting, 99)).FontSize(10).FontWeight(700).TextColor(ui.Hex("#ffffff")).FontFeatures("tnum")
					})
				}
			})
			if h.remote() {
				b.ContextMenu(func(m *ui.Menu) { a.hostMenu(m, h) })
			}
			if b.Clicked() {
				a.showSpace(h)
			}
		}
	})
}

// spaceTip names the strip's nth button, of h, nil for All: the host, how
// many of its sessions need the user, and the button's keys.
func (a *App) spaceTip(h *host, n int) string {
	keys := " (" + actions.Glyphs(spaceKeys(n)) + ")"
	if h == nil {
		return locales.HostAllMachines() + keys
	}
	if w := a.waitingOn(h); w > 0 {
		return h.label() + " · " + locales.SidebarNeedsYou(w) + keys
	}
	return h.label() + keys
}

// spaceButton is a button of the strip, filled when its space shows.
func (a *App) spaceButton(c *ui.Context, pal *palette, key string, on bool, tip string) ui.Element {
	b := ui.ButtonBase(c.Key(key)).Size(28, 26).Radius(7).Center().Label(tip).Tooltip(tip)
	switch {
	case on:
		b.Background(pal.rowSelected).InsetShadow(0, 0, 0, 1, pal.rowSelBorder)
		if !pal.dark {
			b.Shadow(0, 1, 2, 0, pal.rowShadow)
		}
	case b.Hovered():
		b.Background(pal.rowHover)
	}
	return b
}

// initial is what a host's button shows of its name: its first letter.
func initial(name string) string {
	for _, r := range name {
		return strings.ToUpper(string(r))
	}
	return "?"
}

// hostColors are the colors of settings.HostColors, light and dark.
var hostColors = map[string][2]ui.Color{
	"red":    {ui.Hex("#d9453b"), ui.Hex("#ff7a70")},
	"orange": {ui.Hex("#dc6a1f"), ui.Hex("#ff9d5c")},
	"amber":  {ui.Hex("#b8860b"), ui.Hex("#f2c14e")},
	"green":  {ui.Hex("#3a8f47"), ui.Hex("#6fd27c")},
	"teal":   {ui.Hex("#13897b"), ui.Hex("#4fd1c0")},
	"blue":   {ui.Hex("#3b6cf6"), ui.Hex("#7b9fff")},
	"purple": {ui.Hex("#8257e6"), ui.Hex("#b493ff")},
	"pink":   {ui.Hex("#cf4c7c"), ui.Hex("#f58fb5")},
}

// hostColorName is a host's color: its own, else the one its name picks,
// which stays the same from run to run.
func hostColorName(h *host) string {
	if h.cfg.Color != "" {
		return h.cfg.Color
	}
	f := fnv.New32a()
	f.Write([]byte(strings.ToLower(h.name)))
	return settings.HostColors[f.Sum32()%uint32(len(settings.HostColors))]
}

// hostColor is the color that marks a host's sessions: the text's for
// this machine, which no other's is.
func (pal *palette) hostColor(h *host) ui.Color {
	if !h.remote() {
		return pal.textMuted
	}
	c := hostColors[hostColorName(h)]
	if pal.dark {
		return c[1]
	}
	return c[0]
}

// colorMenu sets a host's color, in its settings.
func (a *App) colorMenu(m *ui.Menu, h *host) {
	m.Submenu(locales.HostColor(), func(m *ui.Menu) {
		if m.Item(locales.HostColorAuto()).Checked(h.cfg.Color == "").Chosen() {
			a.setHostColor(h, "")
		}
		m.Separator()
		for _, name := range settings.HostColors {
			if m.Item(colorLabel(name)).Checked(h.cfg.Color == name).Chosen() {
				a.setHostColor(h, name)
			}
		}
	})
}

func (a *App) setHostColor(h *host, color string) {
	s := a.set.Clone()
	if cfg := s.Host(h.name); cfg != nil {
		cfg.Color = color
		h.cfg.Color = color
	}
	a.set = s
}

func colorLabel(name string) string {
	switch name {
	case "red":
		return locales.ColorRed()
	case "orange":
		return locales.ColorOrange()
	case "amber":
		return locales.ColorAmber()
	case "green":
		return locales.ColorGreen()
	case "teal":
		return locales.ColorTeal()
	case "blue":
		return locales.ColorBlue()
	case "purple":
		return locales.ColorPurple()
	}
	return locales.ColorPink()
}
