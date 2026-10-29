package main

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// kero carries JetBrains Mono, with Nerd Fonts' icons (resources/fonts,
// SIL Open Font License, see OFL.txt there): the terminals' font unless
// the user picks another, and the icons of prompts and of agents' TUIs.

// bundledFont is the family the fonts register as.
const bundledFont = "JetBrainsMono Nerd Font"

// cjkMonoFallbacks are monospaced CJK families tried after the user's
// font for glyphs it lacks.
//
// On Windows, MyGo paints terminals with DirectWrite
// (internal/text/dwrite_windows.go). A one-name family list builds
// IDWriteTextFormat for that face and leaves SetFontFallback unset, so
// missing glyphs use DirectWrite's system fallback: Microsoft YaHei, a
// proportional UI face. Chinese in a TUI then sits next to JetBrains
// Mono with the wrong width and weight. Listing further named families
// both prefers monospaced CJK and makes MyGo attach them before YaHei.
// NSimSun, MS Gothic, MingLiU and GulimChe ship with Windows; the
// others are used when the user has installed them.
const cjkMonoFallbacks = "Sarasa Mono SC, Maple Mono NF CN, Noto Sans Mono CJK SC, Noto Sans Mono CJK, NSimSun, MS Gothic, MingLiU, GulimChe"

// defaultTermFamily is the empty font-family: kero's Nerd Font, then
// cjkMonoFallbacks, then the system's monospaced face.
const defaultTermFamily = bundledFont + ", " + cjkMonoFallbacks + ", monospace"

// fontsLoaded tells that the fonts registered.
var fontsLoaded bool

// loadFonts registers the fonts kero carries: from the app's resources,
// where `mygo build` and `mygo dev` put them, else from the source tree,
// as under `go run`.
func loadFonts() {
	var dirs []string
	if res, err := mygo.App.Path(mygo.PathResources); err == nil {
		dirs = append(dirs, filepath.Join(res, "fonts"))
	}
	dirs = append(dirs, filepath.Join("resources", "fonts"))
	for _, dir := range dirs {
		files, _ := filepath.Glob(filepath.Join(dir, "*.ttf"))
		for _, f := range files {
			data, err := os.ReadFile(f)
			if err != nil {
				continue
			}
			if ui.RegisterFont(data, bundledFont) == nil {
				fontsLoaded = true
			}
		}
		if fontsLoaded {
			return
		}
	}
}

// termFamily returns the family terminals draw with. An empty setting
// is kero's Nerd Font. A single family, including JetBrains Mono from
// the picker, gets cjkMonoFallbacks after it so Windows does not draw
// CJK with YaHei. A comma-separated list, or monospace, is left as the
// user wrote it. Remote panes use this same list; SSH does not pick a
// font of its own.
func (a *App) termFamily() string {
	f := strings.TrimSpace(a.set.FontFamily)
	switch f {
	case "monospace":
		return f
	case "":
		return defaultTermFamily
	}
	if strings.Contains(f, ",") {
		return f
	}
	return f + ", " + cjkMonoFallbacks + ", monospace"
}
