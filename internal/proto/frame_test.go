package proto

import (
	"bytes"
	"io"
	"testing"
)

// framesOf is the wire of a connection carrying frames, in order.
func framesOf(frames ...frame) []byte {
	var wire bytes.Buffer
	for _, f := range frames {
		WriteFrame(&wire, f.kind, f.payload)
	}
	return wire.Bytes()
}

// outputFrames is what a session sends as it works: count frames of output,
// size bytes each.
func outputFrames(count, size int) []frame {
	payload := bytes.Repeat([]byte("output"), size/6+1)[:size]
	frames := make([]frame, count)
	for i := range frames {
		frames[i] = frame{kind: FrameOutput, payload: payload}
	}
	return frames
}

// Reading a connection's frames one at a time, as ReadFrame does, makes a
// buffer for each of them.
func BenchmarkReadFrame(b *testing.B) {
	wire := framesOf(outputFrames(200, 512)...)
	b.SetBytes(int64(len(wire)))
	b.ReportAllocs()
	for b.Loop() {
		r := bytes.NewReader(wire)
		for {
			if _, _, err := ReadFrame(r); err != nil {
				break
			}
		}
	}
}

// A FrameReader reads the same frames into the one buffer it keeps.
func BenchmarkFrameReader(b *testing.B) {
	wire := framesOf(outputFrames(200, 512)...)
	b.SetBytes(int64(len(wire)))
	b.ReportAllocs()
	for b.Loop() {
		f := NewFrameReader(bytes.NewReader(wire))
		for {
			if _, _, err := f.Read(); err != nil {
				break
			}
		}
	}
}

type frame struct {
	kind    byte
	payload []byte
}

// A reader gives the frames in the order the connection carries them,
// whatever they are, and says nothing when they run out.
func TestFrameReaderInOrder(t *testing.T) {
	want := []frame{
		{FrameOutput, []byte("first")},
		{FrameResized, ResizePayload(120, 40)},
		{FrameOutput, []byte("second")},
		{FrameClosed, nil},
		{FrameOutput, []byte("third")},
	}
	f := NewFrameReader(bytes.NewReader(framesOf(want...)))
	for i, w := range want {
		kind, payload, err := f.Read()
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if kind != w.kind || !bytes.Equal(payload, w.payload) {
			t.Errorf("frame %d is %q %q, want %q %q", i, kind, payload, w.kind, w.payload)
		}
	}
	if _, _, err := f.Read(); err != io.EOF {
		t.Errorf("past the last frame: %v, want EOF", err)
	}
}

// A reader keeps one buffer for the frames it reads, so that reading them
// costs nothing: a frame of the size the last one had takes the buffer the
// last one had. The buffer grows to the frames there are and no further,
// and a frame past what a reader keeps, as a terminal's with the pixels of
// an image, takes a buffer of its own, which the reader does not hold.
func TestFrameReaderKeepsItsBuffer(t *testing.T) {
	f := NewFrameReader(bytes.NewReader(framesOf(
		frame{FrameOutput, []byte("a")},
		frame{FrameOutput, bytes.Repeat([]byte("b"), 1000)},
		frame{FrameOutput, []byte("c")},
		frame{FrameOutput, bytes.Repeat([]byte("d"), frameKeep+1)},
		frame{FrameOutput, []byte("e")},
	)))
	var kept []byte // the buffer the reader keeps, as the last frame had it
	for i, want := range []int{1, 1000, 1, frameKeep + 1, 1} {
		_, payload, err := f.Read()
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if len(payload) != want {
			t.Fatalf("frame %d carries %d bytes, want %d", i, len(payload), want)
		}
		if want > frameKeep {
			// A frame past what a reader keeps: a buffer of its own, and
			// the reader's is still the one the frames around it take.
			if cap(payload) <= frameKeep {
				t.Errorf("a frame of %d bytes took a buffer of %d", want, cap(payload))
			}
			continue
		}
		if cap(payload) > frameKeep {
			t.Errorf("a frame of %d bytes took a buffer of %d, past frameKeep", want, cap(payload))
		}
		if kept == nil || cap(payload) > cap(kept) {
			kept = payload // the reader's buffer grew to this frame
			continue
		}
		if &payload[0] != &kept[0] {
			t.Errorf("frame %d took a buffer of its own, of %d bytes", i, cap(payload))
		}
	}
}

// A frame past what a connection carries is a stream gone wrong: the
// reader says so, as ReadFrame does, rather than read it.
func TestFrameTooLarge(t *testing.T) {
	big := bytes.Repeat([]byte("x"), maxFrame+1)
	var wire bytes.Buffer
	hdr := make([]byte, 5)
	hdr[0] = FrameOutput
	hdr[1], hdr[2], hdr[3], hdr[4] = byte(len(big)>>24), byte(len(big)>>16), byte(len(big)>>8), byte(len(big))
	wire.Write(hdr)
	wire.Write(big)
	f := NewFrameReader(bytes.NewReader(wire.Bytes()))
	_, _, err := f.Read()
	if err == nil || !bytes.Contains([]byte(err.Error()), []byte("too large")) {
		t.Errorf("a frame of %d bytes: %v", len(big), err)
	}
	if _, _, err := ReadFrame(bytes.NewReader(wire.Bytes())); err == nil {
		t.Errorf("ReadFrame took a frame of %d bytes", len(big))
	}
}
