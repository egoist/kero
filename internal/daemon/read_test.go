package daemon

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"kero/internal/proto"
)

// feed writes lines into a pane's terminal, as a program does.
func feed(s *pane, n int) {
	for i := range n {
		s.output(fmt.Appendf(nil, "line %d\r\n", i))
	}
}

// readLines are the lines of a read's text.
func readLines(text string) []string {
	text = strings.TrimRight(text, "\n ")
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}

// A read takes the lines the client asks for: the newest, or the ones
// before them, and says how many there are and whether older ones are
// left out.
func TestReadPages(t *testing.T) {
	s := testPane(t)
	feed(s, 100)

	r := s.read(proto.ReadParams{Scrollback: true})
	if got := readLines(r.Text); len(got) != 100 || got[0] != "line 0" || got[99] != "line 99" {
		t.Fatalf("the whole history: %d lines, from %q to %q", len(got), got[0], got[len(got)-1])
	}
	if r.Total != 100 {
		t.Errorf("total %d, want 100", r.Total)
	}
	if r.More {
		t.Error("the whole history was read, yet more is left")
	}

	r = s.read(proto.ReadParams{Scrollback: true, Lines: 10})
	if got := readLines(r.Text); len(got) != 10 || got[0] != "line 90" || got[9] != "line 99" {
		t.Fatalf("the newest lines: %d, from %q to %q", len(got), got[0], got[len(got)-1])
	}
	if !r.More {
		t.Error("older lines are left out, yet more is not said")
	}

	r = s.read(proto.ReadParams{Scrollback: true, Lines: 10, Offset: 10})
	if got := readLines(r.Text); len(got) != 10 || got[0] != "line 80" || got[9] != "line 89" {
		t.Fatalf("the lines before them: %d, from %q to %q", len(got), got[0], got[len(got)-1])
	}
	if r.Total != 100 {
		t.Errorf("total %d, want 100", r.Total)
	}

	// A window that reaches the end of the history: no older lines are
	// left out of it.
	r = s.read(proto.ReadParams{Scrollback: true, Lines: 10, Offset: 95})
	if got := readLines(r.Text); len(got) != 5 || got[0] != "line 0" || got[4] != "line 4" {
		t.Fatalf("the last lines: %d, from %q to %q", len(got), got[0], got[len(got)-1])
	}
	if r.More {
		t.Error("the history's end was read, yet more is said")
	}
}

// Without the scrollback a read gives the screen's rows, the newest of
// the history, and says that older ones are left out.
func TestReadScreenOnly(t *testing.T) {
	s := testPane(t)
	feed(s, 100)

	r := s.read(proto.ReadParams{})
	got := readLines(r.Text)
	if len(got) != 28 {
		t.Fatalf("the screen: %d lines, want 28", len(got))
	}
	if got[0] != "line 72" || got[27] != "line 99" {
		t.Errorf("the screen: from %q to %q", got[0], got[27])
	}
	if !r.More {
		t.Error("older lines are left out, yet more is not said")
	}
	if r.Total != 100 {
		t.Errorf("total %d, want 100", r.Total)
	}
}

// A read of the lines as the terminal wrote them carries their colors.
func TestReadStyled(t *testing.T) {
	s := testPane(t)
	s.output([]byte("\x1b[32mgreen\x1b[0m\r\n"))
	s.output([]byte("plain\r\n"))

	r := s.read(proto.ReadParams{Scrollback: true, Styled: true})
	if r.Text != "" {
		t.Errorf("a styled read carries plain text too: %q", r.Text)
	}
	if !strings.Contains(r.VT, "green") || !strings.Contains(r.VT, "\x1b[") {
		t.Errorf("the vt has no colors: %q", r.VT)
	}
	lines := strings.Split(strings.TrimSuffix(r.VT, "\r\n"), "\r\n")
	if len(lines) != 2 {
		t.Fatalf("the vt has %d lines, want 2: %q", len(lines), r.VT)
	}
	if !strings.HasSuffix(lines[0], "\x1b[0m") {
		t.Errorf("the vt's line ends with %q, want a reset", lines[0])
	}
	if got := readLines(s.read(proto.ReadParams{Scrollback: true}).Text); len(got) != 2 || got[0] != "green" || got[1] != "plain" {
		t.Errorf("the plain text: %q", got)
	}
}

