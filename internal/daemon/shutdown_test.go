package daemon

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSignalShutdownRefusesNewSessions(t *testing.T) {
	d := testDaemon(t)
	d.quit = make(chan struct{})
	d.shutdownOnSignal(os.Interrupt)
	_, err := d.call(nil, "create", json.RawMessage(`{"url":"localhost:3000"}`))
	if err == nil || !strings.Contains(err.Error(), "shutting down") {
		t.Fatalf("create after signal shutdown: %v", err)
	}
}

func TestRestartRefusesNewSessions(t *testing.T) {
	d := testDaemon(t)
	d.quit = make(chan struct{})
	then, err := d.restart()
	if err != nil {
		t.Fatal(err)
	}
	then()
	_, err = d.call(nil, "create", json.RawMessage(`{"url":"localhost:3000"}`))
	if err == nil || !strings.Contains(err.Error(), "shutting down") {
		t.Fatalf("create after restart: %v", err)
	}
}

// A daemon that is shutting down starts no session: the session would
// go with it, and the user would hear of neither.
func TestShutdownRefusesNewSessions(t *testing.T) {
	d := testDaemon(t)
	d.quit = make(chan struct{})
	if _, err := d.call(nil, "shutdown", nil); err != nil {
		t.Fatal(err)
	}
	_, err := d.call(nil, "create", json.RawMessage(`{"url":"localhost:3000"}`))
	if err == nil {
		t.Fatal("made a session while the daemon was shutting down")
	}
	if !strings.Contains(err.Error(), "shutting down") {
		t.Errorf("the error of the refused session: %v", err)
	}
}
