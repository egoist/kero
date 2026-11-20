package daemon

import (
	"bytes"
	"io"
	"log"
	"testing"

	"kero/internal/proto"
)

// clientFrame is a frame a client sends a session: its kind and what it
// carries.
type clientFrame struct {
	kind    byte
	payload []byte
}

// framesOfClient is the wire of the frames a client sends a session, in
// order.
func framesOfClient(frames ...clientFrame) []byte {
	var wire bytes.Buffer
	for _, f := range frames {
		proto.WriteFrame(&wire, f.kind, f.payload)
	}
	return wire.Bytes()
}

// The frames a client sends a session are read into the one buffer the
// reader keeps, and do with the session what they carry: its size, the
// theme the client shows, and who is at the terminal.
func TestServeFrames(t *testing.T) {
	d := listenDaemon(t)
	s := testPane(t)
	s.info.ID = "p"
	a := newAttachment(nil)
	defer a.finish()
	if _, _, _, ok := s.attach(a); !ok {
		t.Fatal("the client did not attach")
	}
	theme := proto.Theme{Foreground: [4]byte{1, 2, 3, 4}}
	wire := framesOfClient(
		clientFrame{proto.FrameTheme, theme.Payload()},
		clientFrame{proto.FrameResize, proto.ResizePixelsPayload(120, 40, 0, 0)},
		clientFrame{proto.FrameClaim, nil},
	)
	d.serveFrames(s, a, proto.NewFrameReader(bytes.NewReader(wire)))

	if d.theme.Load() == nil {
		t.Error("the theme the client sent did not reach the daemon")
	}
	if s.info.Cols != 120 || s.info.Rows != 40 {
		t.Errorf("the pane is %dx%d, want 120x40", s.info.Cols, s.info.Rows)
	}
	if s.claimer != a {
		t.Error("the client that claimed the pane is not the one that did")
	}
}

// benchPane is a pane with a terminal and no program, for a benchmark.
func benchPane(b *testing.B) *pane {
	b.Helper()
	d := &Daemon{log: log.New(io.Discard, "", 0), changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1)}
	d.viewed.Store(new(string))
	s, err := newPane(d, "s", proto.Pane{ID: "p", Status: proto.Idle, Cols: 96, Rows: 28})
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { s.term.Close() })
	return s
}

// The frames a client sends are read into the one buffer the reader keeps,
// so that reading them costs nothing: a client sends a frame for every
// keystroke and every mouse report.
func BenchmarkServeFrames(b *testing.B) {
	s := benchPane(b)
	a := newAttachment(nil)
	defer a.finish()
	s.attach(a)
	var wire bytes.Buffer
	for range 100 {
		proto.WriteFrame(&wire, proto.FrameInput, []byte("a keystroke"))
	}
	b.SetBytes(int64(wire.Len()))
	b.ReportAllocs()
	for b.Loop() {
		s.d.serveFrames(s, a, proto.NewFrameReader(bytes.NewReader(wire.Bytes())))
	}
}

// The same frames read one at a time, each into a buffer of its own, as
// the daemon read them before: the same work, over the same frames.
func BenchmarkServeFramesOneByOne(b *testing.B) {
	s := benchPane(b)
	a := newAttachment(nil)
	defer a.finish()
	s.attach(a)
	var wire bytes.Buffer
	for range 100 {
		proto.WriteFrame(&wire, proto.FrameInput, []byte("a keystroke"))
	}
	b.SetBytes(int64(wire.Len()))
	b.ReportAllocs()
	for b.Loop() {
		serveFramesOneByOne(s, a, bytes.NewReader(wire.Bytes()))
	}
}

// serveFramesOneByOne is what the daemon did with the frames a client
// sent, before it read them into the one buffer a reader keeps.
func serveFramesOneByOne(s *pane, a *attachment, r io.Reader) {
	for {
		kind, payload, err := proto.ReadFrame(r)
		if err != nil {
			return
		}
		switch kind {
		case proto.FrameInput:
			if typed(payload) {
				s.claim(a)
			}
			s.input(payload)
		case proto.FrameResize:
			if c, rr, cw, ch, ok := proto.ParseResizePixels(payload); ok {
				s.ask(a, c, rr, cw, ch)
			}
		case proto.FrameClaim:
			s.claim(a)
		case proto.FrameTheme:
			if th, ok := proto.ParseTheme(payload); ok {
				s.d.useTheme(th)
			}
		case proto.FrameClear:
			if len(payload) == 1 {
				s.clear(payload[0])
			}
		}
	}
}
