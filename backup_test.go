package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/git"
	"kero/internal/proto"
)

// An edit of a diff comes back to the diff it was made in: the same file
// against another base is another text, and keeps its own.
func TestEditComesBackToItsOwnDiff(t *testing.T) {
	a := testApp(t)
	p := &a.st.Sessions[0].Panes[0]
	root := "/tmp/demo"
	p.Git = &proto.GitInfo{Root: root, Branch: "main", Default: "main"}
	head, branch := changesScope(p, git.BaseHead), changesScope(p, git.BaseBranch)
	if head == branch {
		t.Fatalf("the two lists of changes are one: %q", head)
	}
	text := proto.GitText{Old: "package main\n", New: "package main\n", Hash: "h"}
	// The app last quit with an edit of a.go's diff against head.
	a.side.backup.unsaved = map[string]unsavedText{
		unsavedKey(sideChanges, "", head, root+"/a.go"): {Kind: sideChanges, Scope: head, Pane: "a", Path: root + "/a.go", Hash: "h", Text: "// head\n"},
	}
	// The same file against another base is another text.
	other := &sideFile{pane: "a", scope: branch, root: root, f: proto.GitFile{Path: "a.go"}}
	a.showText(other, text)
	if got := other.d.New.String(); strings.Contains(got, "// head") {
		t.Errorf("the edit of the head diff came back in the branch diff: %q", got)
	}
	if _, ok := a.side.backup.unsaved[unsavedKey(sideChanges, "", head, root+"/a.go")]; !ok {
		t.Error("the edit of the head diff was spent on the branch diff")
	}
	// The head diff takes it.
	sf := &sideFile{pane: "a", scope: head, root: root, f: proto.GitFile{Path: "a.go"}}
	a.showText(sf, text)
	if got := sf.d.New.String(); !strings.Contains(got, "// head") {
		t.Errorf("the edit did not come back: %q", got)
	}
	if _, ok := a.side.backup.unsaved[unsavedKey(sideChanges, "", head, root+"/a.go")]; ok {
		t.Error("the edit stayed backed up after it came back")
	}
	// A file's edit keeps the key it always had: no scope of its own, so
	// one backed up before scopes were stays the file's.
	if got, want := unsavedKey(sideFiles, "", "", root+"/a.go"), sideFiles+"\x00\x00"+root+"/a.go"; got != want {
		t.Errorf("a file's key is %q, want %q", got, want)
	}
	// And an edit is backed up against the list it is in.
	a.side.changes.base = git.BaseHead
	a.side.changes.files = map[string]*sideFile{head + "|a.go": sf}
	sf.d.New.Edit(editor.Edit{Start: 0, End: 0, Text: "// again\n"})
	var backed bool
	for _, u := range a.backupNow().Unsaved {
		if u.Path == root+"/a.go" && u.Scope == head {
			backed = true
		}
	}
	if !backed {
		t.Error("the edit was backed up without the list of changes it is in")
	}
}

// The signature of the backup is of what the backup holds, not of the
// order a map yields its entries: several viewers, and the signature is
// the same from call to call, so the backup sees the pause and writes
// (backupEdits reads every change of it as the user typing on).
func TestBackupSigSteady(t *testing.T) {
	a := testApp(t)
	a.side.views = map[string]*sideView{
		"s1": {kind: sideChanges},
		"s2": {kind: sideFiles, file: &fileView{pane: "a", path: "/x/a.go"}},
		"s3": {kind: sideFiles, file: &fileView{pane: "a", path: "/x/b.go"}},
		"s4": {kind: sideChanges},
	}
	sig := a.backupSig()
	for i := 0; i < 100; i++ {
		if got := a.backupSig(); got != sig {
			t.Fatalf("the signature changed with nothing changed: %q, then %q", sig, got)
		}
	}
}

