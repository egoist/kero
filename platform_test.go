package main

import "testing"

// Under a tiling window manager, which gives windows no controls of their
// own, Kero draws none either; elsewhere it does, and the environment
// variable has the last word.
func TestControlsWanted(t *testing.T) {
	for _, tc := range []struct {
		goos string
		env  map[string]string
		want bool
	}{
		{"linux", nil, true},
		{"linux", map[string]string{"XDG_CURRENT_DESKTOP": "GNOME"}, true},
		{"linux", map[string]string{"XDG_CURRENT_DESKTOP": "KDE"}, true},
		{"linux", map[string]string{"XDG_CURRENT_DESKTOP": "Hyprland"}, false},
		{"linux", map[string]string{"HYPRLAND_INSTANCE_SIGNATURE": "abc"}, false},
		{"linux", map[string]string{"SWAYSOCK": "/run/user/1000/sway.sock"}, false},
		{"linux", map[string]string{"XDG_CURRENT_DESKTOP": "sway:wlroots"}, false},
		{"linux", map[string]string{"I3SOCK": "/tmp/i3"}, false},
		{"linux", map[string]string{"NIRI_SOCKET": "/run/niri"}, false},
		{"linux", map[string]string{"DESKTOP_SESSION": "bspwm"}, false},
		// Not a name a tiling one's contains: whole names only.
		{"linux", map[string]string{"XDG_CURRENT_DESKTOP": "X-Cinnamon"}, true},
		{"linux", map[string]string{"XDG_CURRENT_DESKTOP": "Hyprland", "KERO_WINDOW_CONTROLS": "1"}, true},
		{"linux", map[string]string{"XDG_CURRENT_DESKTOP": "GNOME", "KERO_WINDOW_CONTROLS": "off"}, false},
		{"windows", map[string]string{"XDG_CURRENT_DESKTOP": "Hyprland"}, true},
		{"windows", map[string]string{"KERO_WINDOW_CONTROLS": "0"}, false},
	} {
		if got := controlsWanted(tc.goos, func(k string) string { return tc.env[k] }); got != tc.want {
			t.Errorf("controlsWanted(%s, %v) = %v, want %v", tc.goos, tc.env, got, tc.want)
		}
	}
}
