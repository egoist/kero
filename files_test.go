package main

import (
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

// The right sidebar shows on the tab it showed last, from the button in
// the header at the window's top right, and hides from its own; Toggle
// Changes and Toggle Files show their tab, or hide the sidebar showing it.
func TestRightSidebar(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	shot(t, tt, "right-hidden")
	if err := tt.Click(a.tip("Show Right Sidebar", "rightSidebar.toggle")); err != nil {
		t.Fatal(err)
	}
	tt.Advance(time.Second)
	tt.Frame()
	if a.prefs.Side != sideChanges || !tt.HasText("Files") {
		t.Fatalf("the sidebar didn't show on Changes: %q; texts %q", a.prefs.Side, tt.Texts())
	}
	if a.viewOf(s) != nil {
		t.Error("showing the sidebar opened the viewer")
	}
	if tt.HasText("Show Right Sidebar") {
		t.Error("the button that shows the sidebar stayed as it showed")
	}
	shot(t, tt, "right-sidebar")

	if err := tt.Click("Files"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.prefs.Side != sideFiles {
		t.Errorf("a click on Files showed %q", a.prefs.Side)
	}
	if err := tt.Click(a.tip("Hide Right Sidebar", "rightSidebar.toggle")); err != nil {
		t.Fatal(err)
	}
	tt.Advance(time.Second)
	tt.Frame()
	if a.prefs.Side != "" {
		t.Errorf("the sidebar stayed: %q", a.prefs.Side)
	}
	a.run("rightSidebar.toggle", nil)
	if a.prefs.Side != sideFiles {
		t.Errorf("the sidebar came back on %q, not the tab it showed last", a.prefs.Side)
	}

	// Toggle Changes shows the tab and the diffs, and again hides both.
	a.run("changes.toggle", nil)
	if v := a.viewOf(s); a.prefs.Side != sideChanges || v == nil || v.kind != sideChanges {
		t.Fatal("Toggle Changes didn't show the changes and their diffs")
	}
	a.run("changes.toggle", nil)
	if a.prefs.Side != "" || a.viewOf(s) != nil {
		t.Error("Toggle Changes again didn't hide the sidebar and the diffs")
	}
	a.run("files.toggle", nil)
	if a.prefs.Side != sideFiles || a.viewOf(s) != nil {
		t.Errorf("Toggle Files showed %q, and the viewer %v", a.prefs.Side, a.viewOf(s))
	}
}

// The Files tab is the worktree's tree, a folder listed as it unfolds,
// without .git, what git ignores faded; a click on a file opens it in the
// viewer, as its text, which follows the file.
func TestFilesTab(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main"}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideFiles
	h := a.hostOf(s.ID)
	fs := &a.side.files
	fs.dirs = map[string]*dirList{
		filesKey(h, "/tmp/demo"): {entries: []proto.FSEntry{
			{Name: ".git", Dir: true}, {Name: "internal", Dir: true}, {Name: "node_modules", Dir: true, Ignored: true}, {Name: "main.go"},
		}},
		filesKey(h, "/tmp/demo/internal"): {entries: []proto.FSEntry{{Name: "auth.go"}}},
	}
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	for _, want := range []string{"internal", "node_modules", "main.go"} {
		if _, ok := tt.Find(want); !ok {
			t.Errorf("no %q; texts %q", want, tt.Texts())
		}
	}
	for _, not := range []string{".git", "auth.go"} {
		if _, ok := tt.Find(not); ok {
			t.Errorf("%q shows", not)
		}
	}

	if err := tt.Click("internal"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if _, ok := tt.Find("auth.go"); !ok {
		t.Fatalf("unfolding internal didn't show auth.go; texts %q", tt.Texts())
	}
	if err := tt.Click("auth.go"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	v := a.viewOf(s)
	if v == nil || v.kind != sideFiles || v.file == nil || v.file.path != "/tmp/demo/internal/auth.go" || v.file.rel != "internal/auth.go" {
		t.Fatalf("a click on auth.go opened %+v", v)
	}
	fv := v.file
	fv.fetched = time.Now()
	showFileText(fv, "package internal\r\n\r\nfunc Auth() {}\r\n")
	tt.Frame()
	tt.Frame()
	if got := fv.st.Buffer.String(); got != "package internal\n\nfunc Auth() {}\n" {
		t.Errorf("the viewer shows %q", got)
	}
	if !fv.st.ReadOnly {
		t.Error("the file's text is editable")
	}
	tt.Advance(time.Second)
	tt.Frame()
	shot(t, tt, "side-files")

	// The file changing changes the text in place.
	st := fv.st
	showFileText(fv, "package internal\n\n// Auth signs in.\nfunc Auth() {}\n")
	if fv.st != st || fv.st.Buffer.String() != "package internal\n\n// Auth signs in.\nfunc Auth() {}\n" {
		t.Error("the file's text didn't change in place")
	}

	// Collapse Folders folds them all.
	if err := tt.Click("Collapse Folders"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if _, ok := tt.Find("auth.go"); ok && len(fs.open) != 0 {
		t.Error("Collapse Folders left internal unfolded")
	}
}

func TestIsBinary(t *testing.T) {
	if isBinary([]byte("hello\nworld")) || !isBinary([]byte("PNG\x00\x01")) || isBinary(nil) {
		t.Error("isBinary is wrong")
	}
}
