package main

import (
	"github.com/egoist/mygo"
	"github.com/egoist/mygo/i18n"

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
func awakeModeName(mode string) string { return awakeModeIn(locales.In(i18n.Locale()), mode) }

// awakeModeIn names a mode of Keep computer awake in the language of msgs.
func awakeModeIn(msgs locales.Messages, mode string) string {
	switch mode {
	case awakeOn:
		return msgs.AwakeOn()
	case awakeAgents:
		return msgs.AwakeAgents()
	}
	return msgs.AwakeOff()
}

// setKeepAwake chooses a mode of Keep computer awake, and saves it.
func (a *App) setKeepAwake(mode string) {
	s := a.set
	s.KeepAwake = mode
	a.applySettings(s)
}

// awakeCommands are the palette's commands of Keep computer awake: one for
// each mode but the one it is in.
func (a *App) awakeCommands() []paletteItem {
	en := locales.In("en")
	var cmds []paletteItem
	for _, mode := range settings.KeepAwakeModes {
		if mode == a.set.KeepAwake {
			continue
		}
		cmds = append(cmds, paletteItem{title: locales.AwakeTitle() + ": " + awakeModeName(mode),
			words: en.AwakeTitle() + " " + awakeModeIn(en, mode) + " keep-computer-awake sleep caffeinate", run: func() { a.setKeepAwake(mode) }})
	}
	return cmds
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
			Click:   func(*mygo.MenuItem, *mygo.Window) { a.update(func() { a.setKeepAwake(mode) }) },
		})
	}
	return &mygo.MenuItem{Label: locales.AwakeTitle(), Submenu: modes}
}
