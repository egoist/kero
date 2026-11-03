package main

import (
	"github.com/egoist/mygo"

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

// awakeTrayItem is the tray menu's submenu of Keep computer awake, whose
// items pick the mode.
func (a *App) awakeTrayItem() *mygo.MenuItem {
	var modes []*mygo.MenuItem
	for _, mode := range settings.KeepAwakeModes {
		modes = append(modes, &mygo.MenuItem{
			Label:   awakeModeName(mode),
			Type:    mygo.MenuItemRadio,
			Checked: a.set.KeepAwake == mode,
			Click: func(*mygo.MenuItem, *mygo.Window) {
				a.update(func() {
					s := a.set
					s.KeepAwake = mode
					a.applySettings(s)
				})
			},
		})
	}
	return &mygo.MenuItem{Label: locales.AwakeTitle(), Submenu: modes}
}
