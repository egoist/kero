//go:build darwin || linux

package daemon

import (
	"encoding/json"
	"os"
	"sync"
	"testing"
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
