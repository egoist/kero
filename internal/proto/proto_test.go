package proto

import (
	"path/filepath"
	"testing"
)

// A console's default title, its program's path, names nothing: the pane
// goes by its program.
func TestConsoleTitle(t *testing.T) {
	for title, want := range map[string]bool{
		`管理员: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.7.0_x64__8wekyb3d8bbwe\pwsh.exe`: true,
		`Administrator: C:\Windows\system32\cmd.exe - ping  -n 6 127.0.0.1`:                          true,
		`C:\Program Files\PowerShell\7\pwsh.exe`:                                                     true,
		`C:\src\kero`:                                                                                true,
		`Fix the build`:                                                                              false,
		`Deploying: C:\deploy.ps1 running`:                                                           false,
	} {
		if got := looksLikePath(title); got != want {
			t.Errorf("looksLikePath(%q) = %v", title, got)
		}
	}
	p := Pane{Process: "node", Title: `管理员: C:\Program Files\PowerShell\7\pwsh.exe`}
	if got := p.PaneName(); got != "node" {
		t.Errorf("pane named %q", got)
	}
}

func TestWithin(t *testing.T) {
	sep := string(filepath.Separator)
	home := sep + "home" + sep + "me"
	for path, want := range map[string]bool{home: true, home + sep + "src": true, home + "2": false, sep + "home": false} {
		if got := Within(path, home); got != want {
			t.Errorf("Within(%q, %q) = %v", path, home, got)
		}
	}
}

// A Windows host's directory names its pane by its last element on any
// system the app runs on.
func TestDirName(t *testing.T) {
	for dir, want := range map[string]string{
		`C:\Users\egoist\dev\mygo`: "mygo",
		`C:\src\kero\`:             "kero",
		`C:\`:                      `C:\`,
		"/home/me/src":             "src",
		"/":                        "/",
	} {
		if got := DirName(dir); got != want {
			t.Errorf("DirName(%q) = %q", dir, got)
		}
	}
	p := Pane{Dir: `C:\Users\egoist\dev\mygo`}
	if got := p.PaneName(); got != "mygo" {
		t.Errorf("pane named %q", got)
	}
}
