//go:build darwin || linux

package cli

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"golang.org/x/term"

	"kero/internal/proto"
)

// fakeKerod answers attach connections as kerod does, over pipes.
type fakeKerod struct {
	fail   error
	opened chan *fakeStream
	cols   int
	rows   int
	first  string
}

// fakeStream is a stream's far end, with the frames its client sent.
type fakeStream struct {
	conn   net.Conn
	frames chan fakeFrame
}

type fakeFrame struct {
	kind    byte
	payload []byte
}

func (k *fakeKerod) Dial() (net.Conn, error) {
	if k.fail != nil {
		return nil, k.fail
	}
	here, there := net.Pipe()
	go func() {
		r := bufio.NewReader(there)
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var hello proto.Hello
		json.Unmarshal(line, &hello)
		json.NewEncoder(there).Encode(proto.Welcome{Version: proto.Version, Cols: k.cols, Rows: k.rows})
		s := &fakeStream{conn: there, frames: make(chan fakeFrame, 256)}
		// Reads apart from the first frame's write: a pipe holds nothing, as a
		// socket does.
		go func() {
			for {
				kind, payload, err := proto.ReadFrame(r)
				if err != nil {
					close(s.frames)
					return
				}
				s.frames <- fakeFrame{kind, payload}
			}
		}()
		proto.WriteFrame(there, proto.FrameOutput, []byte(k.first))
		k.opened <- s
	}()
	return here, nil
}

// expect waits for a frame of the kind, returning it, past others.
func (s *fakeStream) expect(t *testing.T, kind byte) []byte {
	t.Helper()
	timeout := time.After(5 * time.Second)
	for {
		select {
		case f, ok := <-s.frames:
			if !ok {
				t.Fatalf("the stream ended, waiting for a frame %q", kind)
			}
			if f.kind == kind {
				return f.payload
			}
		case <-timeout:
			t.Fatalf("no frame %q", kind)
		}
	}
}

// attachRun is an attachment in a pty, as a test watches it.
type attachRun struct {
	t       *testing.T
	master  *os.File
	slave   *os.File
	kerod   *fakeKerod
	before  *term.State
	signals chan os.Signal
	resized chan struct{}
	exited  chan int
	lost    chan struct{}
	ended   chan attachEnd
	err     error

	closing atomic.Bool
	mu      sync.Mutex
	out     bytes.Buffer
}

