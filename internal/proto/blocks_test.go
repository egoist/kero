package proto

import (
	"reflect"
	"strings"
	"testing"
)

func TestMatchBlocks(t *testing.T) {
	text := "old output\n❯ ls\na\nb\n❯ make\nfail\n❯ ls\nc\n❯ \n"
	cases := []struct {
		name  string
		lines []string
		want  []int
	}{
		{"in order", []string{"❯ ls", "❯ make", "❯ ls"}, []int{1, 4, 6}},
		// The first run of ls went with the scrollback: the line it was on
		// is the second's.
		{"one gone at the top", []string{"gone", "❯ make", "❯ ls"}, []int{-1, 4, 6}},
		// One overwritten between others costs only that one.
		{"one gone in the middle", []string{"❯ ls", "gone", "❯ ls"}, []int{1, -1, 6}},
		{"none", nil, []int{}},
		{"all gone", []string{"x", "y"}, []int{-1, -1}},
	}
	for _, c := range cases {
		if got := MatchBlocks(text, c.lines); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
	// A long line is found by what a block keeps of it.
	long := strings.Repeat("x", MaxBlockLine+50)
	if got := MatchBlocks("a\n"+long+"\nb", []string{ClipLine(long)}); got[0] != 1 {
		t.Errorf("a long line: %v", got)
	}
}

func TestClipLine(t *testing.T) {
	s := strings.Repeat("a", MaxBlockLine-1) + "界"
	if got := ClipLine(s); got != strings.Repeat("a", MaxBlockLine-1) {
		t.Errorf("cut inside a rune: %q", got[MaxBlockLine-3:])
	}
	if ClipLine("short") != "short" {
		t.Error("a short line changed")
	}
}

func TestLastLine(t *testing.T) {
	for _, c := range []struct {
		text string
		i    int
		line string
	}{
		{"", -1, ""},
		{"\n\n  \n", -1, ""},
		{"one", 0, "one"},
		{"one\ntwo\n\n\n", 1, "two"},
	} {
		if i, l := LastLine(c.text); i != c.i || l != c.line {
			t.Errorf("LastLine(%q) = %d, %q", c.text, i, l)
		}
	}
}

func TestWrappedRows(t *testing.T) {
	for _, c := range []struct {
		line string
		cols int
		want int
	}{
		{"", 10, 1},
		{"short", 10, 1},
		{strings.Repeat("a", 10), 10, 1},
		{strings.Repeat("a", 11), 10, 2},
		{strings.Repeat("a", 21), 10, 3},
		// A wide rune that doesn't fit the last column goes to the next row.
		{strings.Repeat("a", 9) + "界界", 10, 2},
		{strings.Repeat("界", 5), 10, 1},
		{strings.Repeat("界", 6), 10, 2},
		// Marks and joiners take no cells.
		{"ééé", 3, 1},
		{"👩‍💻👩‍💻", 4, 1},
	} {
		if got := WrappedRows(c.line, c.cols); got != c.want {
			t.Errorf("WrappedRows(%q, %d) = %d, want %d", c.line, c.cols, got, c.want)
		}
	}
}

func TestLocateRows(t *testing.T) {
	text := "aaaa\n" + strings.Repeat("b", 25) + "\ncc\ndd"
	got := LocateRows(text, 10, []int{0, 1, 2, 3, 9})
	if want := []int{0, 1, 4, 5, -1}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestBlockOutput(t *testing.T) {
	text := "❯ one\na\nb\n\n❯ two\nc\n❯ "
	for _, c := range []struct {
		line, count, before int
		want                string
	}{
		{0, 2, -1, "a\nb"},
		{0, 3, -1, "a\nb"}, // blank lines at its end go
		{0, 0, -1, ""},
		{0, -1, 4, "a\nb"},
		{4, 1, -1, "c"},
		{4, -1, -1, "c\n❯ "},
	} {
		if got := BlockOutput(text, c.line, c.count, c.before); got != c.want {
			t.Errorf("BlockOutput(%d, %d, %d) = %q, want %q", c.line, c.count, c.before, got, c.want)
		}
	}
}
