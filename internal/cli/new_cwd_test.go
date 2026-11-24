package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// kero new starts the session in the directory the command ran from —
// but when that directory is already gone, os.Getwd fails, and the
// session would silently open in the home instead: a place the user did
// not pick, with no word about it. A directory that cannot be read is
// said now, the way -d naming a missing directory already is.
func TestNewSaysAGoneWorkingDirectory(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root can still stat a deleted cwd on some filesystems")
	}
	sock, calls := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)
	t.Setenv("KERO_PANE", "")
	t.Setenv("KERO_SESSION", "")

	saved, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	dead := filepath.Join(t.TempDir(), "gone")
	if err := os.Mkdir(dead, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dead); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(saved) })
	if err := os.RemoveAll(dead); err != nil {
		t.Fatal(err)
	}

	err = run([]string{"new"}, "")
	if err == nil {
		t.Fatal("a session was started without a word about the missing directory")
	}
	if !strings.Contains(err.Error(), "current directory") {
		t.Errorf("the error is %v, want the current directory named", err)
	}
	for _, m := range calls() {
		if m == "create" {
			t.Error("a session was created in a directory the user did not pick")
		}
	}
}
