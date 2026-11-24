package client

import (
	"bytes"
	"errors"
	"net"
	"testing"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

// recorder is a connection that keeps what was written to it.
type recorder struct {
	net.Conn
	buf bytes.Buffer
}

func (c *recorder) Write(p []byte) (int, error) { return c.buf.Write(p) }

// counter is a connection that counts what was written to it.
type counter struct {
	net.Conn
	n int
}

func (c *counter) Write(p []byte) (int, error) { c.n += len(p); return len(p), nil }

// failing is a connection that cannot be closed.
type failing struct {
	net.Conn
	closed int
}

func (c *failing) Close() error {
	c.closed++
	return errors.New("the connection is gone")
}

// The frames a stream writes are the frames it writes one at a time, to
// the byte: what a client sends a daemon is what the daemon reads.
func TestStreamWritesFrames(t *testing.T) {
	c := &recorder{}
	s := &Stream{conn: c, closed: make(chan struct{}), Gone: make(chan struct{})}
	theme := &terminal.Theme{Foreground: ui.Color{R: 1, G: 2, B: 3, A: 4}}

	if _, err := s.Write([]byte("a keystroke")); err != nil {
		t.Fatal(err)
	}
	if err := s.ResizePixels(80, 24, 10, 20); err != nil {
		t.Fatal(err)
	}
	if err := s.Claim(); err != nil {
		t.Fatal(err)
	}
	if err := s.UseTheme(theme); err != nil {
		t.Fatal(err)
	}
	if err := s.Clear(proto.ClearScreen); err != nil {
		t.Fatal(err)
	}

	var want bytes.Buffer
	proto.WriteFrame(&want, proto.FrameInput, []byte("a keystroke"))
	proto.WriteFrame(&want, proto.FrameResize, proto.ResizePixelsPayload(80, 24, 10, 20))
	proto.WriteFrame(&want, proto.FrameClaim, nil)
	proto.WriteFrame(&want, proto.FrameTheme, proto.Theme{
		Foreground: [4]byte{1, 2, 3, 4},
	}.Payload())
	proto.WriteFrame(&want, proto.FrameClear, []byte{proto.ClearScreen})
	if !bytes.Equal(c.buf.Bytes(), want.Bytes()) {
		t.Errorf("wrote %q, want %q", c.buf.Bytes(), want.Bytes())
	}
}

// A stream is closed once, and every close of it says the same: a
// second close said it closed, though the first one did not.
func TestStreamCloseSaysItFailed(t *testing.T) {
	c := &failing{}
	s := &Stream{conn: c, closed: make(chan struct{}), Gone: make(chan struct{})}
	err := s.Close()
	if err == nil {
		t.Fatal("the close said it worked")
	}
	if err2 := s.Close(); err2 == nil || err2.Error() != err.Error() {
		t.Errorf("the second close said %v, want %v", err2, err)
	}
	if c.closed != 1 {
		t.Errorf("the connection was closed %d times", c.closed)
	}
}

// A paste of a megabyte or more takes a buffer of its own, which the
// stream does not keep: it would hold it for the connection's life.
func TestStreamDropsABigBuffer(t *testing.T) {
	c := &counter{}
	s := &Stream{conn: c, closed: make(chan struct{}), Gone: make(chan struct{})}
	if _, err := s.Write(bytes.Repeat([]byte("x"), 2<<20)); err != nil {
		t.Fatal(err)
	}
	if cap(s.wbuf) != 0 {
		t.Errorf("the stream kept a buffer of %d bytes", cap(s.wbuf))
	}
	// A keystroke after it takes a buffer again.
	if _, err := s.Write([]byte("a keystroke")); err != nil {
		t.Fatal(err)
	}
	if cap(s.wbuf) == 0 {
		t.Error("the stream kept no buffer for a keystroke")
	}
}

// A client sends a frame for every keystroke: the frames are written
// into the one buffer the stream keeps.
func BenchmarkStreamWrite(b *testing.B) {
	c := &counter{}
	s := &Stream{conn: c, closed: make(chan struct{}), Gone: make(chan struct{})}
	b.ReportAllocs()
	for b.Loop() {
		if _, err := s.Write([]byte("a keystroke")); err != nil {
			b.Fatal(err)
		}
	}
}

// The same frame written into a buffer of its own, as the stream wrote it
// before.
func BenchmarkStreamWriteOneByOne(b *testing.B) {
	c := &counter{}
	b.ReportAllocs()
	for b.Loop() {
		if err := proto.WriteFrame(c, proto.FrameInput, []byte("a keystroke")); err != nil {
			b.Fatal(err)
		}
	}
}
