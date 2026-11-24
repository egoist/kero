package cli

import (
	"path/filepath"
	"strings"
	"testing"
)

// A --focus that could not focus is said: the CLI dropped the select's
// error, so the command said nothing while the app was never told of the
// session it made.
func TestFocusThatFailedIsSaid(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, _ := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)
	failCall(t, "select", "the app is not there")

	var err error
	captureStdout(t, func() { err = run([]string{"new", "--focus"}, "") })
	if err == nil {
		t.Fatal("the focus that failed was not said")
	}
	if !strings.Contains(err.Error(), "the app is not there") {
		t.Errorf("the error is %v", err)
	}
}
