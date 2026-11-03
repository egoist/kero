package cli

import (
	"bytes"
	"slices"
	"strings"
	"sync/atomic"
)

// frameFilter makes a pane's frames (terminal.Mirror, proto.FrameOutput)
// fit for a terminal kero attach only borrows. They are written for a
// terminal that is the pane's alone: each start clears its main screen and
// its scrollback and draws all of the pane's scrollback, and they set modes
// nothing here could set back. So that the shell attach was run from stays
// as it was, the pane shows on the alternate screen, and of the frames:
//
//   - the alternate screen's switches go: both of the pane's screens show
//     on the one of the outer terminal (left tells when that takes a new
//     start);
//   - the outer terminal's scrollback is not cleared;
//   - of a start's scrollback, only the rows it takes to fill the screen go
//     on, which over SSH from a phone is most of what attaching would send;
//   - only modes attachLeave sets back go on, and only colors and titles,
//     links and writes to the clipboard of the other strings. Images go:
//     they are the pixels of what may be megabytes. Reads of the clipboard
//     stay here too, for the caller to refuse (takeRefused): a program in a
//     pane has no business with the clipboard of whatever phone or machine
//     attached to it.
//
// It reads the frames as VT sequences, whatever their pieces.
type frameFilter struct {
	rows int // the pane's
	// hold keeps back what draws, while the pane is of another size than
	// the outer terminal, in which it would make no sense.
	hold bool
	// colored tells that a program's colors went on, which leaving resets;
	// else the outer terminal's own are left alone, as a shell's palette.
	colored *atomic.Bool

	pend    []byte // a sequence not yet whole
	out     bytes.Buffer
	alt     bool // the pane shows its alternate screen
	drew    bool // anything drew since it took it
	left    bool // the frames left it: nothing more makes sense until a new start
	cleared bool // the last sequence erased the screen

	// A start's rows, while dumping: the last rows of them, each up to a
	// hard line break, and the one being read.
	dumping bool
	lines   [][]byte
	line    []byte

	// refused are the replies owed to the program for reads of the clipboard
	// that did not go on.
	refused []string
}

// takeRefused returns what to answer the program with, for the reads of the
// clipboard feed kept back: it would wait for an answer that never comes.
func (f *frameFilter) takeRefused() []string {
	r := f.refused
	f.refused = nil
	return r
}

// reset readies the filter for a new stream, whose first frame starts over.
func (f *frameFilter) reset() {
	*f = frameFilter{rows: f.rows, hold: f.hold, colored: f.colored}
}

// feed returns what to write of p. left reports that the pane went back
// from its alternate screen to its main one: the frames then draw only what
// differs from what the main screen showed, which this terminal no longer
// does. The caller attaches again, for a new start.
func (f *frameFilter) feed(p []byte) (out []byte, left bool) {
	if f.left {
		return nil, false
	}
	data := p
	if len(f.pend) > 0 {
		data = append(f.pend, p...)
		f.pend = nil
	}
	f.out.Reset()
	for i := 0; i < len(data) && !f.left; {
		if data[i] != 0x1b {
			j := i + 1
			if k := bytes.IndexByte(data[j:], 0x1b); k >= 0 {
				j += k
			} else {
				j = len(data)
			}
			// A line break can come in two pieces.
			if f.dumping && j == len(data) && data[j-1] == '\r' {
				f.pend = []byte{'\r'}
				j--
			}
			f.text(data[i:j])
			if f.pend != nil {
				break
			}
			i = j
			continue
		}
		n := sequenceLen(data[i:])
		if n == 0 {
			f.pend = slices.Clone(data[i:])
			break
		}
		f.sequence(data[i : i+n])
		i += n
	}
	return slices.Clone(f.out.Bytes()), f.left
}

// sequenceLen returns the length of the escape sequence b starts with, 0
// when it isn't whole yet.
func sequenceLen(b []byte) int {
	if len(b) < 2 {
		return 0
	}
	switch b[1] {
	case '[':
		for i := 2; i < len(b); i++ {
			if b[i] < 0x20 || b[i] >= 0x40 {
				return i + 1
			}
		}
		return 0
	case ']', '_', 'P', '^', 'X':
		for i := 2; i < len(b); i++ {
			if b[i] == 7 && b[1] == ']' {
				return i + 1
			}
			if b[i] == 0x1b && i+1 < len(b) && b[i+1] == '\\' {
				return i + 2
			}
		}
		return 0
	}
	for i := 1; i < len(b); i++ {
		if b[i] < 0x20 || b[i] > 0x2f {
			return i + 1
		}
	}
	return 0
}

