//go:build darwin || linux

package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// A session none of whose panes start again, as when the terminal's
// library is missing, stays saved for the next start, rather than lost
// with the next save.
func TestUnrestoredSessionKept(t *testing.T) {
	d := testDaemon(t)
	// A shell there that cannot run, as a program whose library is gone.
	shell := filepath.Join(d.dir, "broken-shell")
	if err := os.WriteFile(shell, []byte("not a program"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KERO_CONFIG"), []byte("command = "+shell+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	saved := savedState{Version: 2, Projects: d.projects, Sessions: []savedSession{{
		ID: "kept", Project: "pr", Name: "kept",
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
	if len(d.sessions) != 0 || len(d.panes) != 0 {
		t.Fatalf("restored %d sessions, %d panes with a broken shell", len(d.sessions), len(d.panes))
	}
	d.saveState()
	data, err = os.ReadFile(d.statePath())
	if err != nil {
		t.Fatal(err)
	}
	var st savedState
	if err := json.Unmarshal(data, &st); err != nil {
		t.Fatal(err)
	}
	if len(st.Sessions) != 1 || st.Sessions[0].ID != "kept" || len(st.Sessions[0].Panes) != 1 {
		t.Fatalf("saved sessions %+v, want the unrestored one kept", st.Sessions)
	}
}
