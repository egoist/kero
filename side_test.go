package main

import (
	"fmt"
	"image"
	"math"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/git"
	"kero/internal/proto"
)

// A session in a worktree of its own shows its branch by its name, and
// by its pane's title with its changes; Toggle Changes lists what its
// agent changed in its turn in the right sidebar, and their diffs in the
// viewer.
func TestSidePanel(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "fix-login", Default: "main", Head: "0123456789abcdef", Ahead: 2, Files: 3, Added: 40, Removed: 2}
	s.Panes[0].Git = g
	s.Panes[0].Agent, s.Panes[0].Process = "claude", "claude"
	s.Panes[0].Turn = &proto.Turn{Tree: "abc", Root: "/tmp/demo", At: time.Now().UnixMilli()}
	s.Panes[1].Git = g
	s.Pane = s.Panes[0]
	a.toggleSide(sideChanges)

	// What kerod would answer.
	ch := &a.side.changes
	turnScope := changesScope(&s.Panes[0], git.BaseTurn)
	ch.base, ch.scope, ch.stamp = git.BaseTurn, turnScope, gitStamp(g)+"|abc"
	ch.res = &proto.GitChanges{Root: "/tmp/demo", Files: []proto.GitFile{
		{Path: "internal/auth/login.go", Status: "modified", Added: 30, Removed: 2},
		{Path: "internal/auth/login_test.go", Status: "added", Added: 10},
		{Path: "docs/old.md", Status: "deleted", Removed: 12},
	}}
	ch.fetched = time.Now()
	ch.lists = map[string]*proto.GitChanges{}

	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	for _, want := range []string{"fix-login", "Changes", "Last Turn", "Uncommitted", "Branch", "login.go", "login_test.go", "+30", "−2", "3 files"} {
		if !tt.HasText(want) {
			t.Errorf("no %q; texts %q", want, tt.Texts())
		}
	}
	shot(t, tt, "side-list")

	// Another base: the list stays, faded, while its own comes, and one
	// fetched before shows at once.
	ch.base = git.BaseHead
	tt.Frame()
	if !tt.HasText("login.go") {
		t.Errorf("the list blinked away as the base changed; texts %q", tt.Texts())
	}
	tt.Advance(time.Second)
	tt.Frame()
	if tt.HasText("login.go") {
		t.Error("another base's list stayed past a moment")
	}
	ch.lists[turnScope] = ch.res
	ch.base = git.BaseTurn
	tt.Frame()
	if !tt.HasText("login.go") {
		t.Errorf("a list fetched before didn't show at once; texts %q", tt.Texts())
	}

	// Each file is its header, then its diff, in one scroll: none opens
	// on its own.
	sf := ch.files[turnScope+"|internal/auth/login.go"]
	if sf == nil {
		t.Fatal("no diff kept for login.go")
	}
	a.showText(sf, proto.GitText{
		Old:  "package auth\n\nfunc Login(user string) error {\n\treturn nil\n}\n",
		New:  "package auth\n\nimport \"errors\"\n\n// Login signs a user in.\nfunc Login(user, password string) error {\n\tif password == \"\" {\n\t\treturn errors.New(\"no password\")\n\t}\n\treturn nil\n}\n",
		Hash: "h1",
	})
	if test := ch.files[turnScope+"|internal/auth/login_test.go"]; test != nil {
		a.showText(test, proto.GitText{New: "package auth\n\nfunc TestLogin(t *testing.T) {}\n", Hash: "h2"})
	}
	tt.Frame()
	tt.Advance(100 * time.Millisecond)
	tt.Frame()
	for _, want := range []string{"login.go", "login_test.go", "old.md", "auth"} {
		if !tt.HasText(want) {
			t.Errorf("no %q among the files and diffs; texts %q", want, tt.Texts())
		}
	}
	if n := len(sf.d.Hunks()); n == 0 {
		t.Error("the diff shows no changes")
	}
	shot(t, tt, "side-file")

	// The text changing on disk changes the diff in place.
	a.showText(sf, proto.GitText{Old: "package auth\n", New: "package auth\n\n// More.\n", Hash: "h3"})
	if got := sf.d.New.String(); got != "package auth\n\n// More.\n" {
		t.Errorf("the new text is %q", got)
	}

	// Scrolled into a long diff, its file's header stays at the top.
	long := "package auth\n"
	for i := range 120 {
		long += fmt.Sprintf("// line %d\n", i)
	}
	a.showText(sf, proto.GitText{Old: "package auth\n", New: long, Hash: "h4"})
	tt.Frame()
	tt.Frame()
	ls := ch.places[turnScope]
	top, _ := tt.Find("login.go")
	if pinned(tt, ls, "login.go", top.Y) {
		t.Error("login.go's header pinned at the top before any scroll")
	}
	tt.Scroll(top.X, top.Y+100, 0, 600)
	for range 3 {
		tt.Frame()
	}
	if !pinned(tt, ls, "login.go", top.Y) {
		t.Error("scrolled into login.go's diff, its header isn't pinned at the top")
	}
	shot(t, tt, "side-sticky")
	ls.ScrollTo(0, ui.Start)
	for range 3 {
		tt.Frame()
	}
	a.showText(sf, proto.GitText{Old: "package auth\n", New: "package auth\n\n// More.\n", Hash: "h3"})
	tt.Frame()

	// A click on a file's header folds its diff, and another unfolds it.
	hdr, ok := tt.Find("login.go")
	if !ok {
		t.Fatal("no header of login.go")
	}
	tt.ClickAt(hdr.X+hdr.W/2, hdr.Y+hdr.H/2)
	tt.Frame()
	if !a.fileCollapsed(turnScope, ch.res.Files[0]) {
		t.Error("a click didn't fold login.go")
	}
	tt.ClickAt(hdr.X+hdr.W/2, hdr.Y+hdr.H/2)
	tt.Frame()
	if a.fileCollapsed(turnScope, ch.res.Files[0]) {
		t.Error("a second click didn't unfold login.go")
	}
	tt.SetDark(true)
	tt.Frame()
	tt.Advance(time.Second) // colors ease from the light frame's
	tt.Frame()
	shot(t, tt, "side-list-dark")
}

