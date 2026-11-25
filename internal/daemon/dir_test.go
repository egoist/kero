package daemon

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"kero/internal/proto"
)

// A directory that is there but cannot be looked into is not "no
// directory": the stat's failure is said as what it is, so a session is
// not refused under a name that says the files are lost.
func TestCleanDirSaysAStatThatFailed(t *testing.T) {
	d := testDaemon(t)
	base := t.TempDir()
	file := filepath.Join(base, "file")
	if err := os.WriteFile(file, []byte("hi"), 0o600); err != nil {
		t.Fatal(err)
	}
	in := filepath.Join(file, "in")
	if _, err := d.cleanDir(in); err == nil || strings.Contains(err.Error(), "no directory") {
		t.Errorf("a parent that is no folder said %v, want the stat's failure", err)
	}
	dir := filepath.Join(base, "work")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := d.cleanDir(dir); err != nil || got != dir {
		t.Errorf("a directory that is there: %v, %q", err, got)
	}
	if _, err := d.cleanDir(filepath.Join(base, "gone")); err == nil || !strings.Contains(err.Error(), "no directory") {
		t.Errorf("a directory that is not there said %v", err)
	}

	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("requires Unix directory permissions without root privileges")
	}
	locked := filepath.Join(base, "locked")
	if err := os.Mkdir(locked, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(locked, "work"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o700) })
	if _, err := d.cleanDir(filepath.Join(locked, "work")); err == nil || strings.Contains(err.Error(), "no directory") {
		t.Errorf("a directory it could not look into said %v, want the stat's failure", err)
	}

	// A session is not made in a directory that could not be looked into.
	if _, err := d.create(proto.CreateParams{Dir: filepath.Join(locked, "work")}); err == nil || strings.Contains(err.Error(), "no directory") {
		t.Errorf("create said %v, want the stat's failure", err)
	}
}
