package main

import (
	"os/exec"
	"runtime"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"kero/locales"
)

// fileManager is the system's file manager, as buttons that show a file
// in it name it.
func fileManager() string {
	switch runtime.GOOS {
	case "darwin":
		return locales.FileManagerFinder()
	case "windows":
		return locales.FileManagerExplorer()
	}
	return locales.FileManagerFiles()
}

// openPath opens a file or folder in the app that opens it.
func openPath(path string) { mygo.Shell.OpenPath(path) }

// revealPath shows a file in the file manager.
func revealPath(path string) { mygo.Shell.ShowItemInFolder(path) }

// openTextFile opens a text file, as the configuration, which has no
// extension to tell its app by, in the text editor.
func openTextFile(path string) {
	switch runtime.GOOS {
	case "darwin":
		exec.Command("/usr/bin/open", "-t", path).Start()
	case "windows":
		exec.Command("notepad.exe", path).Start()
	default:
		exec.Command("xdg-open", path).Start()
	}
}

// ownControls tells that Kero draws the window controls itself: on
// Windows and Linux the top-right card's header holds minimize, maximize
// and close, beside Kero's own buttons, where the system's, at the
// window's edge, would straddle the card. macOS keeps its traffic lights.
var ownControls = runtime.GOOS != "darwin"

// framed sets a window's frame: the title bar hidden, under the traffic
// lights on macOS and without its buttons elsewhere (ownControls), which
// keeps the edges that resize the window.
func framed(o mygo.WindowOptions) mygo.WindowOptions {
	// The wash may be translucent, and with blur off the desktop shows
	// through the window itself, not a material.
	o.Transparent = true
	if ownControls {
		o.TitleBarStyle = mygo.TitleBarHidden
		o.HideWindowButtons = true
		// No menu bar over the sidebar and the cards: Alt and F10 show the
		// menus, whose shortcuts work all the same.
		o.AutoHideMenuBar = true
		return o
	}
	o.TitleBarStyle = mygo.TitleBarHiddenInset
	o.TitleBarHeight = topBar
	// The lights' buttons are 16 tall, and MyGo puts them a DIP above the
	// position: centered on barMid, as the sidebar's buttons and the
	// panes' headers are.
	o.TrafficLightPosition = &mygo.Point{X: 18, Y: barMid - 7}
	return o
}

var (
	minimizeIcon = icon(`<path d="M3.5 8h9"/>`)
	maximizeIcon = icon(`<rect x="3.5" y="3.5" width="9" height="9" rx="1.5"/>`)
	restoreIcon  = icon(`<rect x="3.5" y="5.5" width="7" height="7" rx="1.2"/><path d="M5.5 3.5h5.5a1.5 1.5 0 0 1 1.5 1.5v5.5"/>`)
)

// windowControls are a window's minimize, maximize and close buttons, as
// Kero draws them (ownControls), at the right of a header.
func windowControls(c *ui.Context, pal *palette, w *mygo.Window) {
	if !ownControls || w == nil {
		return
	}
	ui.Row(c.Key("window-controls")).Gap(2).AlignItems(ui.Center).Shrink(0).Margin(0, 0, 0, 6).Children(func() {
		iconButton(c, "minimize", minimizeIcon, locales.WindowMinimize(), pal, w.Minimize)
		// The system's maximize button for the pointer, which brings
		// Windows 11's snap layouts as it rests there: no tooltip over them.
		maximized := w.IsMaximized()
		label, svg := locales.WindowMaximize(), maximizeIcon
		if maximized {
			label, svg = locales.WindowRestore(), restoreIcon
		}
		m := ui.ButtonBase(c.Key("maximize")).Size(28, 26).Radius(6).Center().TextColor(pal.textMuted).Label(label).MaximizeButton()
		if m.Pressed() {
			m.Background(pal.rowHover.Alpha(0.12))
		} else if m.Hovered() {
			m.Background(pal.rowHover).TextColor(pal.text)
		}
		m.Children(func() { ui.Icon(c, svg).Size(16, 16) })
		if m.Clicked() {
			if maximized {
				w.Unmaximize()
			} else {
				w.Maximize()
			}
		}
		b := ui.ButtonBase(c.Key("close-window")).Size(28, 26).Radius(6).Center().TextColor(pal.textMuted).Label(locales.CommonClose()).Tooltip(locales.CommonClose())
		if b.Hovered() || b.Pressed() {
			b.Background(pal.danger).TextColor(ui.RGB(255, 255, 255))
		}
		b.Children(func() { ui.Icon(c, closeIcon).Size(16, 16) })
		if b.Clicked() {
			w.Close()
		}
	})
}
