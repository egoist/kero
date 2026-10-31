package main

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/git"
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
// viewer, as its text, which edits and follows the file.
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
	if fv.st.ReadOnly {
		t.Error("the file's text doesn't edit with no agent working")
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

// The viewer's texts edit as VS Code's and Zed's do: a file of Files and
// the new side of a diff of Changes keep their edits, a dot on the
// viewer's close button saying so, until Save writes them through kerod,
// as the file was read and with its line endings, agent working or not.
// Closing the viewer with edits asks to save them, and a file changed on
// disk meanwhile asks to overwrite it or discard them.
func TestViewerEdits(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 1, Added: 1}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	writes := make(chan proto.FSWriteParams, 4)
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method != "fs.write" {
			return nil, errors.New("unexpected method " + method)
		}
		var p proto.FSWriteParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		writes <- p
		return git.Hash([]byte(p.Text)), nil
	})
	defer stop()
	written := func() (proto.FSWriteParams, bool) {
		select {
		case p := <-writes:
			return p, true
		case <-time.After(time.Second):
			return proto.FSWriteParams{}, false
		}
	}

	// A file of Files, with \r\n line endings, an agent working.
	a.prefs.Side = sideFiles
	s.Panes[1].Status = proto.Working
	fv := &fileView{pane: "a", path: "/tmp/demo/main.go", rel: "main.go", fetched: time.Now(), stamp: gitStamp(g)}
	fv.hash = git.Hash([]byte("package main\r\n"))
	showFileText(fv, "package main\r\n")
	a.openView(s, sideFiles, fv)
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	a.local().cl = cl
	if fv.st.ReadOnly {
		t.Fatal("the file is read only")
	}
	if tt.HasText("Unsaved changes") {
		t.Error("the viewer says it has unsaved changes before any edit")
	}
	fv.st.Buffer.Edit(editor.Edit{Start: 12, End: 12, Text: "\n\nfunc main() {}"})
	tt.Frame()
	tt.Advance(5 * time.Second)
	tt.Frame()
	select {
	case p := <-writes:
		t.Fatalf("wrote %q unsaved", p.Text)
	default:
	}
	if !tt.HasText("Unsaved changes") {
		t.Error("the viewer doesn't say it has unsaved changes")
	}
	shot(t, tt, "viewer-unsaved")
	a.paneRef("side-card").Focus() // as the user typing there has it
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyS)
	p, ok := written()
	if !ok {
		t.Fatal("Save didn't write the file")
	}
	if want := (proto.FSWriteParams{Path: "/tmp/demo/main.go", Hash: fv.hash, Text: "package main\r\n\r\nfunc main() {}\r\n"}); p != want {
		t.Errorf("wrote %+v, want %+v", p, want)
	}
	s.Panes[1].Status = proto.Idle

	// Closing the viewer with edits asks to save them; Don't Save drops
	// them, for the file as it is.
	fv.edits.saving = false // as the write answered, which no window runs here
	fv.st.Buffer.Edit(editor.Edit{Start: 0, End: 0, Text: "// Main.\n"})
	a.closeView(s)
	tt.Frame()
	if a.viewOf(s) == nil || !tt.HasText("Do you want to save the changes you made to “main.go”?") {
		t.Fatalf("closing with edits didn't ask to save them; texts %q", tt.Texts())
	}
	shot(t, tt, "viewer-ask-save")
	if err := tt.Click("Don't Save"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.viewOf(s) != nil || fv.st.Buffer.Modified() || !fv.fetched.IsZero() {
		t.Error("Don't Save didn't close the viewer, dropping the edits for the file read anew")
	}

	// The new side of a diff edits, and Save writes the one focused.
	a.local().cl = nil
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo", Files: []proto.GitFile{{Path: "pkg/a.go", Status: "modified", Added: 1}}}
	ch.fetched = time.Now()
	tt.Frame()
	sf := ch.files[scope+"|pkg/a.go"]
	if sf == nil {
		t.Fatal("no diff of pkg/a.go")
	}
	a.showText(sf, proto.GitText{Old: "package a\n", New: "package a\n\nvar x = 1\n", Hash: "h1"})
	tt.Frame()
	if !sf.d.Editable {
		t.Fatal("the diff's new side doesn't edit")
	}
	a.local().cl = cl
	sf.d.New.Edit(editor.Edit{Start: 0, End: 0, Text: "// A.\n"})
	ch.focus = sf
	a.paneRef("side-card").Focus()
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyS)
	p, ok = written()
	if !ok {
		t.Fatal("Save didn't write the diff's edit")
	}
	if want := (proto.FSWriteParams{Path: "/tmp/demo/pkg/a.go", Hash: "h1", Text: "// A.\npackage a\n\nvar x = 1\n"}); p != want {
		t.Errorf("wrote %+v, want %+v", p, want)
	}

	// Text read anew doesn't go over edits not saved.
	sf.edits.saving = false
	sf.d.New.Edit(editor.Edit{Start: 0, End: 0, Text: "x"})
	a.showText(sf, proto.GitText{Old: "package a\n", New: "package b\n", Hash: "h2"})
	if got := sf.d.New.String(); got[:1] != "x" || sf.hash != "h1" {
		t.Errorf("reading the file anew went over the user's edit: %q, hash %q", got, sf.hash)
	}
	if n := len(a.allTargets()); n != 1 {
		t.Errorf("%d texts to save as the app quits, want 1", n)
	}

	// Its file changed meanwhile: Discard Changes drops the edits.
	a.local().cl = nil
	a.askOverwrite(a.diffTarget(sf), func(bool) {})
	tt.Frame()
	if !tt.HasText("“a.go” changed on disk") {
		t.Fatalf("no question of the file changed; texts %q", tt.Texts())
	}
	shot(t, tt, "viewer-conflict")
	if err := tt.Click("Discard Changes"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if sf.d.New.Modified() {
		t.Error("Discard Changes kept the edits")
	}
}

