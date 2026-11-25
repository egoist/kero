//go:build darwin || linux

package daemon

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"testing"

	"kero/internal/proto"
)

func TestSendReportsInputFailure(t *testing.T) {
	p := testPane(t)
	p.d.panes = map[string]*pane{p.info.ID: p}
	cli := &controlConn{done: make(chan struct{})}
	raw, err := json.Marshal(proto.SendParams{ID: p.info.ID, Data: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	call := func() (any, error) { return p.d.call(cli, "send", raw) }

	if _, err := call(); !errors.Is(err, errNoShell) {
		t.Fatalf("send to ended shell: %v", err)
	}

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	p.proc = &ptyProc{master: w}
	if got, err := call(); err != nil || got != true {
		t.Fatalf("send to open terminal: result %v, error %v", got, err)
	}
	buf := make([]byte, len("hello"))
	if _, err := io.ReadFull(r, buf); err != nil || string(buf) != "hello" {
		t.Fatalf("terminal received %q, error %v", buf, err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := call(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("send to closed terminal: %v", err)
	}
}
