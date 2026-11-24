package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// A file dragged onto a pane of another machine that could not be read
// is a failure, and says one: it is not a folder, which is all the toast
// said of any file it could not stat — one gone between the drag and the
// upload, or one a directory's permission hid.
func TestRemotePasteStatFailedIsSaid(t *testing.T) {
	a, sent := remoteApp(t)
	dir := t.TempDir()
	gone := filepath.Join(dir, "gone.txt")
	// A folder is a folder's.
	a.remoteDrop("a", []string{dir})
	if !strings.Contains(a.pendingToast, "folder") {
		t.Errorf("a folder's toast is %q, want it named a folder", a.pendingToast)
	}
	a.pendingToast = ""
	// A file that is not there says it could not be read, not that it is
	// a folder.
	a.remoteDrop("a", []string{gone})
	if strings.Contains(a.pendingToast, "folder") {
		t.Errorf("a file that is not there was told a folder: %q", a.pendingToast)
	}
	if a.pendingToast == "" {
		t.Error("a file that is not there was not said")
	}
	// The good file of the same drop went on anyway.
	good := filepath.Join(dir, "shot.png")
	if err := os.WriteFile(good, fakePNG, 0o600); err != nil {
		t.Fatal(err)
	}
	a.pendingToast = ""
	a.remoteDrop("a", []string{gone, good})
	if strings.Contains(a.pendingToast, "folder") {
		t.Errorf("the drop's unreadable file was told a folder: %q", a.pendingToast)
	}
	select {
	case ups := <-sent:
		t.Errorf("the whole drop was refused over one file: uploaded %+v", ups)
	case <-time.After(100 * time.Millisecond):
	}
	if runtime.GOOS != "windows" && os.Getuid() != 0 {
		// A file under a directory of no permission reads the same.
		locked := filepath.Join(dir, "locked")
		if err := os.Mkdir(locked, 0o700); err != nil {
			t.Fatal(err)
		}
		f := filepath.Join(locked, "x.txt")
		if err := os.WriteFile(f, fakePNG, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(locked, 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(locked, 0o700) })
		a.pendingToast = ""
		a.remoteDrop("a", []string{f})
		if strings.Contains(a.pendingToast, "folder") {
			t.Errorf("a file under a locked directory was told a folder: %q", a.pendingToast)
		}
		if a.pendingToast == "" {
			t.Error("a file under a locked directory was not said")
		}
	}
}
