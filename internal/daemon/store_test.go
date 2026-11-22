package daemon

import (
	"os"
	"testing"

	"kero/internal/proto"
)

// A history that could not be written is the pane's still: it is saved
// again the next time, and the scrollback is not lost.
func TestFailedHistorySaveKeepsIt(t *testing.T) {
	d := testDaemon(t)
	p, err := newPane(d, "s1", proto.Pane{ID: "a", Status: proto.Idle, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.term.Close() })
	d.panes["a"] = p
	p.show("hello")
	// The history cannot be written: the path is a directory.
	if err := os.MkdirAll(d.historyPath("a"), 0o755); err != nil {
		t.Fatal(err)
	}
	d.saveHistories(false)
	p.mu.Lock()
	dirty := p.dirty
	p.mu.Unlock()
	if !dirty {
		t.Fatal("the history is not the pane's any more")
	}
	// Written, it is saved and the pane is clean.
	os.Remove(d.historyPath("a"))
	d.saveHistories(false)
	if b, err := os.ReadFile(d.historyPath("a")); err != nil || len(b) == 0 {
		t.Errorf("the history written: %v", err)
	}
	p.mu.Lock()
	dirty = p.dirty
	p.mu.Unlock()
	if dirty {
		t.Error("the history was saved and the pane is still dirty")
	}
}
