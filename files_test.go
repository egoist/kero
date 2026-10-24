package main

import (
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/client"
	"kero/internal/proto"
)

// The Files view shows a session's folder as a tree, its folders opening
// on a click, and the file chosen in it under the tree: its text, or why
// it shows none.
func TestFilesView(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	a.prefs.Side = sideFiles
	// A host connected, whose folders never come: the tree shows what it
	// was given.
	a.local().cl = &client.Client{}

	// What kerod would answer: the pane's own folder, which is the tree's.
	s.Panes[0].ProcessDir = "/tmp/demo"
	pane, root := a.filesRoot(s)
	tree := a.tree(pane, root)
	tree.dirs[root] = &fileDir{paths: []string{"/tmp/demo/src", "/tmp/demo/main.go", "/tmp/demo/logo.png", "/tmp/demo/blob.bin"}}
	for _, p := range tree.dirs[root].paths {
		tree.isDir[p] = p == "/tmp/demo/src"
	}
	tree.dirs["/tmp/demo/src"] = &fileDir{paths: []string{"/tmp/demo/src/a.go"}}

	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	for _, want := range []string{"Files", "Changes", "demo", "src", "main.go", "logo.png"} {
		if !tt.HasText(want) {
			t.Fatalf("no %q; texts %q", want, tt.Texts())
		}
	}
	shot(t, tt, "files-tree")

	// A folder opens on a click.
	if err := tt.Click("src"); err != nil {
		t.Fatalf("click src: %v", err)
	}
	tt.Frame()
	if !tt.HasText("a.go") {
		t.Errorf("a folder did not open; texts %q", tt.Texts())
	}

	// A file opens under the tree.
	f := &openFile{path: "/tmp/demo/main.go"}
	b := editor.NewBuffer("package main\n\nfunc main() {}\n")
	b.SetLanguage(editor.LanguageFor("main.go"))
	f.st = &editor.State{Buffer: b}
	tree.shown, tree.file = "/tmp/demo/main.go", f
	tt.Frame()
	if !tt.HasText("Code editor") {
		t.Errorf("no text of the file; texts %q", tt.Texts())
	}
	shot(t, tt, "files-open")

	// A binary file is told of, not shown.
	tree.shown, tree.file = "/tmp/demo/blob.bin", &openFile{path: "/tmp/demo/blob.bin", binary: true}
	tt.Frame()
	if !tt.HasText("Binary file") {
		t.Errorf("no note of a binary file; texts %q", tt.Texts())
	}

	// A session with no folder says why.
	s.Panes[0].Dir, s.Panes[0].ProcessDir, s.Panes[1].Dir = "", "", ""
	tt.Frame()
	if !tt.HasText("No folder") {
		t.Errorf("no note of a session without a folder; texts %q", tt.Texts())
	}
}

// A path of a host joins with the host's separator, which its own paths
// tell.
func TestHostJoin(t *testing.T) {
	for _, c := range []struct{ dir, name, want string }{
		{"/tmp/demo", "src", "/tmp/demo/src"},
		{"/tmp/", "src", "/tmp/src"},
		{`C:\Users\me`, "src", `C:\Users\me\src`},
		{`C:\Users\me\`, "src", `C:\Users\me\src`},
		{`C:`, "src", `C:\src`},
	} {
		if got := hostJoin(c.dir, c.name); got != c.want {
			t.Errorf("hostJoin(%q, %q) = %q, want %q", c.dir, c.name, got, c.want)
		}
	}
}

// A tree names a path from its folder, with either slash between.
func TestFileTreeRel(t *testing.T) {
	tree := &fileTree{root: "/tmp/demo"}
	for p, want := range map[string]string{
		"/tmp/demo/main.go":  "main.go",
		"/tmp/demo/src/a.go": "src/a.go",
		`/tmp/demo/src\a.go`: `src\a.go`,
	} {
		if got := tree.rel(p); got != want {
			t.Errorf("rel(%q) = %q, want %q", p, got, want)
		}
	}
	if !strings.HasPrefix(tree.rel("/tmp/demo/x"), "x") {
		t.Error("rel kept the folder's slash")
	}
	_ = proto.FSList{}
}

// The header's tabs show their view on a click, each way, so that the
// header's drag of the window does not keep them.
func TestSideTabsClick(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	s.Panes[0].ProcessDir, s.Panes[1].ProcessDir = "/tmp/demo", "/tmp/demo"
	// A host connected, whose folders never come: the tree shows what it
	// was given.
	a.local().cl = &client.Client{}
	pane, root := a.filesRoot(s)
	a.tree(pane, root).dirs[root] = &fileDir{paths: []string{"/tmp/demo/main.go"}}
	a.prefs.Side = sideChanges
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	if err := tt.Click("Files"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.prefs.Side != sideFiles {
		t.Fatalf("a click on Files showed %q", a.prefs.Side)
	}
	if !tt.HasText("main.go") {
		t.Errorf("the Files view did not show; texts %q", tt.Texts())
	}
	if err := tt.Click("Changes"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.prefs.Side != sideChanges {
		t.Fatalf("a click on Changes showed %q", a.prefs.Side)
	}
}
