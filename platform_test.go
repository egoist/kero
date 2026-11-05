package main

import (
	"testing"

	"github.com/egoist/mygo"
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
