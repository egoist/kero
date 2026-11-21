package main

import (
	"testing"

	"github.com/egoist/mygo/ui/editor"

	"kero/internal/git"
	"kero/internal/proto"
)

// The Changes viewer asks to save the diffs of the list it shows: the
// diffs of another worktree's changes are another session's, and stay
// theirs.
func TestChangesViewerSavesItsOwnList(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	s.Panes[0].Git = &proto.GitInfo{Root: "/tmp/a", Branch: "main", Default: "main"}
	a.side.changes.base = git.BaseHead
	one := editedDiff(t, a, "/tmp/a", "main.go")
	two := editedDiff(t, a, "/tmp/b", "main.go")
	a.side.changes.files = map[string]*sideFile{
		"/tmp/a|head|main.go": one,
		"/tmp/b|head|main.go": two,
	}
	v := &sideView{kind: sideChanges}
	ts := a.viewTargets(v, s)
	if len(ts) != 1 || ts[0].path != "/tmp/a/main.go" {
		t.Fatalf("the viewer asks to save %+v", ts)
	}
	// And the diffs of the worktree the session is in, when it is in
	// another one.
	s.Panes[0].Git = &proto.GitInfo{Root: "/tmp/b", Branch: "main", Default: "main"}
	ts = a.viewTargets(v, s)
	if len(ts) != 1 || ts[0].path != "/tmp/b/main.go" {
		t.Fatalf("the viewer asks to save %+v", ts)
	}
}

// editedDiff is a changed file's diff whose new side the user edited.
func editedDiff(t *testing.T, a *App, root, path string) *sideFile {
	sf := &sideFile{pane: "a", scope: root + "|" + git.BaseHead, root: root, f: proto.GitFile{Path: path}}
	a.showText(sf, proto.GitText{Old: "package main\n", New: "package main\n", Hash: "h"})
	sf.d.New.Edit(editor.Edit{Start: 0, End: 0, Text: "// edited\n"})
	if !a.diffTarget(sf).dirty() {
		t.Fatalf("the diff of %s is not edited", path)
	}
	return sf
}

// A diff of a pane gone is not a text to save: no host has the pane, and
// the local one is where its file is not — a session that ended must not
// have its diff written here.
func TestDiffOfAPaneGoneIsNotSaved(t *testing.T) {
	a := testApp(t)
	a.st.Sessions[0].Panes[0].Git = &proto.GitInfo{Root: "/tmp/a", Branch: "main", Default: "main"}
	sf := editedDiff(t, a, "/tmp/a", "main.go")
	sf.pane = "gone"
	if a.diffTarget(sf).dirty() {
		t.Error("a diff of a pane gone is a text to save")
	}
	if ts := a.allTargets(); len(ts) != 0 {
		t.Errorf("the texts with edits to save: %+v", ts)
	}
}

// The edit of a diff of a pane gone is not saved, but it is still backed
// up: its file is where it was, on the host it was asked of, and the
// worktree may show it again.
func TestEditOfAPaneGoneStaysBackedUp(t *testing.T) {
	a := testApp(t)
	box := &host{name: "box"}
	a.hosts = append(a.hosts, box)
	a.owner = map[string]*host{"a": box, "s1": box}
	s := &a.st.Sessions[0]
	s.Panes[0].Git = &proto.GitInfo{Root: "/srv/app", Branch: "main", Default: "main"}
	sf := editedDiff(t, a, "/srv/app", "main.go")
	sf.host = "box"
	a.side.changes.files = map[string]*sideFile{"/srv/app|head|main.go": sf}
	if got := a.diffTarget(sf).host; got != "box" {
		t.Fatalf("the diff is of the host %q", got)
	}

	// The session ends: no host has its pane.
	a.owner = map[string]*host{}
	s.Panes = nil
	if ts := a.allTargets(); len(ts) != 0 {
		t.Errorf("the texts with edits to save: %+v", ts)
	}

	var kept unsavedText
	for _, u := range a.backupNow().Unsaved {
		if u.Path == "/srv/app/main.go" {
			kept = u
		}
	}
	if kept.Text != bufferText(sf.d.New) {
		t.Errorf("the edit of the pane gone is not backed up: %+v", kept)
	}
	if kept.Host != "box" || kept.Scope != sf.scope {
		t.Errorf("backed up as %q %q, want box %q", kept.Host, kept.Scope, sf.scope)
	}
}
