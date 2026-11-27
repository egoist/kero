package cli

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// A configuration that cannot be read is not one whose defaults are
// effective settings. `config show` has to say the failure rather than
// print the defaults as though the user had chosen them.
func TestConfigShowSaysAnUnreadableConfiguration(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permissions are Unix's")
	}
	if os.Geteuid() == 0 {
		t.Skip("root reads a file with no read permission")
	}
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config")
	if err := os.WriteFile(cfg, []byte("shell = bash\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(cfg, 0); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_CONFIG", cfg)

	var err error
	out := captureStdout(t, func() { err = configCmd([]string{"show"}) })
	if err == nil {
		t.Fatal("config show accepted an unreadable configuration")
	}
	if !strings.Contains(err.Error(), "configuration") {
		t.Errorf("the error does not name the configuration: %v", err)
	}
	if out != "" {
		t.Errorf("printed defaults as the configuration: %.80q", out)
	}
}

// Asking for the defaults is intentional and must not be confused with
// a configuration that could not be read.
func TestConfigShowDefaultsDoNotNeedTheConfiguration(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config")
	if err := os.WriteFile(cfg, []byte("shell = bash\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(cfg, 0); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_CONFIG", cfg)

	out := captureStdout(t, func() {
		if err := configCmd([]string{"show", "--defaults"}); err != nil {
			t.Fatalf("config show --defaults: %v", err)
		}
	})
	if !strings.Contains(out, "font-size = 13") {
		t.Errorf("defaults were not printed: %.80q", out)
	}
}
