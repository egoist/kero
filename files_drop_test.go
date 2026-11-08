package main

import (
	"os"
	"path/filepath"
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
