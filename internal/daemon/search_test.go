package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	keroclient "kero/internal/client"
	"kero/internal/proto"
)

// searchPane adds a pane with no program to the daemon, in a session of its
// own, of the project.
func searchPane(t *testing.T, d *Daemon, id, project string, cols int) *pane {
	t.Helper()
	p, err := newPane(d, "s-"+id, proto.Pane{ID: id, Status: proto.Idle, Cols: cols, Rows: 10})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.term.Close() })
	d.panes[id] = p
	d.sessions = append(d.sessions, &session{id: "s-" + id, project: project, panes: []*pane{p}})
	return p
}

// runAll searches the daemon's panes as the method does.
func runAll(t *testing.T, d *Daemon, p proto.SearchParams) ([]proto.SearchMatch, proto.SearchResult) {
	t.Helper()
	panes, err := d.searchPanes(p)
	if err != nil {
		t.Fatal(err)
	}
	var all []proto.SearchMatch
	res := runSearch(context.Background(), panes, p, func(ms []proto.SearchMatch) { all = append(all, ms...) })
	return all, res
}

// A match that a narrow pane soft-wrapped counts, on the one line it is.
func TestSearchAcrossWrap(t *testing.T) {
	d := testDaemon(t)
	p := searchPane(t, d, "a", "pr", 20)
	p.output([]byte(strings.Repeat("x", 17) + "needle tail\r\nnext\r\n"))
	all, _ := runAll(t, d, proto.SearchParams{Query: "needle"})
	if len(all) != 1 {
		t.Fatalf("matches %+v", all)
	}
	m := all[0]
	if m.Pane != "a" || m.Session != "s-a" || m.Line != strings.Repeat("x", 17)+"needle tail" || m.Line[m.Start:m.End] != "needle" {
		t.Errorf("match %+v", m)
	}
}

// What a program colors or titles shows as its text alone, a match running
// through a change of color.
func TestSearchStripsEscapes(t *testing.T) {
	d := testDaemon(t)
	p := searchPane(t, d, "a", "pr", 80)
	p.output([]byte("\x1b]0;a title\x07\x1b[1;31mERR\x1b[0;32mOR\x1b[0m: \x1b]8;;http://example.com\x1b\\link\x1b]8;;\x1b\\ \x1b[48;5;21mdone\x1b[0m\r\n"))
	all, _ := runAll(t, d, proto.SearchParams{Query: "error"})
	if len(all) != 1 {
		t.Fatalf("matches %+v", all)
	}
	if got := all[0].Line; got != "ERROR: link done" {
		t.Errorf("line %q", got)
	}
	if a, _ := runAll(t, d, proto.SearchParams{Query: "[1;31m"}); len(a) != 0 {
		t.Errorf("found an escape sequence: %+v", a)
	}
}

// A pane gives its newest matches up to its bound, all of them up to theirs,
// and the search says it left some out.
func TestSearchBounds(t *testing.T) {
	d := testDaemon(t)
	for _, id := range []string{"a", "b", "c"} {
		p := searchPane(t, d, id, "pr", 80)
		for i := range 30 {
			p.output(fmt.Appendf(nil, "hit %s %d\r\n", id, i))
		}
	}
	all, res := runAll(t, d, proto.SearchParams{Query: "hit", PerPane: 5})
	if len(all) != 15 || !res.Truncated || res.Panes != 3 {
		t.Fatalf("%d matches, %+v", len(all), res)
	}
	if !strings.HasSuffix(all[0].Line, " 29") || all[0].Newer != 0 || all[4].Newer != 4 {
		t.Errorf("not the newest first: %+v", all[:5])
	}
	all, res = runAll(t, d, proto.SearchParams{Query: "hit", PerPane: 5, Limit: 7})
	if len(all) != 7 || !res.Truncated {
		t.Errorf("%d matches, %+v", len(all), res)
	}
	all, res = runAll(t, d, proto.SearchParams{Query: " 29"})
	if len(all) != 3 || res.Truncated {
		t.Errorf("%d matches, %+v", len(all), res)
	}
	// Asking for more than kerod gives.
	if n := bound(1<<30, searchLimit, searchLimitMax); n != searchLimitMax {
		t.Errorf("bound %d", n)
	}
}

