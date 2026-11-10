package client

import (
	"context"
	"errors"
	"strings"
	"sync"

	"kero/internal/proto"
)

// ErrNoSearch is returned by a kerod of a Kero from before search.
var ErrNoSearch = errors.New("this kerod is of a Kero that can't search")

// Search searches the panes' text of the client's kerod, giving fn the
// matches as they come, on the connection's goroutine, and returns when it
// ends, or at once when ctx does, which also stops it there: a host gone
// holds nothing up. fn is not called after it returns.
func (c *Client) Search(ctx context.Context, p proto.SearchParams, fn func([]proto.SearchMatch)) (proto.SearchResult, error) {
	p.Req = c.lastSearch.Add(1)
	var mu sync.Mutex
	over := false
	c.searches.Store(p.Req, func(ms []proto.SearchMatch) {
		mu.Lock()
		defer mu.Unlock()
		if !over {
			fn(ms)
		}
	})
	defer func() {
		c.searches.Delete(p.Req)
		mu.Lock()
		over = true
		mu.Unlock()
	}()
	type outcome struct {
		res proto.SearchResult
		err error
	}
	done := make(chan outcome, 1)
	go func() {
		var o outcome
		o.err = c.Call("search", p, &o.res)
		done <- o
	}()
	select {
	case o := <-done:
		if o.err != nil && strings.Contains(o.err.Error(), "unknown method") {
			return o.res, ErrNoSearch
		}
		return o.res, o.err
	case <-ctx.Done():
		c.Go("search.cancel", proto.SearchCancel{Req: p.Req}, nil)
		return proto.SearchResult{}, ctx.Err()
	}
}

// searchBatch gives a search's matches to the function that waits for them.
func (c *Client) searchBatch(b *proto.SearchBatch) {
	if fn, ok := c.searches.Load(b.Req); ok {
		fn.(func([]proto.SearchMatch))(b.Matches)
	}
}
