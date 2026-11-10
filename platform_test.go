package main

import (
	"fmt"
	"image"
	"runtime"
	"testing"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// Kero draws the window controls where the desktop's title bars have
// buttons, none under a tiling window manager, and the environment
// variable has the last word.
func TestControlsWanted(t *testing.T) {
	desktop := mygo.WindowButtons{End: []string{"minimize", "maximize", "close"}}
	gnome := mygo.WindowButtons{End: []string{"close"}}
	tiling := mygo.WindowButtons{}
	for _, tc := range []struct {
		env     string
		buttons mygo.WindowButtons
		want    bool
	}{
		{"", desktop, true},
		{"", gnome, true},
		{"", tiling, false},
		{"1", tiling, true},
		{"show", tiling, true},
		{"0", desktop, false},
		{"off", desktop, false},
		{"what", tiling, false},
	} {
		getenv := func(k string) string {
			if k == "KERO_WINDOW_CONTROLS" {
				return tc.env
			}
			return ""
		}
		if got := controlsWanted(getenv, tc.buttons); got != tc.want {
			t.Errorf("controlsWanted(KERO_WINDOW_CONTROLS=%q, %+v) = %v, want %v", tc.env, tc.buttons, got, tc.want)
		}
	}
}

func TestWindowCorners(t *testing.T) {
	wasRounded := roundWindows
	roundWindows = runtime.GOOS == "linux"
	t.Cleanup(func() { roundWindows = wasRounded })
	for _, settings := range []bool{false, true} {
		for _, theme := range []string{"plain", "dusk"} {
			for _, dark := range []bool{false, true} {
				t.Run(fmt.Sprintf("settings=%t/theme=%s/dark=%t", settings, theme, dark), func(t *testing.T) {
					a := testApp(t)
					a.set.LightTheme, a.set.DarkTheme = theme, theme
					view := a.view
					if settings {
						a.ss.draft = map[string]string{}
						view = a.settingsView
					}
					tt := ui.NewTester(view, 820, 620)
					tt.SetDark(dark)
					for range 2 {
						tt.Frame()
						img := tt.Image()
						bounds := img.Bounds()
						want := uint8(255)
						if runtime.GOOS == "linux" {
							want = 0
						}
						for _, p := range []image.Point{{0, 0}, {bounds.Max.X - 1, 0}, {0, bounds.Max.Y - 1}, {bounds.Max.X - 1, bounds.Max.Y - 1}} {
							if got := img.RGBAAt(p.X, p.Y).A; got != want {
								t.Errorf("corner %v alpha = %d, want %d", p, got, want)
							}
						}
						if got := img.RGBAAt(24, 24).A; got != 255 {
							t.Errorf("window background alpha = %d, want 255", got)
						}
					}
				})
			}
		}
	}
}
