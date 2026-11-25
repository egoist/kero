package client

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestStartDaemonReportsServiceCheckFailure(t *testing.T) {
	base := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(base, []byte("file"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_CONFIG_HOME", base)
	if err := StartDaemon(); !errors.Is(err, syscall.ENOTDIR) {
		t.Fatalf("starting with an inaccessible service path: %v", err)
	}
}
