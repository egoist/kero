package main

import (
	"strings"
	"testing"

	"github.com/egoist/mygo/plugins/terminal"
)

func TestAppScrollback(t *testing.T) {
	const cap = 256 << 10
	cases := []struct{ limit, want int }{
		{-1, -1},
		{0, -1}, // 0 would be the terminal's own default, 10 MB
		{1, 1},
		{cap, cap},
		{cap + 1, cap},
		{4 << 20, cap},
	}
	for _, c := range cases {
		if got := appScrollback(c.limit); got != c.want {
			t.Errorf("appScrollback(%d) = %d, want %d", c.limit, got, c.want)
		}
	}
}

func TestHistLines(t *testing.T) {
	got := histLines("a \nb \n\n")
	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("lines %q, want the two with their trailing spaces gone", got)
	}
	if histLines(" \n") != nil {
		t.Fatal("a blank history counted as a line")
	}
}

func TestPageHits(t *testing.T) {
	lines := []string{"err", "ok", "err err", "no"}
	hits := pageHits(lines, "err", 10)
	want := []histHit{{back: 11, n: 1}, {back: 11, n: 0}, {back: 13, n: 0}}
	if len(hits) != len(want) {
		t.Fatalf("hits %v, want %v", hits, want)
	}
	for i := range want {
		if hits[i] != want[i] {
			t.Errorf("hit %d = %+v, want %+v", i, hits[i], want[i])
		}
	}
	// The case of ASCII letters is ignored, and no other letters are.
	if n := countFolded("Error", "error"); n != 1 {
		t.Errorf("Error matched %d times, want 1", n)
	}
	if n := countFolded("Érror", "érror"); n != 0 {
		t.Errorf("a letter outside ASCII matched %d times", n)
	}
}

func TestHistOrigin(t *testing.T) {
	if got := histOrigin(100, 24); got != 88 {
		t.Errorf("a match 100 back on a page of 24 ends at %d, want 88", got)
	}
	if got := histOrigin(3, 24); got != 0 {
		t.Errorf("a match near the newest ends at %d, want the newest", got)
	}
}

func TestMoveFind(t *testing.T) {
	cases := []struct {
		name             string
		c                findCursor
		sel, local, deep int
		searching, back  bool
		want             findAction
	}{
		{"next local", findCursor{}, 1, 4, 2, false, false, findAction{step: 1}},
		{"into history at the oldest local", findCursor{}, 4, 4, 2, false, false, findAction{in: true, edge: 4}},
		{"wait at the end while the history is searched", findCursor{}, 4, 4, 0, true, false, findAction{}},
		{"wrap when there is no older history", findCursor{}, 4, 4, 0, false, false, findAction{step: 1}},
		{"previous stays local", findCursor{}, 3, 4, 2, false, true, findAction{step: -1}},
		{"previous from the newest enters the oldest history", findCursor{}, 1, 4, 2, false, true, findAction{in: true, deep: 1, edge: 1}},
		{"next history match", findCursor{in: true, edge: 4}, 4, 4, 2, false, false, findAction{in: true, deep: 1, edge: 4}},
		{"next wraps back to the newest local", findCursor{in: true, deep: 1, edge: 4}, 4, 4, 2, false, false, findAction{step: 1}},
		{"next back to a newest already selected", findCursor{in: true, deep: 1, edge: 1}, 1, 4, 2, false, false, findAction{}},
		{"previous returns to the oldest local", findCursor{in: true, edge: 4}, 4, 4, 2, false, true, findAction{}},
		{"previous wraps to the oldest local", findCursor{in: true, deep: 0, edge: 1}, 1, 4, 2, false, true, findAction{step: -1}},
		{"history only wraps", findCursor{in: true, deep: 1}, 0, 0, 2, false, false, findAction{in: true}},
		{"no matches", findCursor{}, 0, 0, 0, false, false, findAction{}},
	}
	for _, c := range cases {
		got := moveFind(c.c, c.sel, c.local, c.deep, c.searching, c.back)
		if got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

// A page of history replaces the one the overlay showed, rather than
// appending to it: the terminal keeps none of its own scrollback.
func TestHistFeed(t *testing.T) {
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	a.feedHist("old line\r\n", 24)
	term := a.find.hist.term
	if term == nil {
		t.Fatal("no terminal for the page")
	}
	t.Cleanup(func() { a.closeHistView() })
	a.feedHist("new line\r\n", 24)
	if term != a.find.hist.term {
		t.Fatal("a new page built a new terminal")
	}
	text := term.Text()
	if !strings.Contains(text, "new line") || strings.Contains(text, "old line") {
		t.Fatalf("the page shows %q, want only the new line", text)
	}
}
