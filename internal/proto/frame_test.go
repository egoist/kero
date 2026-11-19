package proto

import (
	"bufio"
	"bytes"
	"errors"
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

// A frame goes into a buffer made for it, whatever its size, and takes
// none of its own: the buffer the pool keeps comes back, or one at least
// as large.
func TestFrameBuffers(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), 16<<10)
	for _, size := range []int{5, 6, 5 + len(payload), 5 + maxOutput, 5 + maxOutput + 1} {
		buf := GetFrame(size)
		if cap(buf) < size {
			t.Errorf("a buffer for a frame of %d bytes has %d", size, cap(buf))
		}
		PutFrame(buf)
		if again := GetFrame(size); cap(again) < size {
			t.Errorf("a buffer that came back has %d bytes, want %d", cap(again), size)
		}
	}
	buf := GetFrame(5 + len(payload))
	if n := testing.AllocsPerRun(10, func() {
		buf = AppendFrames(buf[:0], FrameOutput, payload)
	}); n != 0 {
		t.Errorf("a frame into a buffer made for it took %v allocations", n)
	}
	PutFrame(buf)
}

// A frame of output goes into a buffer of its own, which AppendFrames
// grows as it fills it, as a session's frames did.
func BenchmarkAppendFrames(b *testing.B) {
	payload := bytes.Repeat([]byte("output"), 4096/6+1)[:4096]
	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	for b.Loop() {
		AppendFrames(nil, FrameOutput, payload)
	}
}

// A frame of output goes into a buffer made for it, which takes none of
// its own.
func BenchmarkAppendFramesSized(b *testing.B) {
	payload := bytes.Repeat([]byte("output"), 4096/6+1)[:4096]
	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	size := 5 + len(payload)
	buf := make([]byte, 0, size)
	for b.Loop() {
		buf = AppendFrames(buf[:0], FrameOutput, payload)
	}
}

// A frame of output goes into a buffer the pool keeps, which comes back
// once the connection has taken it.
func BenchmarkFrameBuffers(b *testing.B) {
	payload := bytes.Repeat([]byte("output"), 4096/6+1)[:4096]
	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	size := 5 + len(payload)
	for b.Loop() {
		PutFrame(AppendFrames(GetFrame(size), FrameOutput, payload))
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

// A line that fits in the reader's buffer comes back without a copy of
// its own, one that doesn't is assembled into a buffer of its own, and a
// line past max is refused either way.
func TestReadLine(t *testing.T) {
	// Fast path: the whole line in one fill of the buffer, which comes
	// back without a copy of its own.
	r := bufio.NewReaderSize(bytes.NewReader(bytes.Repeat([]byte("first\n"), 16)), 64)
	got, err := ReadLine(r, 100)
	if err != nil || string(got) != "first\n" {
		t.Errorf("first line %q, %v", got, err)
	}
	if n := testing.AllocsPerRun(5, func() {
		if _, err := ReadLine(r, 100); err != nil {
			t.Error(err)
		}
	}); n != 0 {
		t.Errorf("a line in the buffer took %v allocations, want none", n)
	}
	// Slow path: a line longer than the reader's buffer.
	r = bufio.NewReaderSize(bytes.NewReader([]byte("0123456789abcdefghij\n")), 8)
	got, err = ReadLine(r, 100)
	if err != nil || string(got) != "0123456789abcdefghij\n" {
		t.Errorf("long line %q, %v", got, err)
	}
	// A line past max is refused, in the buffer and across it.
	for _, c := range []struct {
		data string
		max  int
	}{
		{"toolong\n", 4},
		{"0123456789abcdefghij\n", 10},
	} {
		r = bufio.NewReaderSize(bytes.NewReader([]byte(c.data)), 8)
		if _, err := ReadLine(r, c.max); !errors.Is(err, ErrLineTooLong) {
			t.Errorf("line of %q past %d: %v, want ErrLineTooLong", c.data, c.max, err)
		}
	}
	// A last line without its newline ends in EOF, as its reader does.
	r = bufio.NewReader(bytes.NewReader([]byte("no newline")))
	if got, err := ReadLine(r, 100); err != io.EOF || string(got) != "no newline" {
		t.Errorf("line at the end %q, %v; want it and EOF", got, err)
	}
}

// Reading a line of the size a state broadcast is, as every control
// connection does for every message.
func BenchmarkReadLine(b *testing.B) {
	line := append(bytes.Repeat([]byte("x"), 17<<10), '\n')
	b.SetBytes(int64(len(line)))
	b.ReportAllocs()
	r := bufio.NewReaderSize(nil, 64<<10)
	for b.Loop() {
		r.Reset(bytes.NewReader(line))
		if _, err := ReadLine(r, MaxLine); err != nil {
			b.Fatal(err)
		}
	}
}