func TestReplaceText(t *testing.T) {
	for _, c := range []struct{ from, to string }{
		{"abc", "abc"}, {"abc", "abXc"}, {"abc", ""}, {"", "x"}, {"héllo", "hállo"}, {"日本語", "日本人語"}, {"aaa", "aa"},
	} {
		b := editor.NewBuffer(c.from)
		replaceText(b, c.to)
		if got := b.String(); got != c.to {
			t.Errorf("%q → %q: got %q", c.from, c.to, got)
		}
	}
}

// Settings' search finds Toggle Changes' shortcut by git and diff, as
// well as by its title.
func TestChangesShortcutSearch(t *testing.T) {
	testApp(t)
	for _, q := range []string{"git", "diff", "changes"} {
		if !slices.Contains(searchResults(q, nil)["keyboard"], "Toggle Changes") {
			t.Errorf("%q doesn't find Toggle Changes: %v", q, searchResults(q, nil))
		}
	}
}

// The command palette offers Toggle Changes, by its title and by git.
func TestChangesInPalette(t *testing.T) {
	for _, q := range []string{"", "toggle changes", "git", "diff"} {
		a := testApp(t)
		a.openPalette()
		a.pal.query = q
		tt := ui.NewTester(a.view, 1100, 2000)
		tt.Frame()
		if !tt.HasText("Toggle Changes") {
			t.Errorf("%q: no Toggle Changes in the palette; texts %q", q, tt.Texts())
		}
	}
	a := testApp(t)
	a.openPalette()
	a.pal.query = "git"
	tt := ui.NewTester(a.view, 1100, 720)
	tt.Frame()
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if v := a.viewOf(&a.st.Sessions[0]); a.prefs.Side != sideChanges || v == nil || v.kind != sideChanges {
		t.Error("choosing it in the palette didn't show the changes and their diffs")
	}
}

