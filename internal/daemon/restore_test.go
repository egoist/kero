//go:build darwin || linux

package daemon

import (
	"encoding/json"
	"os"
	"sync"
	"testing"
	"time"
)

// The state is restored under the daemon's lock: the network listeners
// are up before the restore, and a client that connects then reads the
// state as it is restored.
func TestRestoreWhileState(t *testing.T) {
	d := testDaemon(t)
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
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		d.restore()
	}()
	go func() {
		defer wg.Done()
		for range 200 {
			d.state()
		}
	}()
	wg.Wait()
	if len(d.sessions) != 1 || len(d.sessions[0].panes) != 1 {
		t.Fatalf("restored %d sessions", len(d.sessions))
	}
}

// A session's zoomed pane is its layout's and focus's too: a daemon
// restart — the remote-restart update's, which restores on purpose —
// unzoomed every session, with nothing said.
func TestRestoreKeepsTheZoom(t *testing.T) {
	d := testDaemon(t)
	saved := savedState{Version: 2, Projects: d.projects, Sessions: []savedSession{{
		ID: "s1", Project: "pr", Name: "s1", Zoomed: "p2",
		Panes: []savedPane{
			{ID: "p1", Dir: d.dir, Cols: 80, Rows: 24},
			{ID: "p2", Dir: d.dir, Cols: 80, Rows: 24},
		},
	}}}
	data, err := json.Marshal(saved)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(d.statePath(), data, 0o600); err != nil {
		t.Fatal(err)
	}
	d.restore()
	if len(d.sessions) != 1 {
		t.Fatalf("restored %d sessions", len(d.sessions))
	}
	if got := d.sessions[0].zoomed; got != "p2" {
		t.Errorf("the zoomed pane after the restore: %q, want p2", got)
	}
	// A zoomed pane that did not come back is no pane to zoom.
	d2 := testDaemon(t)
	saved.Sessions[0].Zoomed = "gone"
	data, _ = json.Marshal(saved)
	os.WriteFile(d2.statePath(), data, 0o600)
	d2.restore()
	if got := d2.sessions[0].zoomed; got != "" {
		t.Errorf("the zoom of a pane that is not there: %q", got)
	}
}

// A restored pane is marked for the save of its history before its shell
// starts: the pump that reads the shell's output marks it under the
// pane's lock, and the mark written after the start raced it.
func TestRestoredPaneIsMarkedBeforeItsShell(t *testing.T) {
	d := testDaemon(t)
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
	d.restore()
	if d.findPane("p1") == nil {
		t.Fatal("p1 was not restored")
	}
	// The shell's prompt comes as output, which marks the pane under its
	// lock: the restore's mark, written after the shell started, raced
	// the pump's, and `go test -race` says so.
	time.Sleep(time.Second)
}
