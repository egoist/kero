package client

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A service that cannot be asked is treated as none: a kerod of the
// app's own starts, and why the check failed is said in the log.
func TestStartDaemonFallsBackWhenTheServiceCannotBeChecked(t *testing.T) {
	base := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(base, []byte("file"), 0o600); err != nil {
		t.Fatal(err)
	}
	// The unit's path is under XDG_CONFIG_HOME, which cannot be asked;
	// the socket's folder is KERO_HOME, which can.
	t.Setenv("KERO_HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", base)
	// A kerod of the test's own is not started: true takes its place,
	// which takes the arguments and is done.
	Exe = "true"
	t.Cleanup(func() { Exe = "" })
	var logs strings.Builder
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	if err := StartDaemon(); err != nil {
		t.Fatalf("a service that could not be checked stopped the start: %v", err)
	}
	if said := logs.String(); !strings.Contains(said, "checking kerod's service") || !strings.Contains(said, "not a directory") {
		t.Errorf("the check's failure was not said as it was: %q", said)
	}
}
