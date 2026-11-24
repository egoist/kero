package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// The configuration does not open when the text editor cannot be
// started, and the Settings window says so — its own toast, not the
// main window's, which is not shown in it.
func TestOpenConfigSaysItCouldNotStart(t *testing.T) {
	if runtime.GOOS == "darwin" || runtime.GOOS == "windows" {
		// The editor's path is absolute there (or found through
		// Windows' own directories), not through PATH.
		t.Skip("the editor is not found through PATH")
	}
	t.Setenv("PATH", t.TempDir())
	a := testApp(t)
	a.openConfig()
	if a.ss.toast == "" {
		t.Error("the configuration did not open, and the Settings window said nothing")
	}
	if a.pendingToast != "" {
		t.Error("the toast went to the main window, where the Settings window does not show it")
	}
}

// The configuration that cannot be written is not opened either: the
// editor would open a file of its own making, and the Settings window
// says what happened instead.
func TestOpenConfigSaysItCouldNotBeWritten(t *testing.T) {
	a := testApp(t)
	// A file where the configuration's folder should be: there is no
	// folder to write the configuration in.
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_CONFIG", filepath.Join(blocker, "config"))
	a.openConfig()
	if a.ss.toast == "" {
		t.Error("the configuration could not be written, and the Settings window said nothing")
	}
}
