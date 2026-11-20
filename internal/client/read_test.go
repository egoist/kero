package client

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"kero/internal/proto"
)

// stateLine is a state broadcast as the daemon sends it while sessions
// work: five of them, with their panes, which is the line read parses
// for every one of them.
func stateLine(tb testing.TB) []byte {
	tb.Helper()
	sessions := make([]proto.Session, 5)
	for i := range sessions {
		id := fmt.Sprintf("s-%d", i)
		sessions[i] = proto.Session{
			Pane: proto.Pane{
				ID:      id,
				Title:   "claude — kero",
				Dir:     "/home/me/codes/kero",
				Process: "claude",
				Status:  proto.Working,
				Message: "Migrating the database and checking the results",
			},
			ID:      id,
			Project: "kero",
			Name:    fmt.Sprintf("agent-%d", i),
			Panes: []proto.Pane{{
				ID:      id + "-2",
				Dir:     "/home/me/codes/kero",
				Status:  proto.Waiting,
				Message: "Approve the production deploy?",
			}},
			Lead:  id,
			Focus: id,
		}
	}
	line, err := json.Marshal(proto.Message{
		Event: "state",
		State: &proto.State{Started: 1700000000000, Sessions: sessions},
	})
	if err != nil {
		tb.Fatal(err)
	}
	return append(line, '\n')
}

// A line of each kind the daemon sends goes where it belongs: a response
// to the call it answers, an event to the handler, a line that is no
// message at all to neither.
func TestReadDispatches(t *testing.T) {
	var wire bytes.Buffer
	wire.WriteString("not a message\n")
	fmt.Fprintf(&wire, `{"id": 7, "result": {"ok": "yes"}}`+"\n")
	if err := json.NewEncoder(&wire).Encode(proto.Message{
		Event: "state",
		State: &proto.State{Started: 1700000000000},
	}); err != nil {
		t.Fatal(err)
	}
	res := make(chan response, 1)
	c := &Client{
		pending: map[int64]chan response{7: res},
		closed:  make(chan struct{}),
	}
	events := make(chan proto.Message, 1)
	c.OnEvent(func(m proto.Message) { events <- m })
	done := make(chan struct{})
	go func() {
		c.read(bufio.NewReader(&wire))
		close(done)
	}()
	select {
	case r := <-res:
		if r.err != nil || string(r.result) != `{"ok": "yes"}` {
			t.Errorf("response %+v", r)
		}
	case <-time.After(5 * time.Second):
		t.Error("the response never arrived")
	}
	select {
	case m := <-events:
		if m.Event != "state" || m.State == nil || m.State.Started != 1700000000000 {
			t.Errorf("event %+v", m)
		}
	case <-time.After(5 * time.Second):
		t.Error("the event never arrived")
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Error("read never saw the end of the connection")
	}
}

// Reading a state broadcast, as read does for every one of them, over
// the buffer a handshake leaves on the connection.
func BenchmarkReadState(b *testing.B) {
	line := stateLine(b)
	b.SetBytes(int64(len(line)))
	b.ReportAllocs()
	for b.Loop() {
		c := &Client{
			closed:  make(chan struct{}),
			onEvent: func(proto.Message) {},
			pending: map[int64]chan response{},
		}
		c.read(bufio.NewReaderSize(bytes.NewReader(line), 64<<10))
	}
}