// Moving between the panes of one worktree keeps the changes as they
// were, scrolled where they were: the list is the worktree's, not a pane's.
func TestChangesFollowWorktree(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 40, Added: 400}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	if scope != changesScope(&s.Panes[1], git.BaseHead) {
		t.Fatal("two panes of one worktree list different changes")
	}
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo"}
	for i := range 40 {
		ch.res.Files = append(ch.res.Files, proto.GitFile{Path: fmt.Sprintf("f%02d.go", i), Status: "modified", Added: 10})
	}
	ch.fetched = time.Now()
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Frame()
	r, _ := tt.Find("f00.go")
	tt.Scroll(r.X, r.Y, 0, 300)
	tt.Frame()
	switched := ch.switched
	at, _ := tt.Find("f05.go")
	first, _ := ch.places[scope].Visible()

	a.focus[s.ID], s.Focus = "b", "b"
	tt.Frame()
	tt.Frame()
	if ch.shown != scope || ch.switched != switched {
		t.Errorf("focusing the other pane showed another list: %q", ch.shown)
	}
	now, _ := tt.Find("f05.go")
	if f, _ := ch.places[scope].Visible(); f != first || now.Y != at.Y {
		t.Errorf("focusing the other pane scrolled the list from row %d at %v to row %d at %v", first, at.Y, f, now.Y)
	}
}

// pinned reports whether the list pins the header of name at its top, top,
// over its diff scrolled under it: the first row in view is a diff, of a
// list of files all unfolded.
func pinned(tt *ui.Tester, ls *ui.ListState, name string, top float32) bool {
	first, _ := ls.Visible()
	r, ok := tt.Find(name)
	return first%2 == 1 && ok && math.Abs(float64(r.Y-top)) < 1
}

// The header the next file's pushes up from the top goes under the list's
// top edge, never over the viewer's header above the list.
func TestStickyHeaderStaysInList(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 3, Added: 60}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo"}
	for _, n := range []string{"a.go", "b.go", "c.go"} {
		ch.res.Files = append(ch.res.Files, proto.GitFile{Path: n, Status: "added", Added: 20})
	}
	ch.fetched = time.Now()
	tt := ui.NewTester(a.view, 1280, 500)
	tt.Frame()
	for _, f := range ch.res.Files {
		var b strings.Builder
		for i := range 20 {
			fmt.Fprintf(&b, "var %s%d = %d\n", f.Path[:1], i, i)
		}
		a.showText(ch.files[scope+"|"+f.Path], proto.GitText{New: b.String(), Hash: f.Path})
	}
	for range 4 {
		tt.Frame()
	}
	sum, _ := tt.Find("Changes")
	r := image.Rect(int(sum.X), int(sum.Y), int(sum.X+300), int(sum.Y+sum.H))
	base := tt.Image().SubImage(r).(*image.RGBA)
	snap := func() []uint8 { return append([]uint8(nil), base.Pix...) }
	want := snap()
	at, _ := tt.Find("a.go")
	tt.Scroll(at.X, at.Y+100, 0, 290)
	bad := 0
	for y := float32(300); y < 1300; y += 10 {
		tt.Scroll(at.X, at.Y+100, 0, 10)
		tt.Frame()
		tt.Frame()
		got := tt.Image().SubImage(r).(*image.RGBA)
		same := true
		for row := 0; row < r.Dy(); row++ {
			a0 := got.PixOffset(r.Min.X, r.Min.Y+row)
			b0 := base.PixOffset(r.Min.X, r.Min.Y+row)
			if string(got.Pix[a0:a0+r.Dx()*4]) != string(want[b0:b0+r.Dx()*4]) {
				same = false
				break
			}
		}
		if !same {
			bad++
		}
		if y == 400 {
			shot(t, tt, "side-sticky-pushed")
		}
	}
	if bad > 0 {
		t.Errorf("the sticky header covered the viewer's header at %d scroll positions", bad)
	}
}

