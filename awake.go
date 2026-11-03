package main

import (
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/internal/settings"
	"kero/locales"
)

// The modes of Keep computer awake (settings.KeepAwakeModes): off, the
// system's own sleep; on, kept awake while Kero runs; agents, kept awake
// while an agent of this machine's works.
const (
	awakeOff    = "off"
	awakeOn     = "on"
	awakeAgents = "agents"
)

// keepAwake holds the computer awake, or lets it sleep, as the mode and
// this machine's sessions ask: a session of another host's working
// keeps that machine busy, not this one.
func (a *App) keepAwake() {
	hold := false
	switch a.set.KeepAwake {
	case awakeOn:
		hold = true
	case awakeAgents:
		for i := range a.st.Sessions {
			s := &a.st.Sessions[i]
			if s.Status == proto.Working && !a.hostOf(s.ID).remote() {
				hold = true
				break
			}
		}
	}
	a.awake.hold(hold)
}

// awakeModeName names a mode of Keep computer awake.
func awakeModeName(mode string) string {
	switch mode {
	case awakeOn:
		return locales.AwakeOn()
	case awakeAgents:
		return locales.AwakeAgents()
	}
	return locales.AwakeOff()
}

// awakeButton is the sidebar foot's button of Keep computer awake: a cup,
// in the accent while the mode is not off, whose menu picks the mode.
func (a *App) awakeButton(c *ui.Context, pal *palette) {
	label := locales.AwakeTitle() + ": " + awakeModeName(a.set.KeepAwake)
	b := ui.ButtonBase(c.Key("keep-awake")).Size(28, 26).Radius(6).Center().TextColor(pal.textMuted).Label(label).Tooltip(label)
	on := a.set.KeepAwake != awakeOff
	switch {
	case b.Pressed():
		b.Background(pal.rowHover.Alpha(0.12))
	case b.Hovered():
		b.Background(pal.rowHover)
		b.TextColor(pal.text)
	}
	if on {
		b.TextColor(pal.accent)
	}
	b.Children(func() { ui.Icon(c, coffeeIcon).Size(16, 16) })
	b.Menu(func(m *ui.Menu) {
		for _, mode := range settings.KeepAwakeModes {
			if m.Item(awakeModeName(mode)).Checked(a.set.KeepAwake == mode).Chosen() {
				s := a.set
				s.KeepAwake = mode
				a.applySettings(s)
			}
		}
	})
}
