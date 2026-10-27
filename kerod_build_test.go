package main

import (
	"io/fs"
	"os/exec"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// TestKerodSource checks that kerodSource and kerodModules hold all the
// code kerod runs, or an update that changes it would leave kerod as it
// was.
func TestKerodSource(t *testing.T) {
	for _, goos := range []string{"darwin", "linux", "windows"} {
		cmd := exec.Command("go", "list", "-deps", "-f", "{{if .Module}}{{.Module.Main}} {{.Module.Path}} {{.ImportPath}}{{end}}", "./internal/daemon")
		cmd.Env = append(cmd.Environ(), "GOOS="+goos)
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			f := strings.Fields(line)
			if f[0] == "true" {
				dir := strings.TrimPrefix(f[2], f[1]+"/")
				if _, err := fs.Stat(kerodSource, dir); err != nil {
					t.Errorf("%s: kerodSource has no %s", goos, dir)
				}
			} else if !slices.Contains(kerodModules, f[1]) {
				t.Errorf("%s: kerodModules has no %s", goos, f[1])
			}
		}
	}
}

func TestBuilds(t *testing.T) {
	other := "windows"
	if runtime.GOOS == "windows" {
		other = "linux"
	}
	for _, c := range []struct {
		path, src string
		want      bool
	}{
		{"internal/daemon/session.go", "package daemon", true},
		{"internal/daemon/session_test.go", "package daemon", false},
		{"internal/daemon/pty_" + other + ".go", "package daemon", false},
		{"internal/daemon/pty_" + runtime.GOOS + ".go", "package daemon", true},
		{"internal/daemon/pty_" + other + "_arm64.go", "package daemon", false},
		{"internal/daemon/peer_other.go", "//go:build !linux && !darwin && !windows\n\npackage daemon", runtime.GOOS != "linux" && runtime.GOOS != "darwin" && runtime.GOOS != "windows"},
		{"internal/daemon/pty_unix.go", "//go:build unix\n\npackage daemon", runtime.GOOS != "windows"},
		{"internal/detect/manifests/node.toml", "", true},
	} {
		if got := builds(c.path, []byte(c.src)); got != c.want {
			t.Errorf("builds(%s) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestKerodBuild(t *testing.T) {
	if a, b := kerodBuild(), kerodBuild(); a == "" || a != b {
		t.Errorf("kerodBuild() = %q then %q", a, b)
	}
}