// The panes with the latest output come first, the one named last after
// them; a project keeps to its own; a browser has no text.
func TestSearchOrderAndProject(t *testing.T) {
	d := testDaemon(t)
	d.projects = append(d.projects, proto.Project{ID: "other", Name: "Other"})
	a := searchPane(t, d, "a", "pr", 80)
	b := searchPane(t, d, "b", "pr", 80)
	c := searchPane(t, d, "c", "other", 80)
	for _, p := range []*pane{a, b, c} {
		p.output([]byte("hit\r\n"))
	}
	a.mu.Lock()
	a.info.Activity = 100
	a.mu.Unlock()
	b.mu.Lock()
	b.info.Activity = 300
	b.mu.Unlock()
	c.mu.Lock()
	c.info.Activity = 200
	c.mu.Unlock()
	d.panes["web"] = &pane{d: d, info: proto.Pane{ID: "web", URL: "http://x"}}
	d.sessions = append(d.sessions, &session{id: "s-web", project: "pr", panes: []*pane{d.panes["web"]}})

	order := func(all []proto.SearchMatch) (ids []string) {
		for _, m := range all {
			ids = append(ids, m.Pane)
		}
		return ids
	}
	all, _ := runAll(t, d, proto.SearchParams{Query: "hit"})
	if got := order(all); !slices.Equal(got, []string{"b", "c", "a"}) {
		t.Errorf("order %v", got)
	}
	all, _ = runAll(t, d, proto.SearchParams{Query: "hit", Last: "b"})
	if got := order(all); !slices.Equal(got, []string{"c", "a", "b"}) {
		t.Errorf("order with one last %v", got)
	}
	all, _ = runAll(t, d, proto.SearchParams{Query: "hit", Project: "OTHER"})
	if got := order(all); !slices.Equal(got, []string{"c"}) {
		t.Errorf("of a project %v", got)
	}
	if _, err := d.searchPanes(proto.SearchParams{Project: "nope"}); err == nil {
		t.Error("no error for a project that isn't")
	}
}