// Edits not saved outlast the app, as VS Code's hot exit keeps them: they
// are backed up as the user pauses typing and as the app quits, which
// asks nothing, and come back, not saved still, as their files' texts
// load again, with the viewers that showed them.
func TestUnsavedOutlastQuit(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 1, Added: 1}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideFiles
	disk := []byte("package main\r\n")
	fv := &fileView{pane: "a", path: "/tmp/demo/main.go", rel: "main.go", fetched: time.Now(), stamp: gitStamp(g)}
	a.showFile(fv, disk)
	a.openView(s, sideFiles, fv)
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	fv.st.Buffer.Edit(editor.Edit{Start: 12, End: 12, Text: "\n\nfunc main() {}"})
	tt.Frame()

	// Backed up a moment after the user pauses.
	if _, err := os.Stat(backupPath()); err == nil {
		t.Fatal("backed up as the user typed")
	}
	tt.Advance(2 * time.Second)
	tt.Frame()
	var vb viewerBackup
	if b, err := os.ReadFile(backupPath()); err == nil {
		json.Unmarshal(b, &vb)
	}
	want := unsavedText{Kind: sideFiles, Pane: "a", Path: "/tmp/demo/main.go", Hash: git.Hash(disk), Text: "package main\r\n\r\nfunc main() {}\r\n"}
	if len(vb.Unsaved) != 1 || vb.Unsaved[0] != want {
		t.Fatalf("backed up %+v, want %+v", vb.Unsaved, want)
	}
	if st, _ := os.Stat(backupPath()); st.Mode().Perm() != 0o600 {
		t.Errorf("the backup is %v, readable by others", st.Mode().Perm())
	}

	// Quitting asks nothing.
	a.backupOnQuit()
	if a.confirm != nil {
		t.Fatalf("quitting asked %q", a.confirm.title)
	}

	// The next launch shows the viewer as it was, and the edit as the
	// file loads, not saved, with the hash of the file it was made on.
	b := newApp()
	v := b.side.views[s.ID]
	if v == nil || v.kind != sideFiles || v.file == nil || v.file.path != "/tmp/demo/main.go" || v.file.rel != "main.go" {
		t.Fatalf("the viewer came back as %+v", v)
	}
	now := []byte("package main\r\n\r\n// Changed meanwhile.\r\n")
	b.showFile(v.file, now)
	if got := bufferText(v.file.st.Buffer); got != want.Text || !v.file.st.Buffer.Modified() {
		t.Errorf("the edit came back as %q, modified %v", got, v.file.st.Buffer.Modified())
	}
	if v.file.hash != git.Hash(disk) {
		t.Error("the edit came back without the hash of the file it was made on, saving over the change made meanwhile")
	}
	if len(b.side.backup.unsaved) != 0 {
		t.Error("the edit stayed in the backup as it came back")
	}

	// A diff's too, as its text loads.
	b.side.backup.unsaved = map[string]unsavedText{}
	u := unsavedText{Kind: sideChanges, Pane: "a", Path: "/tmp/demo/pkg/a.go", Hash: "h0", Text: "package a // edited\n"}
	b.side.backup.unsaved[u.key()] = u
	sf := &sideFile{pane: "a", root: "/tmp/demo", f: proto.GitFile{Path: "pkg/a.go"}}
	b.showText(sf, proto.GitText{Old: "package a\n", New: "package a\n\nvar x = 1\n", Hash: "h1"})
	if got := sf.d.New.String(); got != u.Text || !sf.d.New.Modified() || sf.hash != "h0" {
		t.Errorf("the diff's edit came back as %q, hash %q", got, sf.hash)
	}
}

