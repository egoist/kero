package proto

import (
	"slices"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Block is a command a pane's shell ran, as its prompt marks (OSC 133) tell.
//
// A block holds no row: rows change as the pane reflows, and go as the
// scrollback lets them go or the screen clears. It holds the line its command
// shows on, which Locate finds in the terminal's text whenever it is needed,
// so that a block lasts as long as its line does and no longer.
type Block struct {
	Seq uint64 `json:"seq"`
	// Line is the command's last line as the screen shows it, its prompt
	// included (ClipLine).
	Line string `json:"line"`
	// Up is how many rows of its prompt, and of its command, are above
	// Line: the block starts that far up.
	Up int `json:"up,omitempty"`
	// Output is how many lines it wrote below Line, -1 when not known.
	Output int `json:"output"`
	// Started is when it started (unix ms), and Ms how long it took, -1
	// while it runs.
	Started int64 `json:"started"`
	Ms      int64 `json:"ms"`
	// Exit is its exit status, nil while it runs or when the shell told
	// none.
	Exit *int `json:"exit,omitempty"`
}

// Failed tells a block whose command exited non-zero.
func (b Block) Failed() bool { return b.Exit != nil && *b.Exit != 0 }

// Commands is what a pane's state tells of its blocks. kerod replaces it
// whole, never changing one it sent. An older kerod sends none, and the app
// then has no blocks to show.
type Commands struct {
	// Rev changes as the pane's blocks do, for a client to ask for them
	// (BlocksParams).
	Rev uint64 `json:"rev"`
	// Last is the last command that ended, 0 before one did, with its
	// exit status (ExitKnown when it has one), how long it took and the
	// program it ran.
	Last      uint64 `json:"last,omitempty"`
	Exit      int    `json:"exit,omitempty"`
	ExitKnown bool   `json:"exitKnown,omitempty"`
	Ms        int64  `json:"ms,omitempty"`
	Name      string `json:"name,omitempty"`
	// Quiet tells that what it ran told its own status, as a coding agent
	// or a program reporting with OSC 7501: its end is no news.
	Quiet bool `json:"quiet,omitempty"`
}

type (
	// BlocksParams asks for a pane's blocks from Since on.
	BlocksParams struct {
		ID    string `json:"id"`
		Since uint64 `json:"since,omitempty"`
	}
	// BlocksResult is a pane's blocks from Since on; those before First
	// are gone.
	BlocksResult struct {
		Blocks []Block `json:"blocks"`
		First  uint64  `json:"first"`
	}
)

// MaxBlockLine is how many bytes of a command's line a block keeps.
const MaxBlockLine = 240

// ClipLine is what a block keeps of a line.
func ClipLine(line string) string {
	if len(line) <= MaxBlockLine {
		return line
	}
	n := MaxBlockLine
	for n > 0 && !utf8.RuneStart(line[n]) {
		n--
	}
	return line[:n]
}

// LastLine returns the index of the last line of a terminal's text with
// anything on it, and that line, or -1. With the cursor under what a program
// wrote, as a shell's is when it marks a command, it is where the writing
// ended.
func LastLine(text string) (int, string) {
	text = strings.TrimRight(text, " \n")
	if text == "" {
		return -1, ""
	}
	return strings.Count(text, "\n"), text[strings.LastIndexByte(text, '\n')+1:]
}

// MatchBlocks finds where lines, oldest first, show in a terminal's text: the
// index of the line each is on, -1 for one no longer there. The newest takes
// the last line that shows it, each older one the last above the one after
// it, so that a command run twice is found twice, in order. A line one left
// behind costs only that one: those around it are found still.
func MatchBlocks(text string, lines []string) []int {
	at := make(map[string][]int, len(lines))
	for _, l := range lines {
		at[l] = nil
	}
	i := 0
	for line := range strings.SplitSeq(text, "\n") {
		if l, ok := at[ClipLine(line)]; ok {
			at[ClipLine(line)] = append(l, i)
		}
		i++
	}
	found := make([]int, len(lines))
	below := i
	for n := len(lines) - 1; n >= 0; n-- {
		found[n] = -1
		l := at[lines[n]]
		// The last of them above the line found below this one.
		if k := sort.SearchInts(l, below) - 1; k >= 0 {
			found[n], below = l[k], l[k]
		}
	}
	return found
}

// LocateRows returns the row of each of a terminal's text's lines in want,
// ascending, with cols columns: a line takes as many rows as it wraps over.
func LocateRows(text string, cols int, want []int) []int {
	rows := make([]int, len(want))
	row, i, k := 0, 0, 0
	for line := range strings.SplitSeq(text, "\n") {
		if k == len(want) {
			break
		}
		for k < len(want) && want[k] == i {
			rows[k] = row
			k++
		}
		row += WrappedRows(line, cols)
		i++
	}
	for ; k < len(want); k++ {
		rows[k] = -1
	}
	return rows
}

// WrappedRows returns how many rows a line of text takes in cols columns.
// It counts cells as terminals do, near enough: a block's place is checked
// against the screen where the count may be off.
func WrappedRows(line string, cols int) int {
	if cols <= 0 || len(line) <= cols && isASCII(line) {
		return 1
	}
	rows, col := 1, 0
	joined := false
	for _, r := range line {
		w := runeCells(r)
		if joined {
			// After a joiner: the same cell.
			joined = false
			continue
		}
		if r == 0x200D {
			joined = true
			continue
		}
		if w == 0 {
			continue
		}
		if col+w > cols {
			rows++
			col = 0
		}
		col += w
	}
	return rows
}

// LineCells returns how many cells a line of text takes, unwrapped.
func LineCells(line string) int {
	n := 0
	for _, r := range line {
		n += runeCells(r)
	}
	return n
}

func isASCII(s string) bool {
	for i := range len(s) {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// wideRanges are the runes that take two cells: East Asian wide and
// fullwidth forms, and emoji.
var wideRanges = [][2]rune{
	{0x1100, 0x115F}, {0x2E80, 0x303E}, {0x3041, 0x33FF}, {0x3400, 0x4DBF}, {0x4E00, 0x9FFF},
	{0xA000, 0xA4CF}, {0xAC00, 0xD7A3}, {0xF900, 0xFAFF}, {0xFE30, 0xFE6F}, {0xFF00, 0xFF60},
	{0xFFE0, 0xFFE6}, {0x1F300, 0x1F64F}, {0x1F680, 0x1F6FF}, {0x1F900, 0x1F9FF}, {0x1FA70, 0x1FAFF},
	{0x20000, 0x3FFFD},
}

func runeCells(r rune) int {
	switch {
	case r < 0x300:
		return 1
	case unicode.In(r, unicode.Mn, unicode.Me, unicode.Cf):
		return 0
	case slices.ContainsFunc(wideRanges, func(w [2]rune) bool { return r >= w[0] && r <= w[1] }):
		return 2
	}
	return 1
}

// BlockOutput returns the output of a block on a line of a terminal's text:
// the count lines under it, or, as many as the text holds to before when
// count is -1 (before -1 for the text's end), without blank lines at its end.
func BlockOutput(text string, line, count, before int) string {
	var out []string
	i := 0
	for l := range strings.SplitSeq(text, "\n") {
		switch {
		case i <= line:
		case count >= 0 && i > line+count:
		case count < 0 && before >= 0 && i >= before:
		default:
			out = append(out, l)
		}
		i++
	}
	for len(out) > 0 && strings.TrimSpace(out[len(out)-1]) == "" {
		out = out[:len(out)-1]
	}
	return strings.Join(out, "\n")
}
