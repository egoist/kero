package main

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestLastLines(t *testing.T) {
	for _, c := range []struct {
		text string
		n    int
		want string
	}{
		{"", 24, ""},
		{"  \n\n", 24, ""},
		{"a\nb\nc\n\n", 0, ""},
		{"a\nb\nc\n\n", 2, "b\nc"},
		{"a\nb\nc", 5, "a\nb\nc"},
		{"\nb", 1, "b"},
		{"\nb", 2, "b"},
	} {
		if got := lastLines(c.text, c.n); got != c.want {
			t.Errorf("lastLines(%q, %d) = %q, want %q", c.text, c.n, got, c.want)
		}
	}
}

// A new pane's terminal has the keyboard while its screen is still
// blank: showing it to assistive technology must not take the app down.
func TestFocusedBlankTerminal(t *testing.T) {
	a, _, _ := pasteApp(t)
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	a.paneRef("a").Focus()
	tt.Frame()
	tt.Frame()
}