// A search canceled stops: no pane's matches come after, however many panes
// it had to go.
func TestSearchCancel(t *testing.T) {
	d := testDaemon(t)
	var panes []*pane
	for i := range 50 {
		p := searchPane(t, d, fmt.Sprintf("p%d", i), "pr", 80)
		p.output([]byte("hit\r\n"))
		panes = append(panes, p)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	batches := 0
	res := runSearch(ctx, panes, proto.SearchParams{Query: "hit"}, func([]proto.SearchMatch) {
		batches++
		cancel()
	})
	if batches != 1 || !res.Canceled || res.Panes == len(panes) {
		t.Errorf("%d batches after canceling at the first, %+v", batches, res)
	}
	// A search whose bound of them all is reached stops the same.
	res = runSearch(context.Background(), panes, proto.SearchParams{Query: "hit", Limit: 1}, func([]proto.SearchMatch) {})
	if res.Canceled || !res.Truncated || res.Panes != 1 {
		t.Errorf("%+v", res)
	}
	// All of the slots came back.
	for range cap(searchSlots) {
		select {
		case searchSlots <- struct{}{}:
		case <-time.After(5 * time.Second):
			t.Fatal("a search kept a slot")
		}
	}
	for range cap(searchSlots) {
		<-searchSlots
	}
}

// A search.cancel may come before the search it stops: requests run as they
// come.
func TestSearchCancelFirst(t *testing.T) {
	d := testDaemon(t)
	p := searchPane(t, d, "a", "pr", 80)
	p.output([]byte("hit\r\n"))
	c := &controlConn{done: make(chan struct{})}
	defer close(c.done)
	c.cancelSearch(7)
	done := make(chan proto.SearchResult, 1)
	go func() {
		res, err := d.search(c, proto.SearchParams{Req: 7, Query: "hit"})
		if err != nil {
			t.Error(err)
		}
		done <- res
	}()
	select {
	case res := <-done:
		if !res.Canceled {
			t.Errorf("%+v", res)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the search went on")
	}
}

// A match that scrolled out of what the pane keeps is found no more, nor
// found again, and the pane's other text still is.
func TestSearchTrimmedTarget(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config")
	if err := os.WriteFile(cfg, []byte("scrollback-limit = 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_CONFIG", cfg)
	d := &Daemon{changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1), panes: map[string]*pane{}}
	d.viewed.Store(new(string))
	p := searchPane(t, d, "a", "", 80)
	p.output([]byte("trimmed-away needle\r\n"))
	all, _ := runAll(t, d, proto.SearchParams{Query: "needle"})
	if len(all) != 1 {
		t.Fatalf("matches %+v", all)
	}
	m := all[0]
	if _, ok := proto.LocateMatch(p.term.Text(), "needle", m); !ok {
		t.Fatal("not found again before it scrolled away")
	}
	line := strings.Repeat("filler ", 10) + "\r\n"
	for range 100 {
		p.output([]byte(strings.Repeat(line, 1000)))
		if a, _ := runAll(t, d, proto.SearchParams{Query: "needle"}); len(a) == 0 {
			break
		}
	}
	if a, _ := runAll(t, d, proto.SearchParams{Query: "needle"}); len(a) != 0 {
		t.Fatalf("the scrollback kept it: %+v", a)
	}
	if _, ok := proto.LocateMatch(p.term.Text(), "needle", m); ok {
		t.Error("found again once gone")
	}
	if a, _ := runAll(t, d, proto.SearchParams{Query: "filler", PerPane: 1}); len(a) != 1 {
		t.Errorf("what's left isn't found: %+v", a)
	}
}

// pipeDialer connects a client straight to the daemon.
type pipeDialer struct{ d *Daemon }

func (p pipeDialer) Dial() (net.Conn, error) {
	a, b := net.Pipe()
	go p.d.serve(b, identity{peer: "test", via: "unix"})
	return a, nil
}

// A client gets the matches as they come, then the end of the search, over
// the wire.
func TestSearchOverConnection(t *testing.T) {
	d := testDaemon(t)
	d.clients = map[*proto.ClientInfo]struct{}{}
	for _, id := range []string{"a", "b"} {
		searchPane(t, d, id, "pr", 80).output([]byte("hit in " + id + "\r\n"))
	}
	c, err := keroclient.ConnectVia(pipeDialer{d})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var all []proto.SearchMatch
	res, err := c.Search(context.Background(), proto.SearchParams{Query: "hit"}, func(ms []proto.SearchMatch) { all = append(all, ms...) })
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 || res.Panes != 2 || res.Canceled {
		t.Errorf("%+v, %+v", all, res)
	}
	if _, err := c.Search(context.Background(), proto.SearchParams{Query: "  "}, func([]proto.SearchMatch) {}); err == nil {
		t.Error("searched for nothing")
	}
}

// A search stops with the client's connection.
func TestSearchEndsWithConnection(t *testing.T) {
	d := testDaemon(t)
	for i := range 50 {
		searchPane(t, d, fmt.Sprintf("p%d", i), "pr", 80).output([]byte("hit\r\n"))
	}
	here, there := net.Pipe()
	defer there.Close()
	c := &controlConn{conn: here, enc: json.NewEncoder(here), done: make(chan struct{})}
	go func() {
		// The client reads the first matches, then goes; what follows is
		// read only well after, to let nothing but the end stop the search.
		r := bufio.NewReader(there)
		r.ReadBytes('\n')
		close(c.done)
		time.Sleep(100 * time.Millisecond)
		io.Copy(io.Discard, r)
	}()
	done := make(chan proto.SearchResult, 1)
	go func() {
		res, err := d.search(c, proto.SearchParams{Req: 1, Query: "hit"})
		if err != nil {
			t.Error(err)
		}
		done <- res
	}()
	select {
	case res := <-done:
		if !res.Canceled || res.Panes == 50 {
			t.Errorf("%+v", res)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the search went on")
	}
}

// A kerod of a Kero before search says so as any kerod of an unknown method,
// which the client names.
func TestSearchOlderKerod(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	go func() {
		// A control connection that knows no method.
		buf := make([]byte, 4096)
		n, _ := b.Read(buf)
		_ = n
		b.Write([]byte(fmt.Sprintf(`{"version":%d,"pid":1}`+"\n", proto.Version)))
		for {
			n, err := b.Read(buf)
			if err != nil {
				return
			}
			var id int
			fmt.Sscanf(string(buf[:n]), `{"id":%d`, &id)
			b.Write([]byte(fmt.Sprintf(`{"id":%d,"error":"unknown method \"search\""}`+"\n", id)))
		}
	}()
	c, err := keroclient.ConnectVia(connDialer{a})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := c.Search(context.Background(), proto.SearchParams{Query: "x"}, func([]proto.SearchMatch) {}); err != keroclient.ErrNoSearch {
		t.Errorf("err %v", err)
	}
}

type connDialer struct{ c net.Conn }

func (d connDialer) Dial() (net.Conn, error) { return d.c, nil }
