package main

import (
	_ "embed"
	"log"
	"runtime"

	"github.com/egoist/mygo"

	"kero/internal/settings"

	"kero/locales"
)

// Kero's icon in the menu bar on macOS, as Settings › General chooses
// (settings.AppIcons), and always in the notification area on Windows and
// Linux. While it shows, closing the window hides it there, and Kero keeps
// running until the user quits.

// trayTemplate is the frog of the app's icon, black on transparent for
// macOS to tint: 23×18 points, at 2×.
//
//go:embed icons/tray-template.png
var trayTemplate []byte

// trayColor is the app's icon, for the notification area.
//
//go:embed icons/tray.png
var trayColor []byte

// showsTray tells whether the app's icon shows in the menu bar or the
// notification area.
func showsTray(s settings.Settings) bool {
	return runtime.GOOS != "darwin" || s.AppIcon != "dock"
}

// activationPolicy is macOS's for a setting: no Dock icon for the menu bar
// alone.
func activationPolicy(s settings.Settings) mygo.ActivationPolicy {
	if s.AppIcon == "menubar" {
		return mygo.ActivationPolicyAccessory
	}
	return mygo.ActivationPolicyRegular
}

// changeAppIcon shows the app's icon where the settings now say, as the
// user chose another place for it.
func (a *App) changeAppIcon() {
	if runtime.GOOS == "darwin" {
		mygo.App.SetActivationPolicy(activationPolicy(a.set))
		// Without a Dock icon, macOS may leave the app inactive behind
		// another's windows: the Settings window the user chose in stays
		// in front.
		mygo.App.Focus()
	}
	a.applyTray()
}

// applyTray adds or removes the icon in the menu bar or notification area,
// as the settings say, in the running app.
func (a *App) applyTray() {
	switch show := showsTray(a.set); {
	case show && a.tray == nil:
		icon, template := trayColor, false
		if runtime.GOOS == "darwin" {
			icon, template = trayTemplate, true
		}
		t, err := mygo.NewTray(mygo.TrayOptions{ID: "kero", Icon: icon, IconIsTemplate: template, ToolTip: mygo.App.Name(), Menu: a.trayMenu()})
		if err != nil {
			log.Println("kero: tray:", err)
			return
		}
		// Windows' left click, where the right one opens the menu.
		t.OnClick(a.showWindow)
		a.tray = t
	case !show && a.tray != nil:
		a.tray.Destroy()
		a.tray = nil
	}
}

// trayMenu is the icon's menu: the window, Settings, and quitting.
func (a *App) trayMenu() *mygo.Menu {
	return mygo.NewMenu([]*mygo.MenuItem{
		{Label: locales.TrayOpen(mygo.App.Name()), Click: func(*mygo.MenuItem, *mygo.Window) { a.showWindow() }},
		{Label: actionTitle("settings.open"), Click: func(*mygo.MenuItem, *mygo.Window) {
			mygo.App.Focus()
			a.update(func() { a.openSettings("") })
		}},
		mygo.Separator(),
		{Label: locales.MenuQuitApp(mygo.App.Name()), Click: func(*mygo.MenuItem, *mygo.Window) { mygo.App.Quit() }},
	})
}

// showWindow brings the main window back, as from the menu bar where
// closing it hid it.
func (a *App) showWindow() {
	if a.win == nil {
		return
	}
	if a.win.IsMinimized() {
		a.win.Restore()
	}
	a.win.Show()
	a.win.Focus()
	mygo.App.Focus()
}

// hidesOnClose tells whether closing the main window hides it, rather than
// quitting: while the app's icon shows in the menu bar or the notification
// area, which brings it back. A Linux desktop without a tray has no icon.
func (a *App) hidesOnClose() bool { return !a.quitting && a.tray != nil }
