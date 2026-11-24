package daemon

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

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

// A state that could not be written is said: the sessions it holds are
// the ones the next daemon starts again, and a lost write is lost for
// good.
func TestFailedStateSaveIsSaid(t *testing.T) {
	d := testDaemon(t)
	var buf bytes.Buffer
	d.log = log.New(&buf, "", 0)
	// The path of the state is a directory: the write cannot put it
	// there.
	if err := os.MkdirAll(d.statePath(), 0o755); err != nil {
		t.Fatal(err)
	}
	d.saveState()
	if !strings.Contains(buf.String(), "state") {
		t.Fatalf("the failed write was not said: %q", buf.String())
	}
}

// A pane's history that could not be read is said: the pane restores
// without its scrollback, and the log names it. A pane without a history
// at all — none was saved — is no news.
func TestUnreadableHistoryIsSaid(t *testing.T) {
	d := testDaemon(t)
	var buf bytes.Buffer
	d.log = log.New(&buf, "", 0)
	saved := savedState{Version: 2, Projects: d.projects, Sessions: []savedSession{{
		ID: "s1", Project: "pr", Name: "s1",
		Panes: []savedPane{{ID: "p1", Dir: d.dir, Cols: 80, Rows: 24}},
	}}}
	data, err := json.Marshal(saved)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(d.statePath(), data, 0o600); err != nil {
		t.Fatal(err)
	}
	// The history cannot be read: the path is a directory.
	if err := os.MkdirAll(d.historyPath("p1"), 0o755); err != nil {
		t.Fatal(err)
	}
	d.restore()
	if !strings.Contains(buf.String(), "history") {
		t.Fatalf("the unreadable history was not said: %q", buf.String())
	}
	// And the pane restored either way, without its scrollback.
	if len(d.sessions) != 1 || len(d.sessions[0].panes) != 1 {
		t.Fatalf("restored %d sessions", len(d.sessions))
	}
}

// A state that could not be read is said: the sessions of the last
// daemon are gone, and nobody is told.
func TestUnreadableStateIsSaid(t *testing.T) {
	d := testDaemon(t)
	var buf bytes.Buffer
	d.log = log.New(&buf, "", 0)
	if err := os.WriteFile(d.statePath(), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.restore()
	if !strings.Contains(buf.String(), "state") {
		t.Fatalf("the unreadable state was not said: %q", buf.String())
	}
}

// Two saves of the same file at once do not leave it half of each: the
// save loop's and a stop's, which both write state.json's .tmp, run one
// at a time.
func TestSavesDoNotOverlap(t *testing.T) {
	d := testDaemon(t)
	var inside sync.Mutex
	var running, overlapped int
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			d.saveSerialized(func() {
				inside.Lock()
				running++
				if running > 1 {
					overlapped++
				}
				inside.Unlock()
				time.Sleep(5 * time.Millisecond)
				inside.Lock()
				running--
				inside.Unlock()
			})
		}()
	}
	wg.Wait()
	if overlapped > 0 {
		t.Errorf("%d saves ran at once", overlapped)
	}
}
