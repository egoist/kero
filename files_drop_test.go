package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

// copyEntry copies files and folders, replaces or keeps what has their
// name, and puts no folder into itself.
func TestCopyEntry(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	write := func(p, s string) {
		t.Helper()
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	read := func(p string) string {
		b, _ := os.ReadFile(p)
		return string(b)
	}
	write(filepath.Join(src, "a.txt"), "new")
	write(filepath.Join(src, "dir", "in", "b.txt"), "b")
	write(filepath.Join(dst, "a.txt"), "old")

	if err := copyEntry(filepath.Join(src, "a.txt"), filepath.Join(dst, "a.txt"), false); err != nil || read(filepath.Join(dst, "a.txt")) != "old" {
		t.Errorf("skipping replaced it: %v %q", err, read(filepath.Join(dst, "a.txt")))
	}
	if err := copyEntry(filepath.Join(src, "a.txt"), filepath.Join(dst, "a.txt"), true); err != nil || read(filepath.Join(dst, "a.txt")) != "new" {
		t.Errorf("replacing: %v %q", err, read(filepath.Join(dst, "a.txt")))
	}
	if err := copyEntry(filepath.Join(src, "dir"), filepath.Join(dst, "dir"), true); err != nil || read(filepath.Join(dst, "dir", "in", "b.txt")) != "b" {
		t.Errorf("a folder: %v", err)
	}
	if err := copyEntry(filepath.Join(src, "dir"), filepath.Join(src, "dir", "in", "dir"), true); err != errIntoItself {
		t.Errorf("into itself: %v", err)
	}
	if err := copyEntry(filepath.Join(src, "a.txt"), filepath.Join(src, "a.txt"), true); err != nil || read(filepath.Join(src, "a.txt")) != "new" {
		t.Errorf("onto itself: %v", err)
	}
}

// Files dropped on a folder's row of the Files tab are copied into it; a
// name it holds already asks first.
func TestDropFilesIntoTree(t *testing.T) {
	a := testApp(t)
	root, from := t.TempDir(), t.TempDir()
	os.Mkdir(filepath.Join(root, "docs"), 0o755)
	os.WriteFile(filepath.Join(root, "docs", "shot.png"), []byte("old"), 0o644)
	os.WriteFile(filepath.Join(from, "shot.png"), []byte("new"), 0o644)
	os.WriteFile(filepath.Join(from, "report.pdf"), []byte("pdf"), 0o644)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: root, Branch: "main", Default: "main"}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideFiles
	h := a.hostOf(s.ID)
	a.side.files.dirs = map[string]*dirList{
		filesKey(h, root): {entries: []proto.FSEntry{{Name: "docs", Dir: true}, {Name: "README.md"}}},
	}
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	docs, ok := tt.Find("docs")
	if !ok {
		t.Fatalf("no docs row; texts %q", tt.Texts())
	}
	x, y := docs.X+docs.W/2, docs.Y+docs.H/2
	tt.DropFiles(x, y, filepath.Join(from, "report.pdf"))
	tt.Frame()
	waitFor(t, func() bool { _, err := os.Stat(filepath.Join(root, "docs", "report.pdf")); return err == nil })
	if a.confirm != nil && a.confirm.open {
		t.Error("a new name asked first")
	}

	tt.DropFiles(x, y, filepath.Join(from, "shot.png"))
	tt.Frame()
	tt.Frame()
	if a.confirm == nil || !a.confirm.open || a.confirm.title != "Replace “shot.png”?" {
		t.Fatalf("no question about shot.png: %+v", a.confirm)
	}
	shot(t, tt, "drop-replace")
	a.confirm.altRun() // Skip
	time.Sleep(100 * time.Millisecond)
	if b, _ := os.ReadFile(filepath.Join(root, "docs", "shot.png")); string(b) != "old" {
		t.Errorf("Skip replaced it: %q", b)
	}
	a.confirm.run() // Replace
	a.confirm = nil
	waitFor(t, func() bool { b, _ := os.ReadFile(filepath.Join(root, "docs", "shot.png")); return string(b) == "new" })

	// Below the rows: into the root.
	tt.DropFiles(x, 600, filepath.Join(from, "report.pdf"))
	tt.Frame()
	waitFor(t, func() bool { _, err := os.Stat(filepath.Join(root, "report.pdf")); return err == nil })
}

