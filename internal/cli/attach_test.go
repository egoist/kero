package cli

import (
	"bytes"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/egoist/mygo/plugins/terminal"

	"kero/internal/settings"
)

// nullConn is a terminal's program that does nothing.
type nullConn struct{ closed chan struct{} }

func (c nullConn) Read([]byte) (int, error) {
	<-c.closed
	return 0, bytes.ErrTooLarge
}
func (c nullConn) Write(p []byte) (int, error) { return len(p), nil }
func (c nullConn) Close() error                { return nil }

func newTerm(t *testing.T, cols, rows int) *terminal.Terminal {
	t.Helper()
	closed := make(chan struct{})
	term, err := terminal.New(terminal.Options{Conn: nullConn{closed}, Scrollback: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	term.Resize(cols, rows)
	t.Cleanup(func() { close(closed); term.Close() })
	return term
}

// snapshot is all a terminal shows and is set to, as a new mirror's first
// frame tells it: scrollback, screen, modes, colors, keyboard and cursor.
func snapshot(t *testing.T, term *terminal.Terminal) string {
	t.Helper()
	m, err := term.NewMirror()
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	f, _ := m.Frame()
	return string(f)
}

// frames passes a mirror's frame through the filter to the outer terminal.
func frames(t *testing.T, m *terminal.Mirror, f *frameFilter, outer *terminal.Terminal) (left bool) {
	t.Helper()
	raw, _ := m.Frame()
	out, left := f.feed(raw)
	outer.Feed(out)
	return left
}

func lines(from, to int, prefix string) string {
	var b strings.Builder
	for i := from; i < to; i++ {
		b.WriteString(prefix)
		b.WriteString(strings.Repeat("x", i%7))
		b.WriteString("\r\n")
	}
	return b.String()
}

// A pane shows on the outer terminal, whose own screen, scrollback and
// settings are as they were once it leaves, whatever the pane's program set.
func TestAttachLeavesOuterTerminalAsItWas(t *testing.T) {
	outer := newTerm(t, 80, 24)
	outer.Feed([]byte(lines(0, 200, "shell line ") + "$ kero attach"))
	before, beforeText := snapshot(t, outer), outer.Text()

	pane := newTerm(t, 80, 24)
	pane.Feed([]byte(lines(0, 500, "pane line ")))
	pane.Feed([]byte("\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?1004h\x1b[>1u\x1b[?1h\x1b[6 q\x1b]11;rgb:10/20/30\x1b\\\x1b]2;a title\x1b\\the prompt"))
	m, err := pane.NewMirror()
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	var colored atomic.Bool
	f := frameFilter{rows: 24, colored: &colored}
	outer.Feed([]byte(attachEnter))
	frames(t, m, &f, outer)
	if text := outer.Text(); !strings.Contains(text, "the prompt") {
		t.Fatalf("the pane's screen doesn't show:\n%s", text)
	}
	pane.Feed([]byte("\r\nmore output\r\n"))
	frames(t, m, &f, outer)
	if text := outer.Text(); !strings.Contains(text, "more output") {
		t.Fatalf("the pane's output doesn't show:\n%s", text)
	}
	if !colored.Load() {
		t.Error("a program's color went on untold")
	}
	outer.Feed([]byte(attachLeave(colored.Load())))
	if after := outer.Text(); after != beforeText {
		t.Errorf("the outer terminal's text changed:\n%s\n---\n%s", beforeText, after)
	}
	// All but the title, which a terminal with a stack of titles gets back
	// (attachLeave), as this one has none.
	after := strings.Replace(snapshot(t, outer), "\x1b]2;a title\x1b\\", "", 1)
	if after != before {
		t.Errorf("the outer terminal changed: %d bytes, were %d; ends\n%q\nwas\n%q", len(after), len(before), after[max(0, len(after)-300):], before[max(0, len(before)-300):])
	}
}

// A start's scrollback, as the mirror draws all of it, stays home, while the
// screen shows whole, soft-wrapped lines too.
func TestStartSendsOnlyTheScreen(t *testing.T) {
	pane := newTerm(t, 40, 10)
	pane.Feed([]byte(lines(0, 5000, "history ")))
	pane.Feed([]byte("the last line: " + strings.Repeat("wrapped ", 12) + "end\r\nprompt$ "))
	m, err := pane.NewMirror()
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	raw, _ := m.Frame()

	f := frameFilter{rows: 10}
	var out []byte
	// In pieces, as a large frame's come, and a line break's two bytes apart.
	for i := 0; i < len(raw); i += 997 {
		piece, _ := f.feed(raw[i:min(i+997, len(raw))])
		out = append(out, piece...)
	}
	if len(out) > len(raw)/20 {
		t.Errorf("sent %d bytes of a frame of %d", len(out), len(raw))
	}
	if bytes.Contains(out, []byte("\x1b[3J")) || bytes.Contains(out, []byte("\x1b[?1049")) {
		t.Errorf("the screen's switches or the scrollback's clear went on: %q", out)
	}

	got := newTerm(t, 40, 10)
	got.Feed([]byte(attachEnter))
	got.Feed(out)
	// The lines that show are the last of the pane's, soft wraps undone, and
	// no line of them past what the pane's screen shows.
	shown, all := strings.TrimRight(got.Text(), "\n "), strings.TrimRight(pane.Text(), "\n ")
	if !strings.HasSuffix(all, shown) || !strings.Contains(shown, "the last line:") || strings.Contains(shown, "wrapped  ") {
		t.Errorf("the screen shows\n%s", shown)
	}
	if n := strings.Count(shown, "\n"); n < 2 || n >= 10 {
		t.Errorf("%d lines show, of 10 rows with a line wrapped over 3:\n%s", n+1, shown)
	}
}

// The pane going to its alternate screen draws it whole; coming back, the
// frames draw only what differs from a main screen this terminal doesn't
// keep, so it takes a new start, which then shows it right.
func TestLeavingAlternateScreenStartsOver(t *testing.T) {
	outer := newTerm(t, 40, 10)
	outer.Feed([]byte(attachEnter))
	pane := newTerm(t, 40, 10)
	pane.Feed([]byte("the shell's line\r\n"))
	m, err := pane.NewMirror()
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	f := frameFilter{rows: 10}
	if frames(t, m, &f, outer) {
		t.Fatal("a start took for leaving the alternate screen")
	}
	pane.Feed([]byte("\x1b[?1049h\x1b[Hvim here"))
	if frames(t, m, &f, outer) {
		t.Fatal("taking the alternate screen took for leaving it")
	}
	if text := outer.Text(); !strings.Contains(text, "vim here") || strings.Contains(text, "the shell's line") {
		t.Fatalf("on the alternate screen, the outer terminal shows:\n%s", text)
	}
	pane.Feed([]byte("\x1b[?1049l"))
	if !frames(t, m, &f, outer) {
		t.Fatal("leaving the alternate screen went unnoticed")
	}
	if out, _ := f.feed([]byte("late")); len(out) > 0 {
		t.Errorf("frames went on after leaving it: %q", out)
	}

	f.reset()
	m2, err := pane.NewMirror()
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	if frames(t, m2, &f, outer) {
		t.Fatal("the new start took for leaving the alternate screen")
	}
	if text := outer.Text(); !strings.Contains(text, "the shell's line") || strings.Contains(text, "vim here") {
		t.Errorf("after a new start, the outer terminal shows:\n%s", text)
	}

	// A new start while the pane is on its alternate screen is no leaving
	// either, though it goes through the main one.
	pane.Feed([]byte("\x1b[?1049h\x1b[Hvim again"))
	f.reset()
	m3, err := pane.NewMirror()
	if err != nil {
		t.Fatal(err)
	}
	defer m3.Close()
	if frames(t, m3, &f, outer) {
		t.Fatal("a start on the alternate screen took for leaving it")
	}
	if text := outer.Text(); !strings.Contains(text, "vim again") {
		t.Errorf("the alternate screen doesn't show:\n%s", text)
	}
}

// What the filter lets through and what it keeps from the outer terminal.
func TestFrameFilter(t *testing.T) {
	var colored atomic.Bool
	for _, tt := range []struct {
		name, in, want string
		hold           bool
	}{
		{name: "text", in: "hello", want: "hello"},
		{name: "a sequence's pieces", in: "\x1b[3", want: ""},
		{name: "scrollback's clear", in: "\x1b[3J", want: ""},
		{name: "kept modes", in: "\x1b[?2004h\x1b[?1000h", want: "\x1b[?2004h\x1b[?1000h"},
		{name: "modes it couldn't set back", in: "\x1b[?1007h\x1b[?2027h\x1b[?1036l", want: ""},
		{name: "keyboard", in: "\x1b[=1;1u\x1b[>4;2m", want: "\x1b[=1;1u\x1b[>4;2m"},
		{name: "images", in: "\x1b_Ga=T;AAAA\x1b\\x", want: "x"},
		{name: "pointer shape", in: "\x1b]22;text\x1b\\", want: ""},
		{name: "title", in: "\x1b]2;hi\x1b\\", want: "\x1b]2;hi\x1b\\"},
		{name: "clipboard write", in: "\x1b]52;c;aGk=\x1b\\", want: "\x1b]52;c;aGk=\x1b\\"},
		{name: "clipboard read", in: "\x1b]52;c;?\x1b\\x", want: "x"},
		{name: "color resets, none set", in: "\x1b]110\x1b\\\x1b]104\x1b\\", want: ""},
		{name: "held: what draws", in: "text\x1b[2;3H\x1b[2K\x1b[31m", want: "", hold: true},
		{name: "held: what doesn't", in: "\x1b[?2004h\x1b]2;t\x1b\\\x1b[=1;1u\x1b[2 q", want: "\x1b[?2004h\x1b]2;t\x1b\\\x1b[=1;1u\x1b[2 q", hold: true},
	} {
		f := frameFilter{rows: 10, colored: &colored, hold: tt.hold}
		if out, _ := f.feed([]byte(tt.in)); string(out) != tt.want {
			t.Errorf("%s: %q, want %q", tt.name, out, tt.want)
		}
	}
	f := frameFilter{rows: 10, colored: &colored}
	if out, _ := f.feed([]byte("\x1b]11;rgb:01/02/03\x1b\\\x1b]110\x1b\\")); !bytes.Contains(out, []byte("]110")) {
		t.Errorf("a reset after a color went: %q", out)
	}
	if !strings.Contains(attachLeave(true), "\x1b]111") || strings.Contains(attachLeave(false), "\x1b]111") {
		t.Error("leaving resets the colors unless a program set them")
	}
}

func TestDetachMatcher(t *testing.T) {
	ctrlBackslash := func() *detachMatcher { return &detachMatcher{legacy: 0x1c, code: 92} }
	for _, tt := range []struct {
		name    string
		in      []string
		forward string
		detach  bool
	}{
		{name: "plain keys", in: []string{"hello\r"}, forward: "hello\r"},
		{name: "the control character", in: []string{"ab\x1ccd"}, forward: "ab", detach: true},
		{name: "kitty", in: []string{"a\x1b[92;5u"}, forward: "a", detach: true},
		{name: "kitty press", in: []string{"\x1b[92;5:1u"}, detach: true},
		{name: "kitty repeat", in: []string{"\x1b[92;5:2u"}, detach: true},
		{name: "kitty alternate key", in: []string{"\x1b[92:124;5u"}, detach: true},
		{name: "kitty with text", in: []string{"\x1b[92;5;28u"}, detach: true},
		{name: "kitty with Caps Lock", in: []string{"\x1b[92;69u"}, detach: true},
		{name: "kitty release isn't a press", in: []string{"\x1b[92;5:3u"}, forward: "\x1b[92;5:3u"},
		{name: "another modifier", in: []string{"\x1b[92;6u"}, forward: "\x1b[92;6u"},
		{name: "no modifier", in: []string{"\x1b[92u"}, forward: "\x1b[92u"},
		{name: "another key", in: []string{"\x1b[93;5u"}, forward: "\x1b[93;5u"},
		{name: "modifyOtherKeys", in: []string{"\x1b[27;5;92~"}, detach: true},
		{name: "modifyOtherKeys, another key", in: []string{"\x1b[27;5;93~"}, forward: "\x1b[27;5;93~"},
		{name: "in two reads", in: []string{"\x1b[92", ";5u"}, detach: true},
		{name: "arrow in two reads", in: []string{"\x1b[", "A"}, forward: "\x1b[A"},
		{name: "a lone Escape isn't held", in: []string{"\x1b"}, forward: "\x1b"},
		{name: "pasted", in: []string{"\x1b[200~a\x1cb\x1b[92;5u\x1b[201~"}, forward: "\x1b[200~a\x1cb\x1b[92;5u\x1b[201~"},
		{name: "after a paste", in: []string{"\x1b[200~a\x1b[201~", "\x1c"}, forward: "\x1b[200~a\x1b[201~", detach: true},
		{name: "mouse", in: []string{"\x1b[<0;92;5M"}, forward: "\x1b[<0;92;5M"},
	} {
		m := ctrlBackslash()
		var forward []byte
		detach := false
		for _, in := range tt.in {
			f, d := m.feed([]byte(in))
			forward = append(forward, f...)
			detach = detach || d
		}
		if string(forward) != tt.forward || detach != tt.detach {
			t.Errorf("%s: forwarded %q, detach %v; want %q, %v", tt.name, forward, detach, tt.forward, tt.detach)
		}
	}
	// A terminal's reply ending in BEL is no ctrl+g.
	g := &detachMatcher{legacy: 7, code: 'g'}
	if f, d := g.feed([]byte("\x1b]11;rgb:0/0/0\x07a")); d || string(f) != "\x1b]11;rgb:0/0/0\x07a" {
		t.Errorf("a reply: %q, detach %v", f, d)
	}
	if _, d := g.feed([]byte("\x07")); !d {
		t.Error("ctrl+g after a reply didn't detach")
	}
}

func TestParseDetachKey(t *testing.T) {
	for key, want := range map[string][2]int{`ctrl+\`: {0x1c, 92}, "ctrl+]": {0x1d, 93}, "ctrl+q": {0x11, 'q'}, "CTRL+Q": {0x11, 'q'}} {
		legacy, code, err := settings.ParseDetachKey(key)
		if err != nil || int(legacy) != want[0] || code != want[1] {
			t.Errorf("%s: %#x, %d, %v", key, legacy, code, err)
		}
	}
	for _, key := range []string{"", "q", "alt+q", "ctrl+i", "ctrl+m", "ctrl+j", "ctrl+h", "ctrl+[", "ctrl+qq"} {
		if _, _, err := settings.ParseDetachKey(key); err == nil {
			t.Errorf("%q took for a key", key)
		}
	}
}

// A pane's reads of the clipboard never reach the outer terminal, and get an
// empty answer, so that the program isn't left waiting; writes go on.
func TestFrameFilterRefusesClipboardReads(t *testing.T) {
	for _, tt := range []struct {
		name, in, out string
		refused       []string
	}{
		{name: "read, ST", in: "\x1b]52;c;?\x1b\\", refused: []string{"\x1b]52;c;\x1b\\"}},
		{name: "read, BEL", in: "\x1b]52;c;?\x07", refused: []string{"\x1b]52;c;\x1b\\"}},
		{name: "primary selection", in: "\x1b]52;p;?\x1b\\", refused: []string{"\x1b]52;p;\x1b\\"}},
		{name: "two reads", in: "\x1b]52;c;?\x07\x1b]52;p;?\x07", refused: []string{"\x1b]52;c;\x1b\\", "\x1b]52;p;\x1b\\"}},
		{name: "write", in: "\x1b]52;c;aGk=\x07", out: "\x1b]52;c;aGk=\x07"},
		{name: "clearing", in: "\x1b]52;c;\x07", out: "\x1b]52;c;\x07"},
	} {
		f := frameFilter{rows: 10}
		out, _ := f.feed([]byte(tt.in))
		if string(out) != tt.out {
			t.Errorf("%s: wrote %q, want %q", tt.name, out, tt.out)
		}
		if got := f.takeRefused(); !slices.Equal(got, tt.refused) {
			t.Errorf("%s: refused %q, want %q", tt.name, got, tt.refused)
		}
		if got := f.takeRefused(); got != nil {
			t.Errorf("%s: refused twice: %q", tt.name, got)
		}
	}
	// A read in two pieces is still one read.
	f := frameFilter{rows: 10}
	f.feed([]byte("\x1b]52;c"))
	if out, _ := f.feed([]byte(";?\x1b\\")); len(out) != 0 || len(f.takeRefused()) != 1 {
		t.Errorf("in pieces: wrote %q", out)
	}
}
