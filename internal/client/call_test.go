package client

import (
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"
)

// A call made after the connection ended is an error, not a wait that
// never ends: nobody answers a call the daemon is no longer there to
// hear.
func TestCallAfterTheConnectionEnded(t *testing.T) {
	conn, peer := net.Pipe()
	defer peer.Close()
	go io.Copy(io.Discard, peer)
	c := &Client{
		conn:    conn,
		enc:     json.NewEncoder(conn),
		pending: map[int64]chan response{},
		closed:  make(chan struct{}),
	}
	// The connection ended: the reader is gone, and no answer will
	// come.
	close(c.closed)

	done := make(chan error, 1)
	go func() { done <- c.Call("state", nil, nil) }()
	select {
	case err := <-done:
		if err == nil {
			t.Error("the call succeeded on a connection that had ended")
		}
	case <-time.After(5 * time.Second):
		t.Error("the call never ended")
	}
}