// The window of a read: the lines it takes, and whether older ones are
// left out of it.
func TestReadWindow(t *testing.T) {
	cases := []struct {
		name                   string
		n, offset, lines, rows int
		scrollback             bool
		wantStart, wantEnd     int
		wantMore               bool
	}{
		{"the whole history", 10, 0, 0, 0, true, 0, 10, false},
		{"the screen's rows", 100, 0, 0, 28, false, 72, 100, true},
		{"the newest lines", 100, 0, 10, 28, false, 90, 100, true},
		{"the lines before them", 100, 10, 10, 28, true, 80, 90, true},
		{"the last lines", 100, 95, 10, 28, true, 0, 5, false},
		{"past the end", 10, 20, 5, 0, true, 0, 0, false},
		{"a negative offset", 10, -5, 0, 0, true, 0, 10, false},
		{"more lines than there are", 10, 0, 100, 0, true, 0, 10, false},
		{"no lines at all", 0, 0, 10, 28, true, 0, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := proto.ReadParams{Scrollback: c.scrollback, Offset: c.offset, Lines: c.lines}
			start, end, more := readWindow(c.n, req, c.rows)
			if start != c.wantStart || end != c.wantEnd || more != c.wantMore {
				t.Errorf("the window: %d to %d, more %v, want %d to %d, more %v",
					start, end, more, c.wantStart, c.wantEnd, c.wantMore)
			}
		})
	}
}

// A window too big for the bytes a read may answer with keeps the
// newest lines of it.
func TestFitWindow(t *testing.T) {
	lines := []string{"aaaa", "bbbb", "cccc"}
	if start, dropped := fitWindow(lines, 0, 3, 20); start != 0 || dropped {
		t.Errorf("a window that fits: %d, dropped %v", start, dropped)
	}
	if start, dropped := fitWindow(lines, 0, 3, 12); start != 1 || !dropped {
		t.Errorf("a window that does not fit: %d, dropped %v, want 1, dropped", start, dropped)
	}
	if start, dropped := fitWindow(lines, 0, 3, 4); start != 3 || !dropped {
		t.Errorf("a window of nothing: %d, dropped %v, want 3, dropped", start, dropped)
	}
}

// A read of a pane with nothing in it, of a browser's page, and of a
// pane whose terminal is gone. Each answers as it always did: no lines
// at all is a lone newline, and a browser's page comes whole, past any
// screen of rows.
func TestReadEdges(t *testing.T) {
	s := testPane(t)
	r := s.read(proto.ReadParams{Scrollback: true})
	if r.Text != "\n" || r.Total != 0 || r.More {
		t.Errorf("an empty pane: %+v", r)
	}

	d := testDaemon(t)
	ses, err := d.create(proto.CreateParams{URL: "localhost:3000"})
	if err != nil {
		t.Fatal(err)
	}
	p := d.findPane(ses.Panes[0].ID)
	if err := p.setPage("http://localhost:3000/docs", "Docs"); err != nil {
		t.Fatal(err)
	}
	// One row of screen would drop the URL if a page went through the
	// rows limit: it never did, and never does.
	p.info.Rows = 1
	r = p.read(proto.ReadParams{})
	if r.Text != "Docs\nhttp://localhost:3000/docs\n" || r.Total != 2 || r.More {
		t.Errorf("a browser's page: %+v", r)
	}

	// A browser with no page of its own.
	if err := p.setPage("", ""); err != nil {
		t.Fatal(err)
	}
	if r = p.read(proto.ReadParams{}); r.Text != "\n" {
		t.Errorf("a browser's empty page: %+v", r)
	}

	s.term.Close()
	r = s.read(proto.ReadParams{Scrollback: true})
	if r.Text != "\n" || r.Total != 0 {
		t.Errorf("a closed terminal: %+v", r)
	}
}

// A read while the pane's program writes is a read of a moment: the
// lines it gives are a window of the history as it is then.
func TestReadConcurrent(t *testing.T) {
	s := testPane(t)
	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			select {
			case <-stop:
				return
			default:
			}
			s.output(fmt.Appendf(nil, "out %d\r\n", i))
			time.Sleep(time.Millisecond)
		}
	}()
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 20 {
				r := s.read(proto.ReadParams{Scrollback: true, Lines: 5})
				if got := readLines(r.Text); len(got) > 5 {
					t.Errorf("a read of %d lines, want at most 5", len(got))
					return
				}
				r = s.read(proto.ReadParams{Scrollback: true, Styled: true, Lines: 5})
				if got := strings.Count(r.VT, "\r\n"); got > 4 {
					t.Errorf("a styled read of %d lines, want at most 5", got+1)
					return
				}
			}
		}()
	}
	close(stop)
	wg.Wait()
}
