package daemon

import (
	"bytes"
	"io"
	"net"
	"testing"

	"kero/internal/proto"
)

// framesOfOutput is what a session sends a client as it works: count
// frames of output, size bytes each, each of them its own.
func framesOfOutput(count, size int) [][]byte {
	frames := make([][]byte, count)
	for i := range frames {
		frames[i] = bytes.Repeat([]byte{byte(i)}, size)
	}
	return frames
}

// The frames a session sends a client come back as they went, whatever
// the buffers they went out in.
func TestAttachmentFrames(t *testing.T) {
	c, s := net.Pipe()
	defer c.Close()
	a := newAttachment(s)
	defer a.finish()
	go a.write()
	want := framesOfOutput(50, 4096)
	for _, p := range want {
		a.send(proto.FrameOutput, p)
	}
	f := proto.NewFrameReader(c)
	for i, w := range want {
		kind, payload, err := f.Read()
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if kind != proto.FrameOutput || !bytes.Equal(payload, w) {
			t.Errorf("frame %d came back as %d bytes of %q, want %d of %q",
				i, len(payload), payload[:min(8, len(payload))], len(w), w[:min(8, len(w))])
		}
	}
}

// Sending the frames a session sends, as a pane's frame does for every
// client attached: each of them went out in a buffer of its own.
func BenchmarkAttachmentSend(b *testing.B) {
	const frames = 100
	payload := bytes.Repeat([]byte("output"), 4096/6+1)[:4096]
	b.SetBytes(int64(len(payload) * frames))
	b.ReportAllocs()
	buf := make([]byte, 64<<10) // the reader's, outside the loop's cost
	for b.Loop() {
		c, s := net.Pipe()
		a := newAttachment(s)
		go a.write()
		read := make(chan struct{})
		go func() {
			defer close(read)
			for range frames {
				if _, err := io.ReadFull(c, buf[:5+len(payload)]); err != nil {
					return
				}
			}
		}()
		for range frames {
			a.send(proto.FrameOutput, payload)
		}
		<-read
		a.finish()
		c.Close()
	}
}
