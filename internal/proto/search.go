package proto

import (
	"strings"
	"unicode/utf8"
)

// SearchParams asks kerod to search its panes' text (method "search"). The
// matches come as "search" events of the connection (SearchBatch), the pane
// that last had output first, each pane's newest match first; the response
// comes after them.
type SearchParams struct {
	// Req names the search in its events and in search.cancel: the
	// connection's own number for it.
	Req   int64  `json:"req"`
	Query string `json:"query"`
	// Project keeps the search to a project, by id or name.
	Project string `json:"project,omitempty"`
	// Limit and PerPane bound the matches, in all and of a pane; 0 for
	// kerod's defaults, which also caps them.
	Limit   int `json:"limit,omitempty"`
	PerPane int `json:"perPane,omitempty"`
	// Last is a pane to search after the others: the one a command runs in,
	// whose own command line would come first otherwise.
	Last string `json:"last,omitempty"`
}

// SearchCancel stops a search (method "search.cancel").
type SearchCancel struct {
	Req int64 `json:"req"`
}

// SearchBatch is a pane's matches, as a search finds them.
type SearchBatch struct {
	Req     int64         `json:"req"`
	Matches []SearchMatch `json:"matches"`
}

// SearchResult ends a search.
type SearchResult struct {
	// Panes counts the panes searched.
	Panes int `json:"panes"`
	// Truncated tells that a bound left out matches.
	Truncated bool `json:"truncated,omitempty"`
	// Canceled tells that search.cancel stopped it.
	Canceled bool `json:"canceled,omitempty"`
}

// SearchMatch is a match of a search in a pane's text: the line, what a long
// program's output wrapped of it joined, without its colors.
type SearchMatch struct {
	Session string `json:"session"`
	Pane    string `json:"pane"`
	// Line is the line, or of a very long one the part around the match,
	// with an ellipsis where it is cut. Start and End are the match's byte
	// offsets in it.
	Line  string `json:"line"`
	Start int    `json:"start"`
	End   int    `json:"end"`
	// Newer counts the pane's matches newer than this one.
	Newer int `json:"newer"`
}

// MaxQuery bounds a query, in bytes, as a Line holds it whole.
const MaxQuery = 1024

// How much of a line a match keeps around it, in characters.
const (
	lineBefore = 80
	lineAfter  = 120
)

// lowerASCII lowers ASCII's letters, the only ones whose case matching
// ignores, as a pane's find does (terminal.Terminal.Search).
var lowerASCII = func() (t [256]byte) {
	for i := range t {
		t[i] = byte(i)
		if 'A' <= i && i <= 'Z' {
			t[i] = byte(i) + 'a' - 'A'
		}
	}
	return t
}()

// ScanMatches goes through the matches of query in text, a terminal's as
// terminal.Terminal.Text returns it, until visit returns false or stop true,
// which it asks now and then. They are the matches a pane's find finds of
// query, and in its order: from the end of the text, each line's from its
// end, overlapping ones too. Only the fields of a match's text are set.
func ScanMatches(text, query string, stop func() bool, visit func(SearchMatch) bool) {
	if query == "" || strings.IndexByte(query, '\n') >= 0 {
		return
	}
	q := make([]byte, len(query))
	for i := range q {
		q[i] = lowerASCII[query[i]]
	}
	end := len(text)
	if end > 0 && text[end-1] == '\n' {
		end--
	}
	newer := 0
	for lines := 0; ; lines++ {
		if lines&0xfff == 0 && stop != nil && stop() {
			return
		}
		from := strings.LastIndexByte(text[:end], '\n') + 1
		line := text[from:end]
		for i := len(line) - len(q); i >= 0; i-- {
			if lowerASCII[line[i]] != q[0] || !hasFold(line[i:], q) {
				continue
			}
			m := SearchMatch{Newer: newer}
			m.Line, m.Start, m.End = lineWindow(line, i, i+len(q))
			if !visit(m) {
				return
			}
			newer++
		}
		if from == 0 {
			return
		}
		end = from - 1
	}
}

// hasFold reports whether s starts with q, which is lowered.
func hasFold(s string, q []byte) bool {
	for j, b := range q {
		if lowerASCII[s[j]] != b {
			return false
		}
	}
	return true
}

// lineWindow is the part of a line a match keeps, and where the match is in
// it: a program's single line of output can be megabytes long.
func lineWindow(line string, start, end int) (string, int, int) {
	from, to := start, end
	for n := 0; n < lineBefore && from > 0; n++ {
		_, size := utf8.DecodeLastRuneInString(line[:from])
		from -= size
	}
	for n := 0; n < lineAfter && to < len(line); n++ {
		_, size := utf8.DecodeRuneInString(line[to:])
		to += size
	}
	s := line[from:to]
	start, end = start-from, end-from
	if from > 0 {
		s = "…" + s
		start, end = start+len("…"), end+len("…")
	}
	if to < len(line) {
		s += "…"
	}
	return s, start, end
}

// LocateMatch finds a match ScanMatches found earlier in a text as it is
// now, returning how many matches are newer than it, which is how far it
// lies down a pane's find's matches. Output goes on above it, and the oldest
// of the text may be gone: of the same line and place, it takes the first
// with at least as many newer, else, as a program redrew what was below it,
// the nearest with fewer; none when the line has gone.
func LocateMatch(text, query string, m SearchMatch) (newer int, ok bool) {
	newer = -1
	ScanMatches(text, query, nil, func(o SearchMatch) bool {
		if o.Start == m.Start && o.Line == m.Line {
			newer = o.Newer
			return o.Newer < m.Newer
		}
		return true
	})
	return newer, newer >= 0
}
