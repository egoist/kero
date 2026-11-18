package client

import (
	"bytes"
	"io"
	"testing"

	"kero/internal/proto"
)

// wireOf makes the bytes of a connection carrying frames of output: count
// frames of size bytes each, as kerod sends a session's output.
func wireOf(count, size int) []byte {
	frame := bytes.Repeat([]byte("output"), size/6+1)[:size]
	var wire bytes.Buffer
	wire.Grow(count * (size + 5))
	for range count {
		proto.WriteFrame(&wire, proto.FrameOutput, frame)
	}
	return wire.Bytes()
}

// A stream over wire, read as the terminal plugin reads one: into a buffer
// of its own, until the frames run out.
func readWire(b *testing.B, wire []byte) int {
	s := streamOver(bytes.NewReader(wire))
	buf := make([]byte, 64<<10)
	n := 0
	for {
		got, err := s.Read(buf)
		n += got
		if err != nil {
			return n
		}
	}
}

// A session's output arrives in small frames as it works: a few lines at a
// time, each of which the stream read makes a buffer for.
func BenchmarkStreamSmallFrames(b *testing.B) {
	wire := wireOf(200, 512)
	b.SetBytes(int64(len(wire)))
	b.ReportAllocs()
	for b.Loop() {
		if n := readWire(b, wire); n != len(wire)-200*5 {
			b.Fatalf("read %d bytes", n)
		}
	}
}

// A frame carries a screen's worth of output when a session starts or
// clears, which is bigger than the plugin's read buffer.
func BenchmarkStreamBigFrames(b *testing.B) {
	wire := wireOf(64, 64<<10)
	b.SetBytes(int64(len(wire)))
	b.ReportAllocs()
	for b.Loop() {
		if n := readWire(b, wire); n != len(wire)-64*5 {
			b.Fatalf("read %d bytes", n)
		}
	}
}

// A stream that has ended costs nothing to read.
func BenchmarkStreamEOF(b *testing.B) {
	s := streamOver(bytes.NewReader(nil))
	b.ReportAllocs()
	buf := make([]byte, 64<<10)
	for b.Loop() {
		if _, err := s.Read(buf); err != io.EOF {
			b.Fatal(err)
		}
	}
}