// The Files tab makes files and folders, renames and deletes them: New
// File in its header puts a field for the name at the top of the root,
// which Return makes, through kerod; a row's menu offers the same in its
// folder, Rename and Delete; a file renamed keeps its viewer, and its
// edits, at its new path; Delete asks first.
func TestFilesTabChanges(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main"}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideFiles
	h := a.hostOf(s.ID)
	fs := &a.side.files
	fs.dirs = map[string]*dirList{
		filesKey(h, "/tmp/demo"):          {entries: []proto.FSEntry{{Name: "internal", Dir: true}, {Name: "main.go"}}},
		filesKey(h, "/tmp/demo/internal"): {entries: []proto.FSEntry{{Name: "auth.go"}}},
	}
	calls := make(chan [2]string, 4)
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method == "fs.list" {
			return nil, errors.New("the tree keeps what it listed")
		}
		calls <- [2]string{method, string(raw)}
		return true, nil
	})
	defer stop()
	call := func() [2]string {
		select {
		case c := <-calls:
			return c
		case <-time.After(time.Second):
			return [2]string{}
		}
	}
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	a.local().cl = cl

	if err := tt.Click("New File…"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if fs.edit == nil || fs.edit.op != editNewFile || fs.edit.dir != "/tmp/demo" {
		t.Fatalf("New File put %+v", fs.edit)
	}
	tt.Type("docs/notes.md")
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if c := call(); c[0] != "fs.create" || c[1] != `{"path":"/tmp/demo/docs/notes.md"}` {
		t.Errorf("New File called %q", c)
	}
	shot(t, tt, "files-new")

	// A row's menu.
	if err := tt.RightClick("internal"); err != nil {
		t.Fatal(err)
	}
	if got := tt.Menu(); !slices.Contains(got, "New File…") || !slices.Contains(got, "New Folder…") || !slices.Contains(got, "Rename…") || !slices.Contains(got, "Delete…") {
		t.Fatalf("the folder's menu is %q", got)
	}
	if err := tt.ChooseMenuItem("New Folder…"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if fs.edit == nil || fs.edit.op != editNewFolder || fs.edit.dir != "/tmp/demo/internal" {
		t.Fatalf("New Folder in internal put %+v", fs.edit)
	}
	tt.Type("handlers")
	tt.Frame()
	shot(t, tt, "files-name")
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	if fs.edit != nil {
		t.Error("Escape left the field")
	}

	// Rename, in the entry's place.
	if err := tt.RightClick("main.go"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("Rename…"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if fs.edit == nil || fs.edit.op != editRename || fs.edit.name != "main.go" {
		t.Fatalf("Rename put %+v", fs.edit)
	}
	fs.edit.name = "app.go"
	a.commitName()
	if c := call(); c[0] != "fs.rename" || c[1] != `{"from":"/tmp/demo/main.go","to":"/tmp/demo/app.go"}` {
		t.Errorf("Rename called %q", c)
	}
	fs.edit = &nameEdit{op: editRename, pane: "a", dir: "/tmp/demo", path: "/tmp/demo/main.go", oldRel: "main.go", name: "a/b.go"}
	a.commitName()
	if c := call(); c[0] != "" {
		t.Errorf("a name with a slash renamed: %q", c)
	}

	// The viewer follows its file, and the folders theirs.
	fv := &fileView{pane: "a", path: "/tmp/demo/internal/auth.go", rel: "internal/auth.go"}
	showFileText(fv, "package internal\n")
	fv.st.Buffer.Edit(editor.Edit{Start: 0, End: 0, Text: "// x\n"})
	a.openView(s, sideFiles, fv)
	fs.open[filesKey(h, "/tmp/demo/internal")] = true
	a.renamed(h, "/tmp/demo/internal", "/tmp/demo/pkg", "internal", "pkg")
	if fv.path != "/tmp/demo/pkg/auth.go" || fv.rel != "pkg/auth.go" || !fv.st.Buffer.Modified() {
		t.Errorf("the viewer's file went to %q (%q), modified %v", fv.path, fv.rel, fv.st.Buffer.Modified())
	}
	if !fs.open[filesKey(h, "/tmp/demo/pkg")] || fs.open[filesKey(h, "/tmp/demo/internal")] {
		t.Error("the folder renamed didn't stay unfolded")
	}

	// Delete asks first.
	tt.Frame()
	if err := tt.RightClick("main.go"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("Delete…"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !tt.HasText("Delete “main.go”?") || !tt.HasText("Move to Trash") {
		t.Fatalf("Delete didn't ask; texts %q", tt.Texts())
	}
	shot(t, tt, "files-delete")
}

// The app opening with the right sidebar shown shows it at once, not
// sliding in as kerod's state comes; showing it later slides it in.
func TestRightSidebarOpensShown(t *testing.T) {
	a := testApp(t)
	a.prefs.Side = sideChanges
	a.loaded = false // kerod's state not come yet
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(50 * time.Millisecond)
	tt.Frame()
	if a.side.barW != 0 {
		t.Fatalf("the sidebar shows with no session, %v wide", a.side.barW)
	}
	a.loaded = true
	tt.Frame()
	if a.side.barW != a.rightWidth() {
		t.Errorf("as the state came, the sidebar was %v wide, not at once %v", a.side.barW, a.rightWidth())
	}

	a.toggleRight()
	tt.Advance(time.Second)
	tt.Frame()
	a.toggleRight()
	tt.Frame()
	tt.Advance(50 * time.Millisecond)
	tt.Frame()
	if w := a.side.barW; w <= 0 || w >= a.rightWidth() {
		t.Errorf("showing the sidebar didn't slide it in: %v wide a moment after", w)
	}
}

// The right sidebar's edge takes the pointer a few pixels to either side
// of it, over the cards and over the sidebar, and a drag there resizes it.
func TestRightSidebarEdge(t *testing.T) {
	a := testApp(t)
	a.prefs.Side = sideFiles
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	edge := 1280 - a.side.barW
	for dx := float32(-4); dx <= 4; dx++ {
		tt.Move(edge+dx, 400)
		tt.Frame()
		if c := tt.Cursor(); c != ui.CursorResizeColumn {
			t.Errorf("%v from the edge, the cursor is %v", dx, c)
		}
	}
	w := a.rightWidth()
	tt.Press(edge, 400)
	tt.Move(edge-40, 400)
	tt.Release(edge-40, 400)
	tt.Frame()
	if got := a.rightWidth(); got != w+40 {
		t.Errorf("dragging the edge 40 left made the sidebar %v wide, want %v", got, w+40)
	}
}

// In a window too narrow for the panes', the viewer's and the right
// sidebar's widths, the viewer shares the room left with the panes rather
// than running under the sidebar.
func TestNarrowWindowKeepsViewerBesideSidebar(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	a.prefs.SidebarHidden = true
	a.prefs.Side = sideFiles
	fv := &fileView{pane: "a", path: "/tmp/main.go", rel: "main.go", fetched: time.Now()}
	a.showFile(fv, []byte("package main\n"))
	a.openView(s, sideFiles, fv)
	var card, row ui.Rect
	tt := ui.NewTester(func(c *ui.Context) {
		a.view(c)
		card, row = a.paneRef("side-card").Bounds(c), a.paneRef("with-side").Bounds(c)
	}, 560, 600)
	tt.Frame()
	a.toggleRight() // shown anyway, as the window crowds it
	for range 3 {
		tt.Frame()
		tt.Advance(time.Second)
	}
	tt.Frame()
	if a.side.barW == 0 {
		t.Fatal("the sidebar didn't show")
	}
	if edge := float32(560) - a.side.barW; card.X+card.W > edge+0.5 {
		t.Errorf("the viewer runs to %v, under the sidebar from %v", card.X+card.W, edge)
	}
	if card.W <= 0 || card.W > row.W/2+1 {
		t.Errorf("the viewer is %v wide in a row of %v", card.W, row.W)
	}
	shot(t, tt, "narrow")
}

// A window too narrow for the right sidebar beside the cards hides it,
// shown as it is, with the button that shows it, which shows it anyway;
// the window widening shows it again, and narrowing hides it again.
func TestRightSidebarMakesRoom(t *testing.T) {
	a := testApp(t)
	a.prefs.Side = sideFiles
	tt := ui.NewTester(a.view, 1280, 720)
	settle := func() {
		tt.Frame()
		tt.Advance(time.Second)
		tt.Frame()
	}
	settle()
	if a.side.barW == 0 {
		t.Fatal("the sidebar didn't show in a wide window")
	}
	show := a.tip("Show Right Sidebar", "rightSidebar.toggle")

	tt.SetSize(640, 720)
	settle()
	if a.side.barW != 0 || a.prefs.Side != sideFiles {
		t.Fatalf("a narrow window left the sidebar %v wide, shown %q", a.side.barW, a.prefs.Side)
	}
	if err := tt.Click(show); err != nil {
		t.Fatal(err)
	}
	settle()
	if a.side.barW == 0 {
		t.Fatal("Show Right Sidebar didn't show it in a narrow window")
	}
	if tt.HasText("Show Right Sidebar") {
		t.Error("the button stayed with the sidebar shown")
	}

	tt.SetSize(1280, 720)
	settle()
	tt.SetSize(640, 720)
	settle()
	if a.side.barW != 0 {
		t.Error("narrowing the window again didn't hide the sidebar")
	}
	tt.SetSize(1280, 720)
	settle()
	if a.side.barW != a.rightWidth() {
		t.Error("widening the window didn't show the sidebar again")
	}
}

// As the window resizes, the viewer takes its width in the same frame,
// never the last one's, which would shake its edge and its text.
func TestViewerFollowsResize(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	a.prefs.Side = sideFiles
	a.prefs.SideWidth = 600 // wider than the room: the panes' least decides
	fv := &fileView{pane: "a", path: "/tmp/main.go", rel: "main.go", fetched: time.Now()}
	a.showFile(fv, []byte("package main\n"))
	a.openView(s, sideFiles, fv)
	var card, row ui.Rect
	tt := ui.NewTester(func(c *ui.Context) {
		a.view(c)
		card, row = a.paneRef("side-card").Bounds(c), a.paneRef("with-side").Bounds(c)
	}, 1300, 720)
	for range 3 {
		tt.Frame()
		tt.Advance(time.Second)
	}
	for _, w := range []int{1320, 1340, 1310, 1290, 1330} {
		tt.SetSize(w, 720)
		tt.Frame()
		if want := row.W - minPanes; math.Abs(float64(card.W-want)) > 0.5 {
			t.Errorf("at %d wide the viewer is %v wide, want %v as the row is %v", w, card.W, want, row.W)
		}
	}
}
