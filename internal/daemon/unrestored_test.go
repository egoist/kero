//go:build darwin || linux

package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"kero/internal/proto"
)

// A shell that cannot start stays visible and saved for another attempt.
func TestFailedShellSessionKept(t *testing.T) {
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
	p := d.panes["p1"]
	if len(d.sessions) != 1 || p == nil || p.proc != nil || p.info.Status != proto.Exited {
		t.Fatalf("failed shell was not kept as an exited pane: %+v", p)
	}
	defer p.close()
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
