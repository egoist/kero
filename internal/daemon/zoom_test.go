package daemon

import (
	"encoding/json"
	"strings"
	"testing"

	"kero/internal/proto"
)

func TestZoomSaysWhenPaneIsNotInSession(t *testing.T) {
	d := testDaemon(t)
	s := &session{id: "s1", focus: "a", zoomed: "a", panes: []*pane{{info: proto.Pane{ID: "a"}}}}
	d.sessions = []*session{s}
	call := func(pane string) error {
		raw, err := json.Marshal(proto.FocusParams{Session: "s1", Pane: pane})
		if err != nil {
			t.Fatal(err)
		}
		_, err = d.call(nil, "zoom", raw)
		return err
	}
	if err := call("missing"); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Fatalf("zoom missing pane: %v", err)
	}
	if s.zoomed != "a" || s.focus != "a" {
		t.Fatalf("missing pane changed zoom or focus: %q, %q", s.zoomed, s.focus)
	}
	if err := call(""); err != nil || s.zoomed != "" {
		t.Fatalf("clear zoom: %v, zoom %q", err, s.zoomed)
	}
	if err := call("a"); err != nil || s.zoomed != "a" {
		t.Fatalf("zoom pane: %v, zoom %q", err, s.zoomed)
	}
}
