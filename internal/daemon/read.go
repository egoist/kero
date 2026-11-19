package daemon

import (
	"strings"

	"kero/internal/proto"
)

// maxReadLines bounds the lines a read answers with, and maxReadBytes
// its bytes, so that a client cannot ask the daemon for the world.
const (
	maxReadLines = 20000
	maxReadBytes = 8 << 20
)

// read answers a read of the pane's text: the screen, or with the
// scrollback; the newest lines, or the ones before them; plain, or as
// the terminal wrote them, with their colors. The pane's own lock is
// held only to take what the read is of: on a long history, windowing
// it outside the lock keeps the pane's output flowing meanwhile.
func (s *pane) read(req proto.ReadParams) proto.ReadResult {
	s.mu.Lock()
	// A browser pane runs no shell: its page is its title and URL, and
	// its read answers them whole, as it always did.
	if s.term == nil {
		page := strings.TrimSpace(s.info.Title + "\n" + s.info.URL)
		s.mu.Unlock()
		lines := textLines(page)
		return proto.ReadResult{Text: joinLines(lines), Total: len(lines)}
	}
	text, history := "", []byte(nil)
	if req.Styled {
		history = s.term.History()
	} else {
		text = s.term.Text()
	}
	rows := s.info.Rows
	s.mu.Unlock()

	if req.Styled {
		lines := vtLines(string(history))
		start, end, more := readWindow(len(lines), req, rows)
		start, dropped := fitWindow(lines, start, end, maxReadBytes)
		return proto.ReadResult{VT: strings.Join(lines[start:end], "\r\n"), More: more || dropped, Total: len(lines)}
	}
	lines := textLines(text)
	start, end, more := readWindow(len(lines), req, rows)
	start, dropped := fitWindow(lines, start, end, maxReadBytes)
	return proto.ReadResult{Text: joinLines(lines[start:end]), More: more || dropped, Total: len(lines)}
}

// readWindow takes the window of a read: of the lines there are, the
// newest, or the ones before them (the offset), and the screen's rows
// when the scrollback was not asked for. It tells whether older lines
// are left out of it.
func readWindow(n int, req proto.ReadParams, rows int) (start, end int, more bool) {
	end = n - req.Offset
	if end > n {
		end = n
	}
	if end < 0 {
		end = 0
	}
	limit := 0 // as many lines as there are
	switch {
	case req.Lines > 0:
		limit = min(req.Lines, maxReadLines)
	case !req.Scrollback && rows > 0:
		limit = rows
	}
	if limit > 0 && end > limit {
		start = end - limit
	}
	return start, end, start > 0
}

// fitWindow drops the oldest lines of a window that does not fit the
// bytes a read may answer with, and tells that it dropped them.
func fitWindow(lines []string, start, end int, size int) (int, bool) {
	total := 0
	for _, l := range lines[start:end] {
		total += len(l) + 1
	}
	if total <= size {
		return start, false
	}
	for start < end {
		total -= len(lines[start]) + 1
		start++
		if total <= size {
			return start, true
		}
	}
	return end, true
}

// textLines are the lines of a text: without the empty ones at its end
// and with the spaces at the end of each line gone.
func textLines(text string) []string {
	text = strings.TrimRight(text, "\n ")
	if text == "" {
		return nil
	}
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " ")
	}
	return lines
}

// vtLines are the lines of what the terminal wrote, with their colors:
// each ends with the reset that follows it and a newline, except where
// a program's long line wrapped, which the terminal joins.
func vtLines(vt string) []string {
	vt = strings.TrimSuffix(vt, "\r\n")
	if vt == "" {
		return nil
	}
	return strings.Split(vt, "\r\n")
}

// joinLines are lines as the text of a read: one after another, a
// newline each. No lines is a lone newline, as a read always answered.
func joinLines(lines []string) string {
	return strings.Join(lines, "\n") + "\n"
}
