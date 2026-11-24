package main

import (
	"path/filepath"
	"testing"
)

func TestExpandHomeForOS(t *testing.T) {
	home := filepath.Join("home", "user")
	for _, tt := range []struct {
		name, path, goos, want string
	}{
		{"bare tilde", "~", "linux", home},
		{"unix home path", "~/notes.txt", "linux", filepath.Join(home, "notes.txt")},
		{"windows home path", `~\notes.txt`, "windows", filepath.Join(home, "notes.txt")},
		{"windows name without separator", "~notes.txt", "windows", "~notes.txt"},
		{"non-windows backslash path", `~\notes.txt`, "linux", `~\notes.txt`},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := expandHomeForOS(tt.path, home, tt.goos); got != tt.want {
				t.Errorf("expandHomeForOS(%q, %q, %q) = %q, want %q", tt.path, home, tt.goos, got, tt.want)
			}
		})
	}
}