func (f *frameFilter) text(b []byte) {
	f.cleared = false
	if len(b) == 0 {
		return
	}
	f.drew = true
	if !f.dumping {
		if !f.hold {
			f.out.Write(b)
		}
		return
	}
	for {
		before, after, broke := bytes.Cut(b, []byte("\r\n"))
		f.line = append(f.line, before...)
		if !broke {
			return
		}
		f.lines = append(f.lines, f.line)
		f.line = nil
		// Each line takes at least a row, so the last rows of them fill the
		// screen.
		if n := len(f.lines) - max(f.rows, 1); n > 0 {
			f.lines = slices.Delete(f.lines, 0, n)
		}
		b = after
	}
}

// endDump ends a start's rows: what shows of them goes out, from the top,
// its rows that don't fit going off it.
func (f *frameFilter) endDump() {
	if !f.dumping {
		return
	}
	f.dumping = false
	lines := append(f.lines, f.line)
	if n := len(lines) - max(f.rows, 1); n > 0 {
		lines = lines[n:]
	}
	if !f.hold {
		f.out.WriteString("\x1b[H")
		f.out.Write(bytes.Join(lines, []byte("\r\n")))
	}
	f.lines, f.line = nil, nil
}

func (f *frameFilter) sequence(tok []byte) {
	wasCleared := f.cleared
	f.cleared = false
	switch tok[1] {
	case '[':
		f.csi(tok, wasCleared)
	case ']':
		f.osc(tok)
	case '_', 'P', '^', 'X':
		f.endDump()
	default:
		f.endDump()
		if !f.hold {
			f.out.Write(tok)
		}
	}
}

func (f *frameFilter) csi(tok []byte, wasCleared bool) {
	body, final := string(tok[2:len(tok)-1]), tok[len(tok)-1]
	if rest, ok := strings.CutPrefix(body, "?"); ok {
		f.endDump()
		f.privateModes(rest, final)
		return
	}
	// The keyboard's (=, >) and the cursor's shape (a space before the
	// final): state, and no drawing.
	if strings.HasPrefix(body, "=") || strings.HasPrefix(body, ">") || strings.ContainsAny(body, " !\"#$%&'()*+,-./") {
		f.endDump()
		f.out.Write(tok)
		return
	}
	switch {
	case final == 'J' && body == "3":
		// The outer terminal's scrollback stays. After the screen's erase,
		// it's a start: its rows follow.
		if wasCleared {
			f.dumping = true
		}
		return
	case final == 'J' && body == "2":
		f.endDump()
		f.cleared = true
	case f.dumping && (final == 'm' || final == 'K'):
		f.line = append(f.line, tok...)
		return
	case f.dumping && final == 'H' && body == "":
		return // endDump draws from the top
	default:
		f.endDump()
	}
	if final == 'H' {
		f.drew = true
	}
	if !f.hold {
		f.out.Write(tok)
	}
}

// attachModes are the private modes that go on to the outer terminal, each
// of which attachLeave sets back. Those it could only guess the setting
// of, as the alternate scroll's and the graphemes', stay the outer
// terminal's own.
var attachModes = map[string]bool{
	"1": true, "5": true, "25": true, "66": true, // the cursor keys, reverse video, the cursor, the keypad
	"1004": true, "2004": true, // focus reports, bracketed paste
	"9": true, "1000": true, "1002": true, "1003": true, // the mouse's events
	"1005": true, "1006": true, "1015": true, "1016": true, // and format
}

func (f *frameFilter) privateModes(params string, final byte) {
	for _, m := range strings.Split(params, ";") {
		switch {
		case m == "1049" && final == 'h':
			f.alt, f.drew = true, false
		case m == "1049" && final == 'l':
			// A start goes through it, drawing nothing on the way, to clear
			// both screens; otherwise the pane left its alternate screen.
			if f.alt && f.drew {
				f.left = true
				return
			}
			f.alt = false
		case attachModes[m] && (final == 'h' || final == 'l'):
			f.out.WriteString("\x1b[?" + m + string(final))
		}
	}
}

func (f *frameFilter) osc(tok []byte) {
	body := tok[2:]
	code, _, _ := bytes.Cut(body, []byte(";"))
	code = bytes.TrimRight(code, "\x07\x1b\\")
	switch string(code) {
	case "8": // a link, within a row
		if f.dumping {
			f.line = append(f.line, tok...)
		} else if !f.hold {
			f.out.Write(tok)
		}
		return
	case "52":
		f.endDump()
		if sel, read := clipboardRead(body); read {
			f.refused = append(f.refused, "\x1b]52;"+sel+";\x1b\\")
		} else {
			f.out.Write(tok)
		}
	case "0", "1", "2":
		f.endDump()
		f.out.Write(tok)
	case "4", "10", "11", "12":
		f.endDump()
		if f.colored != nil {
			f.colored.Store(true)
		}
		f.out.Write(tok)
	case "104", "110", "111", "112":
		f.endDump()
		if f.colored != nil && f.colored.Load() {
			f.out.Write(tok)
		}
	default:
		f.endDump()
	}
}

