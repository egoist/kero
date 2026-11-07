package main

import (
	"strings"

	"github.com/egoist/mygo/ui"

	"kero/internal/shell"
	"kero/locales"
)

const shellQueryPrefix = "shell:"

func shellPaletteQuery(query string) (string, bool) {
	trimmed := strings.TrimSpace(query)
	if len(trimmed) >= len(shellQueryPrefix) && strings.EqualFold(trimmed[:len(shellQueryPrefix)], shellQueryPrefix) {
		return strings.TrimSpace(trimmed[len(shellQueryPrefix):]), true
	}
	return query, false
}

func (a *App) shellInventory() []shell.Entry {
	if a.shellMenu == nil || a.shellKey != a.set.Shell {
		a.shellKey = a.set.Shell
		a.shellMenu = shell.Inventory(a.shells, a.set.Shell)
	}
	return a.shellMenu
}

func (a *App) shellItems() []paletteItem {
	var items []paletteItem
	for i, entry := range a.shellInventory() {
		program, detail := entry.Path, entry.Path
		if i == 0 {
			program = "" // the daemon applies the configured arguments to the default
			detail = locales.ShellDefault() + " · " + detail
		}
		items = append(items, paletteItem{
			title: locales.ShellPaletteItem(entry.Name), detail: detail,
			shell: true,
			words: "shell terminal " + entry.Name + " " + entry.Path,
			run:   func() { a.newSessionWithShell(a.local(), "", program) },
		})
	}
	return items
}

// newSessionButton starts a session, with a menu for other shells and hosts.
func (a *App) newSessionButton(c *ui.Context, key string, pal *palette) {
	iconButton(c, key, plusIcon, a.tip(locales.ActionNewSession(), "session.new"), pal, func() { a.newSession("") })
	b := ui.ButtonBase(c.Key(key+"-shells")).Size(18, 26).Radius(5).Center().TextColor(pal.textMuted).
		Label(locales.ShellMenu()).Tooltip(locales.ShellMenu())
	if b.Hovered() {
		b.Background(pal.rowHover).TextColor(pal.text)
	}
	b.Children(func() { ui.Icon(c, chevronDownIcon).Size(12, 12) })
	b.PopoverMenuButton(func(m *ui.Menu) {
		m.Item(locales.ShellLocal()).Disabled(true)
		current := a.shellInventory()[0]
		if m.Item(current.Name + " · " + locales.ShellDefault()).Disabled(a.local().cl == nil).Chosen() {
			a.newSessionOn(a.local(), "")
		}
		if m.Item(locales.ShellOther()).Chosen() {
			a.defer_(func() {
				a.openPalette()
				a.pal.query = shellQueryPrefix + " "
			})
		}
		if len(a.hosts) > 1 {
			m.Separator()
			for _, h := range a.hosts[1:] {
				if m.Item(h.name).Disabled(h.cl == nil).Chosen() {
					a.newSessionOn(h, "")
				}
			}
		}
	})
}
