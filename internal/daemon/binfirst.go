package daemon

import (
	"os"
	"path/filepath"
	"runtime"

	"github.com/egoist/mygo"
)

// Kero Dev's panes run its own kero, not the installed Kero's. PATH has
// bin last (environment), and login shells put /usr/local/bin, where the
// installed one is, before it anyway (path_helper, fish's /etc/paths). So
// they put bin first once their startup files have run: fish with -C, zsh
// from a .zshenv of Kero's (ZDOTDIR), and a session's command in its
// script (shellArgs).

// binFirst returns the bin that panes' shells put first on PATH, "" for
// none.
func (d *Daemon) binFirst() string {
	if !mygo.IsDev() || runtime.GOOS == "windows" {
		return ""
	}
	return filepath.Join(d.dir, "bin")
}

// zshEnv is the environment that starts zsh with Kero's .zshenv in dir
// (zshDir), which gives the user's ZDOTDIR back.
func zshEnv(dir string) []string {
	return []string{"ZDOTDIR=" + dir, "KERO_ZDOTDIR=" + os.Getenv("ZDOTDIR")}
}

// fishBinFirst is fish's command that puts bin first.
func fishBinFirst(bin string) string { return "fish_add_path -mP " + shellQuote("fish", bin) }
