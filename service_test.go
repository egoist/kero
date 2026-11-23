package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"

	"kero/internal/proto"
	"kero/locales"
)

// fakeKerod answers the calls of the Settings window's service line without
// starting the user's daemon: it listens on the socket, greets with the
// protocol version given, and answers each call with handle.
func fakeKerod(t *testing.T, version int, handle func(string) (any, error)) {
	t.Helper()
	t.Setenv("KERO_HOME", t.TempDir())
	t.Setenv("KERO_SOCKET", "")
	listener, err := net.Listen("unix", proto.SocketPath())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				dec, enc := json.NewDecoder(conn), json.NewEncoder(conn)
				var hello proto.Hello
				if err := dec.Decode(&hello); err != nil {
					return
				}
				if err := enc.Encode(proto.Welcome{Version: version}); err != nil {
					return
				}
				for {
					var req struct {
						ID     int64           `json:"id"`
						Method string          `json:"method"`
						Params json.RawMessage `json:"params"`
					}
					if err := dec.Decode(&req); err != nil {
						return
					}
					result, err := handle(req.Method)
					msg := proto.Message{ID: req.ID, Result: result}
					if err != nil {
						msg.Error = err.Error()
					}
					if err := enc.Encode(msg); err != nil {
						return
					}
				}
			}()
		}
	}()
}

// kerod runs, but its state could not be read: the service line says so,
// and does not count the sessions of a state it has none of.
func TestServiceLineSaysAnUnreadableState(t *testing.T) {
	fakeKerod(t, proto.Version, func(string) (any, error) { return nil, errors.New("the state is gone") })
	line := serviceLine()
	if !strings.Contains(line, "could not be read") {
		t.Errorf("the state that failed is not said: %q", line)
	}
	if strings.Contains(line, "0 sessions") {
		t.Errorf("it counted the sessions it has none of: %q", line)
	}
}

// kerod runs, but of another protocol: the service line says so, and does
// not read as "Not running" while kerod is running.
func TestServiceLineSaysAnotherVersion(t *testing.T) {
	fakeKerod(t, proto.Version+1, func(string) (any, error) { return nil, nil })
	line := serviceLine()
	if !strings.Contains(line, "another version") {
		t.Errorf("a kerod of another version is not said: %q", line)
	}
	if strings.Contains(line, locales.SvcNotRunning()) {
		t.Errorf("it says kerod is not running while kerod is: %q", line)
	}
}

// kerod runs: the service line counts its sessions and panes.
func TestServiceLineCountsSessions(t *testing.T) {
	fakeKerod(t, proto.Version, func(m string) (any, error) {
		if m != "state" {
			return nil, fmt.Errorf("no %s", m)
		}
		return proto.State{Sessions: []proto.Session{
			{ID: "a", Panes: []proto.Pane{{ID: "1"}, {ID: "2"}}},
			{ID: "b", Panes: []proto.Pane{{ID: "3"}}},
		}}, nil
	})
	line := serviceLine()
	if !strings.Contains(line, "2 sessions") || !strings.Contains(line, "3 panes") {
		t.Errorf("the sessions are not counted: %q", line)
	}
}
