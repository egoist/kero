package daemon

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"runtime"
	"slices"
	"strings"
	"sync"

	"kero/internal/proto"
)

// Bounds of a search's matches: its defaults, and the most it may ask.
const (
	searchLimit      = 200
	searchPerPane    = 20
	searchLimitMax   = 2000
	searchPerPaneMax = 2000
)

// searchSlots bounds the panes searched at once, by every search together:
// each holds a copy of its pane's text while it goes through it.
var searchSlots = make(chan struct{}, min(max(runtime.NumCPU()/2, 1), 4))

// search searches the panes' text as a client asks, streaming the matches to
// its connection as they come. Nothing of it stays: no index, no results,
// and neither the query nor the matches go to the log. It reads the pane's
// text under the terminal's lock alone (terminal.Terminal.Text), as its
// output waits while it is copied, and goes through the copy under none.
func (d *Daemon) search(c *controlConn, p proto.SearchParams) (proto.SearchResult, error) {
	if strings.TrimSpace(p.Query) == "" {
		return proto.SearchResult{}, errors.New("search: for what?")
	}
	if len(p.Query) > proto.MaxQuery {
		return proto.SearchResult{}, fmt.Errorf("search: a query is at most %d bytes", proto.MaxQuery)
	}
	panes, err := d.searchPanes(p)
	if err != nil {
		return proto.SearchResult{}, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// A search.cancel may come first: requests run as they come.
	if _, canceled := c.searches.LoadOrStore(p.Req, cancel); canceled {
		cancel()
	}
	defer c.searches.Delete(p.Req)
	go func() {
		select {
		case <-c.done:
			cancel()
		case <-d.quit:
			cancel()
		case <-ctx.Done():
		}
	}()
	return runSearch(ctx, panes, p, func(ms []proto.SearchMatch) {
		c.write(proto.Message{Event: "search", Search: &proto.SearchBatch{Req: p.Req, Matches: ms}})
	}), nil
}

// cancelSearch stops a search of the connection.
func (c *controlConn) cancelSearch(req int64) {
	noop := context.CancelFunc(func() {})
	if v, ok := c.searches.LoadOrStore(req, noop); ok {
		v.(context.CancelFunc)()
	}
}

// searchPanes lists the terminals to search, of the project asked for: the
// one that last had output first, and the one named last after them.
func (d *Daemon) searchPanes(p proto.SearchParams) ([]*pane, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	project := ""
	if p.Project != "" {
		for _, pr := range d.projects {
			if pr.ID == p.Project || strings.EqualFold(pr.Name, p.Project) {
				project = pr.ID
				break
			}
		}
		if project == "" {
			return nil, fmt.Errorf("no project %q", p.Project)
		}
	}
	type entry struct {
		p        *pane
		activity int64
		last     bool
	}
	var list []entry
	for _, s := range d.sessions {
		if project != "" && s.project != project {
			continue
		}
		for _, pn := range s.panes {
			if pn.term == nil {
				continue // a browser's, which has no text
			}
			pn.mu.Lock()
			list = append(list, entry{pn, pn.info.Activity, pn.info.ID == p.Last})
			pn.mu.Unlock()
		}
	}
	slices.SortStableFunc(list, func(a, b entry) int {
		if a.last != b.last {
			if b.last {
				return -1
			}
			return 1
		}
		return cmp.Compare(b.activity, a.activity)
	})
	panes := make([]*pane, len(list))
	for i, e := range list {
		panes[i] = e.p
	}
	return panes, nil
}

// searched is what a search found of a pane.
type searched struct {
	matches []proto.SearchMatch
	more    bool
}

// runSearch searches the panes, several at once, and gives emit the matches
// of each in the panes' order, as soon as those before it are through,
// stopping once ctx ends or the bound of them all is reached.
func runSearch(ctx context.Context, panes []*pane, p proto.SearchParams, emit func([]proto.SearchMatch)) proto.SearchResult {
	limit := bound(p.Limit, searchLimit, searchLimitMax)
	perPane := bound(p.PerPane, searchPerPane, searchPerPaneMax)
	outer := ctx
	ctx, cancel := context.WithCancel(ctx)
	results := make([]chan searched, len(panes))
	for i := range results {
		results[i] = make(chan searched, 1)
	}
	var wg sync.WaitGroup
	defer func() {
		cancel()
		wg.Wait()
	}()
	wg.Go(func() {
		for i, pn := range panes {
			select {
			case searchSlots <- struct{}{}:
			case <-ctx.Done():
				return
			}
			wg.Go(func() {
				defer func() { <-searchSlots }()
				results[i] <- pn.searchText(ctx, p.Query, perPane)
			})
		}
	})
	var res proto.SearchResult
	for _, ch := range results {
		var r searched
		select {
		case r = <-ch:
		case <-outer.Done():
		}
		// A search stopped as it went through this pane found less of it.
		if outer.Err() != nil {
			res.Canceled = true
			return res
		}
		res.Panes++
		res.Truncated = res.Truncated || r.more
		if n := min(limit, len(r.matches)); n < len(r.matches) {
			r.matches, res.Truncated = r.matches[:n], true
		}
		if len(r.matches) > 0 {
			emit(r.matches)
			limit -= len(r.matches)
		}
		if limit <= 0 {
			break
		}
	}
	if limit <= 0 && res.Panes < len(panes) {
		res.Truncated = true
	}
	return res
}

// searchText finds the pane's newest matches of query, at most n, and tells
// whether it has more.
func (s *pane) searchText(ctx context.Context, query string, n int) searched {
	text := s.term.Text()
	var r searched
	proto.ScanMatches(text, query, func() bool { return ctx.Err() != nil }, func(m proto.SearchMatch) bool {
		if len(r.matches) == n {
			r.more = true
			return false
		}
		m.Pane = s.info.ID
		r.matches = append(r.matches, m)
		return true
	})
	if len(r.matches) > 0 {
		s.d.mu.Lock()
		sid := s.sid
		s.d.mu.Unlock()
		for i := range r.matches {
			r.matches[i].Session = sid
		}
	}
	return r
}

// bound is a count asked for: def when none is, at most most.
func bound(n, def, most int) int {
	if n <= 0 {
		return def
	}
	return min(n, most)
}
