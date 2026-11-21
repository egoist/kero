package main

import (
	"strings"
	"testing"

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
