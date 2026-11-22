package main

import (
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
