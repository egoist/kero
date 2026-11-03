package main

import (
	"testing"

	"github.com/egoist/mygo/plugins/terminal"

	"kero/internal/proto"
)

func TestBlockAt(t *testing.T) {
	done := func(seq uint64) proto.Block { return proto.Block{Seq: seq, Ms: 1} }
	b := paneBlocks{
		list: []proto.Block{done(1), done(2), done(3), {Seq: 4, Ms: -1}},
		rows: []int{0, 5, 50, 90},
	}
	for _, c := range []struct {
		name string
		v    terminal.Viewport
		want int
	}{
		// At its end: the last that ended, not the one that runs.
		{"at the bottom", terminal.Viewport{Top: 80, Rows: 30, AtBottom: true}, 2},
		{"a block at the top", terminal.Viewport{Top: 0, Rows: 30}, 0},
		{"one starting near the top", terminal.Viewport{Top: 45, Rows: 30}, 2},
		{"in the middle of one", terminal.Viewport{Top: 20, Rows: 30}, 1},
	} {
		if got := b.blockAt(c.v); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
	// Its prompt counts as its start.
	b = paneBlocks{list: []proto.Block{{Seq: 1, Ms: 1, Up: 2}}, rows: []int{12}}
	if got := b.blockAt(terminal.Viewport{Top: 10, Rows: 30}); got != 0 {
		t.Errorf("a prompt above its line: %d", got)
	}
	if got := (&paneBlocks{}).blockAt(terminal.Viewport{Rows: 30, AtBottom: true}); got != -1 {
		t.Errorf("no blocks: %d", got)
	}
	// None found, none to look at.
	b = paneBlocks{list: []proto.Block{done(1)}, rows: []int{-1}}
	if got := b.blockAt(terminal.Viewport{Top: 10, Rows: 30}); got != -1 {
		t.Errorf("a block no longer there: %d", got)
	}
}

func TestBlockLabel(t *testing.T) {
	code := func(n int) *int { return &n }
	for _, c := range []struct {
		b    proto.Block
		want string
	}{
		{proto.Block{Ms: 40, Exit: code(0)}, ""}, // a quick ls adds nothing
		{proto.Block{Ms: 3200, Exit: code(0)}, "3.2s"},
		{proto.Block{Ms: 40, Exit: code(1)}, "exit 1"},
		{proto.Block{Ms: 3200, Exit: code(2)}, "exit 2 · 3.2s"},
		{proto.Block{Ms: -1}, ""},          // still running
		{proto.Block{Ms: 40}, ""},          // no status told
		{proto.Block{Ms: 125000}, "2m 5s"}, // no status told, but long
	} {
		if got := blockLabel(c.b); got != c.want {
			t.Errorf("blockLabel(%+v) = %q, want %q", c.b, got, c.want)
		}
	}
}

func TestFormatDuration(t *testing.T) {
	for ms, want := range map[int64]string{
		2000: "2s", 3210: "3.2s", 9999: "10.0s", 12400: "12s", 60000: "1m", 125000: "2m 5s",
		3600000: "1h", 3720000: "1h 2m",
	} {
		if got := formatDuration(ms); got != want {
			t.Errorf("formatDuration(%d) = %q, want %q", ms, got, want)
		}
	}
}

// A command's end is news only when it took long, is no agent's, and the user
// wants it told.
func TestCommandWorthTelling(t *testing.T) {
	long := &proto.Commands{Last: 1, Ms: 40000}
	if !commandWorthTelling(long, true, 30) {
		t.Error("a long command isn't told")
	}
	if commandWorthTelling(long, false, 30) {
		t.Error("told with notify-on-long-command off")
	}
	if commandWorthTelling(long, true, 60) {
		t.Error("told under the threshold")
	}
	if commandWorthTelling(&proto.Commands{Last: 1, Ms: 40000, Quiet: true}, true, 30) {
		t.Error("an agent's end is told twice")
	}
}
