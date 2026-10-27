package daemon

import (
	"io"
	"net"
	"testing"
	"time"

	keroclient "kero/internal/client"
	"kero/internal/proto"
)

// attached attaches a client to a pane whose frames go nowhere.
func attached(t *testing.T, s *pane) *attachment {
	t.Helper()
	here, there := net.Pipe()
	go io.Copy(io.Discard, there)
	t.Cleanup(func() { here.Close(); there.Close() })
	a := newAttachment(here)
	if _, _, _, ok := s.attach(a); !ok {
		t.Fatal("attach failed")
	}
	go a.write()
	return a
}

// paneSize returns a check of the pane's size.
func paneSize(t *testing.T, s *pane) func(when string, cols, rows int) {
	return func(when string, cols, rows int) {
		t.Helper()
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.info.Cols != cols || s.info.Rows != rows {
			t.Errorf("%s: %dx%d, want %dx%d", when, s.info.Cols, s.info.Rows, cols, rows)
		}
	}
}

// A pane takes the size of the client the user is in: another client's,
// resized by a layout synced from it, waits until the user is in that one.
func TestPaneSizeClaim(t *testing.T) {
	s := testPane(t)
	size := paneSize(t, s)
	mac, win := attached(t, s), attached(t, s)
	s.ask(mac, 90, 30, 9, 18)
	size("none claimed", 90, 30)
	s.claim(mac) // the user types on the Mac
	s.ask(win, 100, 40, 9, 18)
	size("another client's size", 90, 30)
	s.ask(mac, 80, 30, 9, 18)
	size("the claimer's", 80, 30)
	s.claim(win) // the user moves to Windows
	size("the new claimer's last asked", 100, 40)
	s.claim(win)
	s.ask(mac, 70, 20, 9, 18)
	size("claimed again", 100, 40)
}

// The client claimed in leaving, the pane goes back to the one claimed in
// before it, which shows it at once at its own size rather than cut off
// at the gone one's; none claimed, to the one that asked last.
func TestPaneSizeClaimerLeaves(t *testing.T) {
	s := testPane(t)
	size := paneSize(t, s)
	mac, win, cli := attached(t, s), attached(t, s), attached(t, s)
	s.ask(mac, 90, 30, 9, 18)
	s.ask(win, 100, 40, 9, 18)
	s.ask(cli, 60, 20, 9, 18)
	s.claim(win)
	s.claim(mac)
	size("the Mac's", 90, 30)
	s.detach(mac) // the Mac app quits
	size("back to Windows", 100, 40)
	s.detach(win)
	size("to the one left", 60, 20)
}

// An app that reconnects, its old connection not yet seen gone, as after
// a laptop's sleep, takes the pane with its new one as the user claims it
// there, rather than waiting for the old one to time out.
func TestPaneSizeReconnect(t *testing.T) {
	s := testPane(t)
	size := paneSize(t, s)
	old, win := attached(t, s), attached(t, s)
	s.ask(old, 90, 30, 9, 18)
	s.ask(win, 100, 40, 9, 18)
	s.claim(old)
	s.claim(win)
	s.claim(old)
	size("the Mac's", 90, 30)
	mac := attached(t, s)
	s.ask(mac, 80, 30, 9, 18)
	size("the old connection holds it", 90, 30)
	s.claim(mac)
	size("the new connection's", 80, 30)
	s.detach(old)
	size("the old one gone", 80, 30)
}

// What an app's terminal sends as its pane gains or loses the keyboard,
// which the app may move without the user, claims nothing; the rest is the
// user's.
func TestTyped(t *testing.T) {
	for in, want := range map[string]bool{
		"\x1b[I":       false,
		"\x1b[O":       false,
		"a":            true,
		"\x1b[A":       true,
		"\x1b[<0;3;4M": true,
	} {
		if got := typed([]byte(in)); got != want {
			t.Errorf("typed(%q) = %v, want %v", in, got, want)
		}
	}
}

// serveDialer dials d as the app does this machine's kerod.
type serveDialer struct{ d *Daemon }

func (s serveDialer) Dial() (net.Conn, error) {
	here, there := net.Pipe()
	go s.d.serve(there, identity{peer: "uid 501", via: "unix"})
	return here, nil
}

// Two apps' streams of a shell's pane, as from two machines: the pane
// takes the size of the one the user types in, not the focus reports an
// app's terminal sends unasked, and goes back to the other as that one
// leaves.
func TestPaneSizeOverStreams(t *testing.T) {
	d := testDaemon(t)
	d.clients = map[*proto.ClientInfo]struct{}{}
	ses, err := d.create(proto.CreateParams{Project: "pr"})
	if err != nil {
		t.Fatal(err)
	}
	s := d.findPane(ses.Panes[0].ID)
	t.Cleanup(s.close)
	open := func() *keroclient.Stream {
		st, err := keroclient.AttachVia(serveDialer{d}, s.info.ID)
		if err != nil {
			t.Fatal(err)
		}
		go io.Copy(io.Discard, st)
		return st
	}
	size := func(when string, cols, rows int) {
		t.Helper()
		var c, r int
		for range 200 {
			s.mu.Lock()
			c, r = s.info.Cols, s.info.Rows
			s.mu.Unlock()
			if c == cols && r == rows {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Errorf("%s: %dx%d, want %dx%d", when, c, r, cols, rows)
	}
	mac, win := open(), open()
	mac.ResizePixels(90, 30, 9, 18)
	size("the Mac's ask", 90, 30)
	mac.Write([]byte(" "))
	win.ResizePixels(100, 40, 9, 18)
	time.Sleep(100 * time.Millisecond)
	size("Windows' ask, the user on the Mac", 90, 30)
	win.Write([]byte("\x1b[I"))
	time.Sleep(100 * time.Millisecond)
	size("Windows' focus report", 90, 30)
	win.Claim()
	size("Windows claimed", 100, 40)
	win.Close()
	size("Windows gone", 90, 30)
	mac.Close()
}