// Folding the file pinned at the top near the list's end makes the list
// shorter, which then scrolls back to its end: the header of the file
// whose diff runs past the top stays in every frame, never gone for one.
func TestStickyHeaderAsFoldShortensList(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 3, Added: 180}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo"}
	names := []string{"a.go", "b.go", "c.go"}
	for _, n := range names {
		ch.res.Files = append(ch.res.Files, proto.GitFile{Path: n, Status: "added", Added: 60})
	}
	ch.fetched = time.Now()
	var tt *ui.Tester
	var top ui.Rect
	// The file whose header shows at the top of the list.
	atTop := func() string {
		for _, n := range names {
			if r, ok := tt.Find(n); ok && math.Abs(float64(r.Y-top.Y)) < 1 {
				return n
			}
		}
		return ""
	}
	var stuck []string
	recording := false
	tt = ui.NewTester(func(c *ui.Context) {
		if recording {
			stuck = append(stuck, atTop()) // as the frame before showed
		}
		a.view(c)
	}, 1280, 700)
	tt.Frame()
	for _, f := range ch.res.Files {
		var b strings.Builder
		for i := range 60 {
			fmt.Fprintf(&b, "var %s%d = %d\n", f.Path[:1], i, i)
		}
		a.showText(ch.files[scope+"|"+f.Path], proto.GitText{New: b.String(), Hash: f.Path})
	}
	for range 4 {
		tt.Frame()
	}
	top, _ = tt.Find("a.go")
	ch.places[scope].ScrollToEnd()
	for range 4 {
		tt.Frame()
	}
	if f := atTop(); f != "c.go" {
		t.Fatalf("at the end, %q pinned at the top, want c.go", f)
	}
	recording = true
	tt.ClickAt(top.X+top.W/2, top.Y+top.H/2)
	for range 3 {
		tt.Frame()
	}
	recording = false
	stuck = append(stuck, atTop())
	if !a.fileCollapsed(scope, ch.res.Files[2]) {
		t.Fatal("a click on the header at the top didn't fold c.go")
	}
	for i, f := range stuck {
		if f == "" {
			t.Errorf("frame %d of the fold shows no header at the top: %q", i, stuck)
			break
		}
	}
	if f := atTop(); f != "b.go" {
		t.Errorf("folded, %q pinned at the top, want b.go", f)
	}
}

// The tree of the files: their folders, a folder alone in another as
// one, in the diffs' order.
func TestFileTree(t *testing.T) {
	files := []proto.GitFile{
		{Path: "docs/old.md"},
		{Path: "internal/auth/login.go"},
		{Path: "internal/auth/login_test.go"},
		{Path: "main.go"},
	}
	var got []string
	for _, it := range treeItems(fileTree(files), func(string) bool { return false }) {
		got = append(got, strings.Repeat("  ", it.depth)+it.name)
	}
	want := []string{"docs", "  old.md", "internal/auth", "  login.go", "  login_test.go", "main.go"}
	if !slices.Equal(got, want) {
		t.Errorf("the tree is %q, want %q", got, want)
	}
	items := treeItems(fileTree(files), func(dir string) bool { return dir == "internal/auth" })
	if len(items) != 4 || items[2].open {
		t.Errorf("a closed folder shows its files: %v", items)
	}
}

// The Changes tab lists the files in their folders, without opening the
// viewer: a click on a file opens it on the diffs, scrolled to the file,
// which the tree then shows as the one there, and one on a folder folds
// it.
func TestChangesTree(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 40, Added: 400}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideChanges
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo"}
	for i := range 40 {
		ch.res.Files = append(ch.res.Files, proto.GitFile{Path: fmt.Sprintf("pkg/d%d/f%02d.go", i/10, i), Status: "modified", Added: 10})
	}
	ch.fetched = time.Now()
	tt := ui.NewTester(a.view, 1280, 1200)
	tt.Frame()
	tt.Frame()
	if _, ok := tt.Find("d0"); !ok {
		t.Fatalf("the tree didn't show; texts %q", tt.Texts())
	}
	if a.viewOf(s) != nil {
		t.Fatal("the viewer opened with the tab")
	}
	shot(t, tt, "side-tree")

	if err := tt.Click("f12.go"); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if v := a.viewOf(s); v == nil || v.kind != sideChanges {
		t.Fatal("a click on a file didn't open the diffs")
	}
	if first, _ := ch.places[scope].Visible(); first == 0 {
		t.Error("the diffs didn't open scrolled to the file")
	}
	if ch.current != "pkg/d1/f12.go" {
		t.Errorf("after a click on f12.go the tree shows %q as the file there", ch.current)
	}
	shot(t, tt, "side-tree-diffs")

	if err := tt.Click("d2"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !ch.treeClosed[scope+"|pkg/d2"] {
		t.Error("a click on a folder didn't fold it")
	}
}

