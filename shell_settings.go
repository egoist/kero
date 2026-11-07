package main

import (
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/internal/shell"
	"kero/locales"
)

func (a *App) shellProgramSetting(c *ui.Context, pal *palette, login string) {
	settingRow(c, pal, locales.SetShell(), locales.SetShellDetail(proto.ShortDir(login)), func() {
		entries := a.shellInventory()
		labels := []string{locales.ShellSystemDefault()}
		for _, e := range entries {
			label := e.Name
			if slices.Contains(labels, label) {
				label += " · " + e.Path
			}
			labels = append(labels, label)
		}
		value := labels[0]
		if a.set.Shell != "" {
			value = labels[1]
		}
		a.searchPopup(c, "shell", value, labels, 180, locales.ShellUseProgram, pal, func(choice string) {
			switch i := slices.Index(labels, choice); {
			case i == 0:
				a.set.Shell = ""
			case i > 0:
				a.set.Shell = entries[i-1].Path
			default:
				a.set.Shell = strings.TrimSpace(choice)
			}
		})
		if a.set.Shell != "" {
			iconButton(c, "shell-reset", revertIcon, locales.ShellResetProgram(), pal, func() { a.set.Shell = "" })
		}
	})
}

func (a *App) shellArgsSetting(c *ui.Context, pal *palette) {
	settingRow(c, pal, locales.SetShellArgs(), locales.SetShellArgsDetail(), func() {
		if !a.ss.argsEditing && a.ss.argsError == "" {
			a.ss.argsDraft = a.set.ShellArgs
		}
		keep := func() {
			if _, err := shell.ParseArgs(a.ss.argsDraft); err != nil {
				a.ss.argsError = locales.SetShellArgsInvalid(err.Error())
				return
			}
			a.ss.argsError, a.set.ShellArgs = "", a.ss.argsDraft
		}
		in := textField(c, "shell-args", &a.ss.argsDraft, locales.CommonNone(), 220, pal).Label(locales.SetShellArgs())
		a.ss.argsEditing = in.Focused()
		in.OnChange(keep)
		in.OnSubmit(keep)
		if !a.ss.argsEditing {
			keep()
		}
	})
	if a.ss.argsError != "" {
		ui.Text(c, a.ss.argsError).FontSize(12).TextColor(pal.danger).Padding(0, 0, 8, 0)
	}
}

func (a *App) shellDirectorySetting(c *ui.Context, pal *palette) {
	settingRow(c, pal, locales.SetShellDirectory(), locales.SetShellDirectoryDetail(), func() {
		mode := "inherit"
		if a.set.ShellDir == "~" {
			mode = "home"
		} else if a.set.ShellDir != "" || a.ss.dirCustom {
			mode = "custom"
		}
		labels := map[string]string{"inherit": locales.ShellDirectoryInherit(), "home": locales.ShellDirectoryHome(), "custom": locales.ShellDirectoryCustom()}
		ui.Column(c).Gap(6).AlignItems(ui.End).Children(func() {
			popup(c, "shell-dir-mode", &mode, []string{"inherit", "home", "custom"}, func(s string) string { return labels[s] }, 220, pal).
				Label(locales.SetShellDirectory()).OnChange(func() {
				a.ss.dirCustom = mode == "custom"
				switch mode {
				case "inherit":
					a.set.ShellDir = ""
				case "home":
					a.set.ShellDir = "~"
				case "custom":
					if a.set.ShellDir == "~" {
						a.set.ShellDir = ""
					}
				}
			})
			if mode == "custom" {
				textField(c, "shell-dir", &a.set.ShellDir, locales.ShellDirectoryPath(), 220, pal)
			}
		})
	})
}