// clipboardRead tells whether the body of an OSC 52 asks for the clipboard's
// contents, and of which selection, rather than setting them.
func clipboardRead(body []byte) (sel string, read bool) {
	body = bytes.TrimRight(body, "\x07\x1b\\")
	parts := bytes.SplitN(body, []byte(";"), 3)
	if len(parts) != 3 || !bytes.Equal(parts[2], []byte("?")) {
		return "", false
	}
	return string(parts[1]), true
}

// attachEnter takes the outer terminal for the pane, keeping the title and
// the screen attachLeave gives back.
const attachEnter = "\x1b[22;2t\x1b[?1049h\x1b[H\x1b[2J"

// attachLeave gives the outer terminal back: what frameFilter lets a pane
// change set back, on the alternate screen, whose keyboard flags are its
// own, then the screen and the title as they were.
func attachLeave(colored bool) string {
	s := "\x1b[0m\x1b[=0;1u\x1b[>4m"
	for _, m := range []string{"9", "1000", "1002", "1003", "1005", "1006", "1015", "1016", "1004", "2004", "1", "66", "5"} {
		s += "\x1b[?" + m + "l"
	}
	s += "\x1b[0 q\x1b[?25h"
	if colored {
		s += "\x1b]104\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\"
	}
	return s + "\x1b[?1049l\x1b[23;2t"
}

// detachMatcher finds the detach key in what the outer terminal sends: as
// its control character, or as the keyboard protocols the pane's program may
// have turned on send it, which is how Claude Code's and Codex's keyboards
// send it. What is pasted, and the terminal's own replies, are not keys.
type detachMatcher struct {
	legacy byte
	code   int // its key's in the keyboard protocols, as 92 for ctrl+\

	pend  []byte // a sequence not yet whole
	paste bool
	str   bool // in a string (OSC, DCS, APC), up to its terminator
}

// feed returns what of p goes on to the pane, and whether the key came, which
// ends it.
func (m *detachMatcher) feed(p []byte) (forward []byte, detach bool) {
	data := p
	if len(m.pend) > 0 {
		data = append(m.pend, p...)
		m.pend = nil
	}
	var out []byte
	for i := 0; i < len(data); {
		c := data[i]
		switch {
		case m.str:
			// Up to BEL, or ST: its ESC ends the string, the \ then passes
			// as text.
			if c == 7 || c == 0x1b {
				m.str = false
			}
			out = append(out, c)
			i++
		case c == 0x1b && i+1 < len(data) && (data[i+1] == ']' || data[i+1] == 'P' || data[i+1] == '_') && !m.paste:
			m.str = true
			out = append(out, data[i:i+2]...)
			i += 2
		case c == 0x1b && i+1 < len(data) && data[i+1] == '[':
			n := csiLen(data[i:])
			if n == 0 {
				if len(data)-i > 64 { // no key is this long
					out = append(out, data[i:i+2]...)
					i += 2
					continue
				}
				m.pend = slices.Clone(data[i:])
				return out, false
			}
			seq := string(data[i : i+n])
			i += n
			switch {
			case m.paste:
				m.paste = seq != "\x1b[201~"
			case seq == "\x1b[200~":
				m.paste = true
			case m.isKey(seq):
				return out, true
			}
			out = append(out, seq...)
		case c == m.legacy && !m.paste:
			return out, true
		default:
			out = append(out, c)
			i++
		}
	}
	return out, false
}

// csiLen returns the length of the CSI sequence b starts with, 0 when it
// isn't whole yet.
func csiLen(b []byte) int {
	for i := 2; i < len(b); i++ {
		if b[i] < 0x20 || b[i] >= 0x40 {
			return i + 1
		}
	}
	return 0
}

// isKey reports whether a CSI sequence is the key pressed: the Kitty
// keyboard protocol's CSI code[:alternates] ; mods[:event] [; text] u, or
// modifyOtherKeys' CSI 27 ; mods ; code ~.
func (m *detachMatcher) isKey(seq string) bool {
	body := seq[2 : len(seq)-1]
	fields := strings.Split(body, ";")
	switch seq[len(seq)-1] {
	case 'u':
		if len(fields) < 2 {
			return false
		}
		code, _, _ := strings.Cut(fields[0], ":")
		mods, event, _ := strings.Cut(fields[1], ":")
		return atoi(code) == m.code && ctrlOnly(mods) && event != "3"
	case '~':
		return len(fields) == 3 && fields[0] == "27" && ctrlOnly(fields[1]) && atoi(fields[2]) == m.code
	}
	return false
}

// ctrlOnly reports whether the modifiers, as the protocols write them, are
// Ctrl's alone, Caps Lock and Num Lock aside.
func ctrlOnly(mods string) bool {
	n := atoi(mods)
	return n > 0 && (n-1)&^(64|128) == 4
}

// atoi reads a number, -1 when it's none.
func atoi(s string) int {
	if s == "" {
		return -1
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' || n > 1<<20 {
			return -1
		}
		n = n*10 + int(c-'0')
	}
	return n
}