// Collapse All folds every file's diff, keeping the file at the top
// there, and Expand All, which takes its place, unfolds them all.
func TestFoldAllFiles(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 40, Added: 400}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp/demo"}
	for i := range 40 {
		ch.res.Files = append(ch.res.Files, proto.GitFile{Path: fmt.Sprintf("f%02d.go", i), Status: "modified", Added: 10})
	}
	ch.fetched = time.Now()
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Frame()
	r, _ := tt.Find("f00.go")
	tt.Scroll(r.X, r.Y, 0, 600)
	tt.Frame()
	first, _ := ch.places[scope].Visible()
	top := ch.res.Files[first/2].Path

	if err := tt.Click("Collapse All"); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	for _, f := range ch.res.Files {
		if !a.fileCollapsed(scope, f) {
			t.Fatalf("%s stayed unfolded", f.Path)
		}
	}
	if first, _ := ch.places[scope].Visible(); ch.res.Files[first].Path != top {
		t.Errorf("folding all put %s at the top, not %s", ch.res.Files[first].Path, top)
	}
	tt.Advance(time.Second)
	tt.Frame()
	shot(t, tt, "side-folded")

	if err := tt.Click("Expand All"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	for _, f := range ch.res.Files {
		if a.fileCollapsed(scope, f) {
			t.Fatalf("%s stayed folded", f.Path)
		}
	}
	if _, ok := tt.Find("Collapse All"); !ok {
		t.Error("Collapse All didn't come back with the diffs unfolded")
	}
}

// A pane just split from another has no worktree until kerod looks at
// it: meanwhile the sidebar keeps the worktree its directory is in, its
// changes listed and its base chosen, and its files.
func TestSplitKeepsSidebar(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp", Branch: "main", Default: "main", Files: 1, Added: 3}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.toggleSide(sideChanges)
	ch := &a.side.changes
	scope := changesScope(&s.Panes[0], git.BaseHead)
	ch.base, ch.scope, ch.stamp = git.BaseHead, scope, gitStamp(g)
	ch.res = &proto.GitChanges{Root: "/tmp", Files: []proto.GitFile{{Path: "main.go", Status: "modified", Added: 3}}}
	ch.fetched = time.Now()
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()

	s.Panes = append(s.Panes, proto.Pane{ID: "c", Shell: "zsh", Dir: "/tmp/sub", Status: proto.Idle, Progress: -1})
	s.Layout = s.Layout.Split("b", "c", "down", 0)
	s.Focus = "c"
	for range 3 {
		tt.Frame()
		if tt.HasText("Not a git repository") || !tt.HasText("main.go") {
			t.Fatalf("the split pane emptied the changes; texts %q", tt.Texts())
		}
	}
	if ch.base != git.BaseHead {
		t.Errorf("the split pane changed the base to %q", ch.base)
	}
	if p, root := a.filesRoot(s); p == nil || p.ID != "c" || root != "/tmp" {
		t.Errorf("the split pane's files are of %q", root)
	}

	// Outside every pane's worktree, it is none.
	s.Panes[2].Dir = "/elsewhere"
	if p := withGit(s, &s.Panes[2]); p.Git != nil {
		t.Error("a pane outside the worktrees took one")
	}
}

func TestWithinDir(t *testing.T) {
	for _, c := range []struct {
		dir, root string
		want      bool
	}{
		{"/a/b", "/a/b", true}, {"/a/b/c", "/a/b", true}, {"/a/bc", "/a/b", false}, {"/a", "/a/b", false},
		{`C:\code\kero\x`, `C:\code\kero`, true}, {`C:\code\kerox`, `C:\code\kero`, false}, {"/a/b", "/a/b/", true},
	} {
		if got := withinDir(c.dir, c.root); got != c.want {
			t.Errorf("withinDir(%q, %q) = %v", c.dir, c.root, got)
		}
	}
}