// A backup that could not be written is tried again a moment on: it was
// marked written before it was written, so a failure left the edits
// unbacked until the app quit.
func TestBackupWriteIsRetried(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 1, Added: 1}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideFiles
	disk := []byte("package main\n")
	fv := &fileView{pane: "a", path: "/tmp/demo/main.go", rel: "main.go", fetched: time.Now(), stamp: gitStamp(g)}
	a.showFile(fv, disk)
	a.openView(s, sideFiles, fv)
	fv.st.Buffer.Edit(editor.Edit{Start: 12, End: 12, Text: "\n\nfunc main() {}"})

	// Nothing can be written where the backup's temp file goes.
	if err := os.MkdirAll(backupPath()+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(2 * time.Second)
	tt.Frame()
	if _, err := os.Stat(backupPath()); err == nil {
		t.Fatal("a backup was written where nothing can be")
	}
	if a.side.backup.written == a.side.backup.sig {
		t.Error("the backup is marked written though nothing was written")
	}

	// The way is clear again: the edit is backed up without a keystroke.
	os.RemoveAll(backupPath() + ".tmp")
	tt.Advance(2 * time.Second)
	tt.Frame()
	var vb viewerBackup
	b, err := os.ReadFile(backupPath())
	if err != nil {
		t.Fatalf("the backup was not tried again: %v", err)
	}
	json.Unmarshal(b, &vb)
	if len(vb.Unsaved) != 1 || vb.Unsaved[0].Path != "/tmp/demo/main.go" {
		t.Errorf("backed up %+v", vb.Unsaved)
	}
}

// A backup that could not be read is said: the edits the user made are
// in it, and the app shows none of them without it. A backup that is not
// there is no news: there was none to restore.
func TestUnreadableBackupIsSaid(t *testing.T) {
	home := t.TempDir()
	t.Setenv("KERO_HOME", home)
	t.Setenv("KERO_CONFIG", filepath.Join(home, "config"))
	// The backup cannot be read: the path is a directory.
	if err := os.MkdirAll(backupPath(), 0o700); err != nil {
		t.Fatal(err)
	}
	a := newApp()
	if !strings.Contains(a.pendingToast, "unsaved") {
		t.Errorf("the unreadable backup was not said: %q", a.pendingToast)
	}

	// The backup is there, and is not what the app wrote: it is said too.
	home = t.TempDir()
	t.Setenv("KERO_HOME", home)
	t.Setenv("KERO_CONFIG", filepath.Join(home, "config"))
	if err := os.WriteFile(backupPath(), []byte(`{"unsaved": [`), 0o600); err != nil {
		t.Fatal(err)
	}
	a = newApp()
	if !strings.Contains(a.pendingToast, "unsaved") {
		t.Errorf("the corrupt backup was not said: %q", a.pendingToast)
	}
	if len(a.side.backup.unsaved) != 0 {
		t.Errorf("the corrupt backup was read: %+v", a.side.backup.unsaved)
	}

	// And a backup that is not there is no news.
	home = t.TempDir()
	t.Setenv("KERO_HOME", home)
	t.Setenv("KERO_CONFIG", filepath.Join(home, "config"))
	a = newApp()
	if a.pendingToast != "" {
		t.Errorf("the missing backup was said: %q", a.pendingToast)
	}

	// A backup the app wrote is read, and said nothing about.
	home = t.TempDir()
	t.Setenv("KERO_HOME", home)
	t.Setenv("KERO_CONFIG", filepath.Join(home, "config"))
	b, err := json.Marshal(viewerBackup{Unsaved: []unsavedText{{Kind: sideFiles, Path: "/tmp/demo/main.go", Hash: "h", Text: "// mine\n"}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(backupPath(), b, 0o600); err != nil {
		t.Fatal(err)
	}
	a = newApp()
	if a.pendingToast != "" {
		t.Errorf("the backup was said: %q", a.pendingToast)
	}
	if len(a.side.backup.unsaved) != 1 {
		t.Errorf("the backup was not read: %+v", a.side.backup.unsaved)
	}
}
