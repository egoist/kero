package main

import (
	"fmt"
	"image"
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
// by its pane's title with its changes; the changes panel lists what its
// agent changed in its turn, and opens a file as its diff.
func TestSidePanel(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "fix-login", Default: "main", Head: "0123456789abcdef", Ahead: 2, Files: 3, Added: 40, Removed: 2}
	s.Panes[0].Git = g
	s.Panes[0].Agent, s.Panes[0].Process = "claude", "claude"
	s.Panes[0].Turn = &proto.Turn{Tree: "abc", Root: "/tmp/demo", At: time.Now().UnixMilli()}
	s.Panes[1].Git = g
	s.Pane = s.Panes[0]
	a.prefs.Side = sideChanges

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
	if ch.stuck != "" {
		t.Errorf("%s stuck at the top before any scroll", ch.stuck)
	}
	ch.scrolls[turnScope].Y = 600
	for range 3 {
		tt.Frame()
	}
	if ch.stuck != "internal/auth/login.go" {
		t.Errorf("scrolled into login.go's diff, %q stuck at the top", ch.stuck)
	}
	shot(t, tt, "side-sticky")
	ch.scrolls[turnScope].Y = 0
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

// Settings' search finds the changes panel's shortcut by git and diff, as
// well as by its title.
func TestChangesShortcutSearch(t *testing.T) {
	testApp(t)
	for _, q := range []string{"git", "diff", "changes"} {
		if !slices.Contains(searchResults(q, nil)["keyboard"], "Toggle Changes") {
			t.Errorf("%q doesn't find Toggle Changes: %v", q, searchResults(q, nil))
		}
	}
}

// The command palette offers the changes panel, by its title and by git.
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
	if a.prefs.Side != sideChanges {
		t.Error("choosing it in the palette didn't open the changes panel")
	}
}

// Moving between the panes of one worktree keeps the changes as they
// were, scrolled where they were: the list is the worktree's, not a pane's.
func TestChangesFollowWorktree(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 40, Added: 400}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideChanges
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
	ch.scrolls[scope].Y = 300
	tt.Frame()
	switched := ch.switched

	a.focus[s.ID], s.Focus = "b", "b"
	tt.Frame()
	tt.Frame()
	if ch.shown != scope || ch.switched != switched {
		t.Errorf("focusing the other pane showed another list: %q", ch.shown)
	}
	if y := ch.scrolls[scope].Y; y != 300 {
		t.Errorf("focusing the other pane scrolled the list to %v, from 300", y)
	}
}

// The header the next file's pushes up from the top goes under the list's
// top edge, never over the summary above the list.
func TestStickyHeaderStaysInList(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	g := &proto.GitInfo{Root: "/tmp/demo", Branch: "main", Default: "main", Files: 3, Added: 60}
	s.Panes[0].Git, s.Panes[1].Git = g, g
	a.prefs.Side = sideChanges
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
	sum, _ := tt.Find("3 files")
	r := image.Rect(int(sum.X), int(sum.Y), int(sum.X+300), int(sum.Y+sum.H))
	base := tt.Image().SubImage(r).(*image.RGBA)
	snap := func() []uint8 { return append([]uint8(nil), base.Pix...) }
	want := snap()
	bad := 0
	for y := float32(300); y < 1300; y += 10 {
		ch.scrolls[scope].Y = y
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
		t.Errorf("the sticky header covered the summary at %d scroll positions", bad)
	}
}
