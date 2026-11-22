package main

import (
	"runtime"
	"testing"
)

// The configuration does not open when the text editor cannot be
// started, and the window says so.
func TestOpenConfigSaysItCouldNotStart(t *testing.T) {
	if runtime.GOOS == "darwin" || runtime.GOOS == "windows" {
		// The editor's path is absolute there (or found through
		// Windows' own directories), not through PATH.
		t.Skip("the editor is not found through PATH")
	}
	t.Setenv("PATH", t.TempDir())
	a := testApp(t)
	a.openConfig()
	if a.pendingToast == "" {
		t.Error("the configuration did not open, and nothing said so")
	}
}
