package main

import (
	"strings"
	"testing"
	"unsafe"

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

// The text of a screen is held as long as the app shows it. The text a
// terminal gives holds its whole scrollback, so the screen's lines are
// copied out of it: a slice of it would keep the scrollback alive too.
func TestLastLinesDoesNotPinTheScrollback(t *testing.T) {
	scrollback := strings.Repeat("an old line\n", 10000) + "the newest line\n"
	got := lastLines(scrollback, 1)
	if got != "the newest line" {
		t.Fatalf("lastLines = %q", got)
	}
	p := uintptr(unsafe.Pointer(unsafe.StringData(got)))
	q := uintptr(unsafe.Pointer(unsafe.StringData(scrollback)))
	if p >= q && p < q+uintptr(len(scrollback)) {
		t.Error("the screen's text is a slice of the terminal's text")
	}
}

func BenchmarkLastLines(b *testing.B) {
	scrollback := strings.Repeat("an old line\n", 200000) + "the newest line\n"
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		_ = lastLines(scrollback, 24)
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
