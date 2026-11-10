package proto

import (
	"strings"
	"testing"
)

func scan(text, query string) []SearchMatch {
	var out []SearchMatch
	ScanMatches(text, query, nil, func(m SearchMatch) bool {
		out = append(out, m)
		return true
	})
	return out
}

// Matches come as a pane's find goes through them: from the end of the text,
// a line's from its end, overlapping ones too, whatever the case of ASCII
// letters, and of no other's.
func TestScanMatches(t *testing.T) {
	got := scan("foo\nnot here\nFOO bar foo\n", "fOo")
	want := []struct {
		line  string
		start int
	}{{"FOO bar foo", 8}, {"FOO bar foo", 0}, {"foo", 0}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i, w := range want {
		if got[i].Line != w.line || got[i].Start != w.start || got[i].End != w.start+3 || got[i].Newer != i {
			t.Errorf("match %d: %+v, want %+v", i, got[i], w)
		}
	}
	if n := len(scan("aaaa\n", "aa")); n != 3 {
		t.Errorf("%d overlapping matches of aa in aaaa", n)
	}
	if n := len(scan("ÉCOLE école\n", "école")); n != 1 {
		t.Errorf("%d matches of école: only ASCII's case is ignored", n)
	}
	if n := len(scan("a\nb\n", "a\nb")); n != 0 {
		t.Errorf("%d matches across lines", n)
	}
	if n := len(scan("anything\n", "")); n != 0 {
		t.Errorf("%d matches of nothing", n)
	}
	if n := len(scan("", "x")); n != 0 {
		t.Errorf("%d matches in nothing", n)
	}
}

// A very long line keeps the part around its match, and its offsets count.
func TestScanMatchesLongLine(t *testing.T) {
	line := strings.Repeat("好", 5000) + "needle" + strings.Repeat("x", 5000)
	got := scan(line+"\n", "NEEDLE")
	if len(got) != 1 {
		t.Fatalf("%d matches", len(got))
	}
	m := got[0]
	if len(m.Line) > 1000 || m.Line[m.Start:m.End] != "needle" {
		t.Errorf("line %d bytes, match %q", len(m.Line), m.Line[m.Start:m.End])
	}
	if !strings.HasPrefix(m.Line, "…好") || !strings.HasSuffix(m.Line, "x…") {
		t.Errorf("not cut by an ellipsis on either side: %q", m.Line)
	}
}

// stop ends a scan; visit too.
func TestScanMatchesStops(t *testing.T) {
	text := strings.Repeat("hit\n", 20000)
	n := 0
	ScanMatches(text, "hit", func() bool { return n > 0 }, func(SearchMatch) bool {
		n++
		return true
	})
	if n == 0 || n >= 20000 {
		t.Errorf("stop let %d matches through", n)
	}
	n = 0
	ScanMatches(text, "hit", nil, func(SearchMatch) bool {
		n++
		return n < 3
	})
	if n != 3 {
		t.Errorf("visit went on to %d matches", n)
	}
}

// A match is found again as output goes on below it and the oldest goes;
// one whose line has gone is not.
func TestLocateMatch(t *testing.T) {
	text := "old hit\nthe hit a\nnoise\nthe hit b\n"
	m := scan(text, "hit")[1] // "the hit a"
	if m.Line != "the hit a" || m.Newer != 1 {
		t.Fatalf("match %+v", m)
	}
	cases := []struct {
		name, text string
		newer      int
		ok         bool
	}{
		{"as it was", text, 1, true},
		{"output since", text + "another hit\nyet another hit\n", 3, true},
		{"the oldest gone", "the hit a\nnoise\nthe hit b\n", 1, true},
		{"a redraw took a newer one", "the hit a\nnoise\n", 0, true},
		{"gone from the scrollback", "noise\nthe hit b\n", 0, false},
	}
	for _, c := range cases {
		newer, ok := LocateMatch(c.text, "hit", m)
		if ok != c.ok || ok && newer != c.newer {
			t.Errorf("%s: %d %v, want %d %v", c.name, newer, ok, c.newer, c.ok)
		}
	}
	// Of the same line many times, the one as far down as it was at least.
	same := "same hit\nsame hit\nsame hit\n"
	m = scan(same, "hit")[1]
	if newer, ok := LocateMatch(same+"same hit\n", "hit", m); !ok || newer != 1 {
		t.Errorf("repeated: %d %v", newer, ok)
	}
}
