package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"kero/internal/proto"
)

// TestSearchStress measures a search of many panes with full scrollbacks,
// and how output fares during it: KERO_SEARCH_STRESS=1 go test -v -run
// SearchStress ./internal/daemon.
func TestSearchStress(t *testing.T) {
	if os.Getenv("KERO_SEARCH_STRESS") == "" {
		t.Skip("KERO_SEARCH_STRESS is not set")
	}
	for _, tc := range []struct{ panes, mb int }{{40, 4}, {100, 4}, {20, 32}, {6, 256}} {
		t.Run(fmt.Sprintf("%dx%dMB", tc.panes, tc.mb), func(t *testing.T) { searchStress(t, tc.panes, tc.mb) })
	}
}

func searchStress(t *testing.T, count, mb int) {
	cfg := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(cfg, fmt.Appendf(nil, "scrollback-limit = %d\n", mb), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_CONFIG", cfg)
	d := &Daemon{changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1), panes: map[string]*pane{}}
	d.viewed.Store(new(string))
	line := "\x1b[32m2026-11-03T10:00:00Z\x1b[0m \x1b[1minfo\x1b[0m compile package kero/internal/daemon step finished in 123ms status ok %d\r\n"
	var chunk strings.Builder
	for i := range 5000 {
		fmt.Fprintf(&chunk, line, i)
	}
	data := []byte(chunk.String())
	rounds := mb*2 + 20 // well past the limit
	var panes []*pane
	start := time.Now()
	for i := range count {
		p := searchPane(t, d, fmt.Sprintf("p%d", i), "", 120)
		for range rounds {
			p.term.Feed(data)
		}
		p.term.Feed(fmt.Appendf(nil, "the Needle of pane %d\r\n", i))
		panes = append(panes, p)
	}
	text := panes[0].term.Text()
	t.Logf("%d panes at %d MB, filled in %v: %d lines, %.1f MB of text each", count, mb, time.Since(start).Round(time.Millisecond),
		strings.Count(text, "\n"), float64(len(text))/(1<<20))
	text = ""

	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)

	// Output goes on into two panes through it all, as programs' does.
	var stop atomic.Bool
	lat := make(chan []time.Duration, 2)
	for _, p := range []*pane{panes[0], panes[count-1]} {
		go func() {
			var ds []time.Duration
			small := []byte("output while searching\r\n")
			for !stop.Load() {
				t0 := time.Now()
				p.mu.Lock() // as pane.output holds it
				p.term.Feed(small)
				p.mu.Unlock()
				ds = append(ds, time.Since(t0))
				time.Sleep(time.Millisecond)
			}
			lat <- ds
		}()
	}
	run := func(name, query string, p proto.SearchParams) {
		p.Query = query
		first := time.Duration(0)
		found := 0
		t0 := time.Now()
		res := runSearch(context.Background(), panes, p, func(ms []proto.SearchMatch) {
			if first == 0 {
				first = time.Since(t0)
			}
			found += len(ms)
		})
		t.Logf("%-28s %10v in all, first results after %8v, %d matches, %d panes", name, time.Since(t0).Round(100*time.Microsecond),
			first.Round(100*time.Microsecond), found, res.Panes)
	}
	run("no match (whole scan)", "nothing-matches-this", proto.SearchParams{})
	run("one match a pane", "needle of pane", proto.SearchParams{})
	run("everything matches, app's", "compile", proto.SearchParams{Limit: 150, PerPane: 10})
	run("everything matches, CLI's", "compile", proto.SearchParams{Limit: 50, PerPane: 10})

	// One canceled as the user types on.
	ctx, cancel := context.WithCancel(context.Background())
	t0 := time.Now()
	time.AfterFunc(2*time.Millisecond, cancel)
	res := runSearch(ctx, panes, proto.SearchParams{Query: "nothing-matches-this"}, func([]proto.SearchMatch) {})
	t.Logf("canceled after 2ms: returned in %v, canceled %v", time.Since(t0).Round(100*time.Microsecond), res.Canceled)

	runtime.ReadMemStats(&after)
	stop.Store(true)
	for range 2 {
		ds := <-lat
		slices.Sort(ds)
		t.Logf("output during it: %d writes, p50 %v p99 %v max %v", len(ds), ds[len(ds)/2].Round(time.Microsecond),
			ds[len(ds)*99/100].Round(time.Microsecond), ds[len(ds)-1].Round(time.Microsecond))
	}
	t.Logf("Go heap: %.0f MB before, %.0f MB after, largest %.0f MB of Sys; collected %d times",
		float64(before.HeapAlloc)/(1<<20), float64(after.HeapAlloc)/(1<<20), float64(after.Sys)/(1<<20), after.NumGC-before.NumGC)
}