// waitFor waits for what goes on off the main thread.
func waitFor(t *testing.T, done func() bool) {
	t.Helper()
	for range 200 {
		if done() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out")
}

// What a file's copy lands on is not taken away before the copy is
// there: a copy that fails leaves what was there.
func TestCopyEntryKeepsWhatIsThereWhenTheCopyFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permissions are Unix's")
	}
	if os.Geteuid() == 0 {
		t.Skip("root reads a file with no read permission")
	}
	src, dst := t.TempDir(), t.TempDir()
	// A file that cannot be read: its copy cannot be made.
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("new"), 0o000); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dst, "f"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := copyEntry(filepath.Join(src, "f"), filepath.Join(dst, "f"), true); err == nil {
		t.Fatal("the copy went on: a file that cannot be read was copied")
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "f")); string(b) != "old" {
		t.Errorf("what was there is gone: %q", b)
	}
	// Nothing of the copy is left behind.
	entries, _ := os.ReadDir(dst)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".kero-copy-") {
			t.Errorf("the copy left %s behind", e.Name())
		}
	}
}

// A folder's copy that fails leaves the folder that was there as well:
// a copy that is half made is not a copy.
func TestCopyEntryKeepsWhatIsThereWhenAFolderCopyFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permissions are Unix's")
	}
	if os.Geteuid() == 0 {
		t.Skip("root reads a file with no read permission")
	}
	src, dst := t.TempDir(), t.TempDir()
	in := filepath.Join(src, "d", "in")
	if err := os.MkdirAll(in, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(in, "b.txt"), []byte("b"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A folder of the copy that cannot be read: the copy of it cannot be
	// made whole.
	if err := os.Chmod(in, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(in, 0o755) })
	if err := os.Mkdir(filepath.Join(dst, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dst, "d", "old.txt"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := copyEntry(filepath.Join(src, "d"), filepath.Join(dst, "d"), true); err == nil {
		t.Fatal("the copy went on: a folder that cannot be read was copied")
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "d", "old.txt")); string(b) != "old" {
		t.Errorf("what was there is gone: %q", b)
	}
	entries, _ := os.ReadDir(dst)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".kero-copy-") {
			t.Errorf("the copy left %s behind", e.Name())
		}
	}
}

// A replacement that fails after the copy is made says where the whole
// copy is: the part of what was there that could not be taken away stays,
// and the copy is not silently left as an orphan either — it is the
// user's, named in the failure the toast shows.
func TestCopyEntrySaysWhereAFailedRemoveLeftTheCopy(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permissions are Unix's")
	}
	if os.Geteuid() == 0 {
		t.Skip("root enters a directory with no search permission")
	}
	src, dst := t.TempDir(), t.TempDir()
	in := filepath.Join(src, "d", "in")
	if err := os.MkdirAll(in, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(in, "b.txt"), []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}
	// What is there: a folder holding a folder whose entries cannot be
	// reached, so the removal of it fails part way.
	old := filepath.Join(dst, "d", "locked")
	if err := os.MkdirAll(old, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(old, "b.txt"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(old, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(old, 0o755) })
	err := copyEntry(filepath.Join(src, "d"), filepath.Join(dst, "d"), true)
	if err == nil {
		t.Fatal("a copy over a folder whose removal failed was put in place")
	}
	if !strings.Contains(err.Error(), ".kero-copy-") {
		t.Errorf("the failure does not say where the whole copy is: %v", err)
	}
	// The part of the old folder that could not be taken away stays.
	if _, statErr := os.Stat(old); statErr != nil {
		t.Errorf("the locked part is gone: %v", statErr)
	}
}