func startAttach(t *testing.T, cols, rows int, kerod *fakeKerod) *attachRun {
	t.Helper()
	old := attachHintPause
	attachHintPause = 0
	t.Cleanup(func() { attachHintPause = old })
	master, slave := openPTY(t)
	if err := unix.IoctlSetWinsize(int(slave.Fd()), unix.TIOCSWINSZ, &unix.Winsize{Col: uint16(cols), Row: uint16(rows)}); err != nil {
		t.Fatal(err)
	}
	before, err := term.GetState(int(slave.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	if kerod.opened == nil {
		kerod.opened = make(chan *fakeStream, 8)
	}
	if kerod.cols == 0 {
		kerod.cols, kerod.rows = cols, rows
	}
	r := &attachRun{t: t, master: master, slave: slave, kerod: kerod, before: before,
		signals: make(chan os.Signal, 1), resized: make(chan struct{}, 1), exited: make(chan int, 1), lost: make(chan struct{}), ended: make(chan attachEnd, 1)}
	masterFD := int(master.Fd())
	go func() {
		buf := make([]byte, 4096)
		for {
			// A read waiting on it would keep a Close from closing it.
			if n, _ := unix.Poll([]unix.PollFd{{Fd: int32(masterFD), Events: unix.POLLIN}}, 20); n <= 0 {
				if r.closing.Load() {
					return
				}
				continue
			}
			n, err := master.Read(buf)
			r.mu.Lock()
			r.out.Write(buf[:n])
			r.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	go func() {
		end, err := runAttach(attachConfig{dial: kerod, pane: "p1", label: "a session", client: "test", in: slave, out: slave,
			keyName: `ctrl+\`, key: detachMatcher{legacy: 0x1c, code: 92},
			signals: r.signals, resized: r.resized, exited: r.exited, lost: r.lost})
		r.err = err
		r.ended <- end
	}()
	return r
}

func (r *attachRun) output() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.out.String()
}

func (r *attachRun) waitOutput(want string) {
	r.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(r.output(), want) {
		if time.Now().After(deadline) {
			r.t.Fatalf("no %q in the output: %q", want, r.output())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (r *attachRun) stream() *fakeStream {
	r.t.Helper()
	select {
	case s := <-r.kerod.opened:
		return s
	case <-time.After(5 * time.Second):
		r.t.Fatal("no stream opened")
		return nil
	}
}

// wait returns how it ended, checking that the terminal is as it was.
func (r *attachRun) wait() attachEnd {
	r.t.Helper()
	select {
	case end := <-r.ended:
		r.checkRestored()
		return end
	case <-time.After(10 * time.Second):
		r.t.Fatalf("it didn't end: %q", r.output())
		return attachEnd{}
	}
}

func (r *attachRun) checkRestored() {
	r.t.Helper()
	after, err := term.GetState(int(r.slave.Fd()))
	if err != nil {
		r.t.Fatal(err)
	}
	if !reflect.DeepEqual(r.before, after) {
		r.t.Errorf("the terminal's settings stayed changed: %+v, were %+v", after, r.before)
	}
	want := attachLeave(false)
	deadline := time.Now().Add(5 * time.Second)
	for !strings.HasSuffix(r.output(), want) {
		if time.Now().After(deadline) {
			r.t.Errorf("the output doesn't end in the restoring sequences: %q", r.output())
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestAttachOnEveryWayOut(t *testing.T) {
	for _, tt := range []struct {
		name string
		do   func(r *attachRun, s *fakeStream)
		want attachEnd
	}{
		{"detach key", func(r *attachRun, s *fakeStream) { r.master.Write([]byte{0x1c}) }, attachEnd{kind: endDetached}},
		{"detach key, as the keyboard protocol sends it", func(r *attachRun, s *fakeStream) { r.master.Write([]byte("\x1b[92;5u")) }, attachEnd{kind: endDetached}},
		{"SIGTERM", func(r *attachRun, s *fakeStream) { r.signals <- syscall.SIGTERM }, attachEnd{kind: endSignal, code: 15}},
		{"SIGHUP", func(r *attachRun, s *fakeStream) { r.signals <- syscall.SIGHUP }, attachEnd{kind: endSignal, code: 1}},
		{"the pane's program failing", func(r *attachRun, s *fakeStream) { r.exited <- 3 }, attachEnd{kind: endExited, code: 3}},
		{"the pane closing", func(r *attachRun, s *fakeStream) {
			proto.WriteFrame(s.conn, proto.FrameClosed, nil)
			s.conn.Close()
		}, attachEnd{kind: endClosed}},
		{"kerod going away", func(r *attachRun, s *fakeStream) {
			r.kerod.fail = errors.New("no kerod")
			s.conn.Close()
			close(r.lost)
		}, attachEnd{kind: endLost}},
		{"kerod going away, its control connection last", func(r *attachRun, s *fakeStream) {
			r.kerod.fail = errors.New("no kerod")
			s.conn.Close()
		}, attachEnd{kind: endLost}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			k := &fakeKerod{first: "\x1b[?2004h\x1b[Hthe pane's screen"}
			r := startAttach(t, 80, 24, k)
			s := r.stream()
			r.waitOutput("the pane's screen")
			now, _ := term.GetState(int(r.slave.Fd()))
			if reflect.DeepEqual(now, r.before) {
				t.Error("attached, the terminal isn't raw")
			}
			r.master.Write([]byte("typed"))
			if got := s.expect(t, proto.FrameInput); string(got) != "typed" {
				t.Errorf("input %q", got)
			}
			tt.do(r, s)
			if end := r.wait(); end != tt.want {
				t.Errorf("ended %+v, want %+v", end, tt.want)
			}
			out := r.output()
			if i, j := strings.Index(out, attachEnter), strings.Index(out, "the pane's screen"); i < 0 || j < i {
				t.Errorf("the pane didn't show on the alternate screen: %q", out)
			}
			if !strings.Contains(out, "Press ctrl+\\ to detach") {
				t.Errorf("the detach key didn't show: %q", out)
			}
		})
	}
}

// A kerod that can't be reached from the start leaves the terminal as it was
// too.
func TestAttachFailing(t *testing.T) {
	r := startAttach(t, 80, 24, &fakeKerod{fail: errors.New("no kerod")})
	if end := r.wait(); end.kind != endLost {
		t.Errorf("ended %+v", end)
	}
}

// The terminal going, as an SSH client's connection, ends it without a fuss.
func TestAttachHangup(t *testing.T) {
	r := startAttach(t, 80, 24, &fakeKerod{})
	r.stream()
	r.closing.Store(true)
	time.Sleep(50 * time.Millisecond)
	r.master.Close()
	select {
	case end := <-r.ended:
		if end.kind != endHangup {
			t.Errorf("ended %+v", end)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("it didn't end")
	}
}

// The terminal asks the pane for its size and takes it from the start, as the
// user is at it, and as it resizes.
func TestAttachSizes(t *testing.T) {
	k := &fakeKerod{cols: 120, rows: 40, first: "\x1b[Hat the old size"}
	r := startAttach(t, 80, 24, k)
	s := r.stream()
	cols, rows, _, _, ok := proto.ParseResizePixels(s.expect(t, proto.FrameResize))
	if !ok || cols != 80 || rows != 24 {
		t.Errorf("asked %dx%d", cols, rows)
	}
	s.expect(t, proto.FrameClaim)
	// Nothing of the old size draws: it wouldn't fit.
	proto.WriteFrame(s.conn, proto.FrameResized, proto.ResizePayload(80, 24))
	proto.WriteFrame(s.conn, proto.FrameOutput, []byte("\x1b[Hat the new size"))
	r.waitOutput("at the new size")
	if strings.Contains(r.output(), "at the old size") {
		t.Errorf("drew at another size: %q", r.output())
	}

	if err := unix.IoctlSetWinsize(int(r.slave.Fd()), unix.TIOCSWINSZ, &unix.Winsize{Col: 100, Row: 30}); err != nil {
		t.Fatal(err)
	}
	r.resized <- struct{}{}
	cols, rows, _, _, _ = proto.ParseResizePixels(s.expect(t, proto.FrameResize))
	if cols != 100 || rows != 30 {
		t.Errorf("asked %dx%d after a resize", cols, rows)
	}
	s.expect(t, proto.FrameClaim)
	r.master.Write([]byte{0x1c})
	r.wait()
}

// Another client taking the pane holds what would draw at its size, says so
// after a moment, and the first key takes the pane back, going no further.
func TestAttachAnotherClientTakesThePane(t *testing.T) {
	k := &fakeKerod{first: "\x1b[Hthe pane"}
	r := startAttach(t, 80, 24, k)
	s := r.stream()
	r.waitOutput("the pane")
	s.expect(t, proto.FrameClaim)

	proto.WriteFrame(s.conn, proto.FrameResized, proto.ResizePayload(200, 50))
	proto.WriteFrame(s.conn, proto.FrameOutput, []byte("\x1b[Hdrawn for the other client"))
	r.waitOutput("Another client shows this pane at 200x50")
	if strings.Contains(r.output(), "drawn for the other client") {
		t.Errorf("drew at another size: %q", r.output())
	}

	r.master.Write([]byte("x"))
	s.expect(t, proto.FrameResize)
	s.expect(t, proto.FrameClaim)
	proto.WriteFrame(s.conn, proto.FrameResized, proto.ResizePayload(80, 24))
	// The notice is on the screen: a new stream draws it all.
	s2 := r.stream()
	s2.expect(t, proto.FrameResize)
	s2.expect(t, proto.FrameClaim) // it's this terminal's again
	// The old stream closes, with all it got.
	for f := range s.frames {
		if f.kind == proto.FrameInput {
			t.Errorf("the key that took the pane back went to it: %q", f.payload)
		}
	}
	r.master.Write([]byte("y"))
	if got := s2.expect(t, proto.FrameInput); string(got) != "y" {
		t.Errorf("input %q", got)
	}
	r.master.Write([]byte{0x1c})
	r.wait()
}

// A focus report, which a terminal sends on its own, doesn't take the pane
// back.
func TestAttachFocusReportClaimsNothing(t *testing.T) {
	k := &fakeKerod{first: "\x1b[Hthe pane"}
	r := startAttach(t, 80, 24, k)
	s := r.stream()
	s.expect(t, proto.FrameClaim)
	proto.WriteFrame(s.conn, proto.FrameResized, proto.ResizePayload(200, 50))
	r.waitOutput("Another client")
	r.master.Write([]byte("\x1b[I"))
	if got := s.expect(t, proto.FrameInput); string(got) != "\x1b[I" {
		t.Errorf("input %q", got)
	}
	r.master.Write([]byte{0x1c})
	r.wait()
}

// The pane leaving its alternate screen takes a new stream, which leaves the
// old one's claim to the new, and the old let go of last.
func TestAttachReopensLeavingAlternateScreen(t *testing.T) {
	k := &fakeKerod{first: "\x1b[Hthe pane"}
	r := startAttach(t, 80, 24, k)
	s := r.stream()
	r.waitOutput("the pane")
	proto.WriteFrame(s.conn, proto.FrameOutput, []byte("\x1b[?1049h\x1b[1Hvim\x1b[?1049l\x1b[1Hstale"))
	s2 := r.stream()
	s2.expect(t, proto.FrameClaim)
	r.waitOutput("vim")
	if strings.Contains(r.output(), "stale") {
		t.Errorf("drew past leaving: %q", r.output())
	}
	for range s.frames { // the old stream closes, after the new one claimed
	}
	r.master.Write([]byte{0x1c})
	r.wait()
}

// kerod drops a client too far behind, which is to attach again, not to
// end.
func TestAttachAgainAfterBeingDropped(t *testing.T) {
	k := &fakeKerod{first: "\x1b[Hthe pane"}
	r := startAttach(t, 80, 24, k)
	s := r.stream()
	s.conn.Close()
	s2 := r.stream()
	s2.expect(t, proto.FrameClaim)
	r.master.Write([]byte{0x1c})
	if end := r.wait(); end.kind != endDetached {
		t.Errorf("ended %+v", end)
	}
}
