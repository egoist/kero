package main

import (
	"bufio"
	"encoding/json"
	"net"
	"slices"
	"testing"
	"time"

	"kero/internal/client"
	"kero/internal/proto"
)

// pipeDialer dials a kerod that welcomes an attach and hands what the
// client then sends to frames.
type pipeDialer struct{ frames chan byte }

func (d pipeDialer) Dial() (net.Conn, error) {
	here, there := net.Pipe()
	go func() {
		r := bufio.NewReader(there)
		if _, err := proto.ReadLine(r, 64<<10); err != nil {
			return
		}
		json.NewEncoder(there).Encode(proto.Welcome{Version: proto.Version, Cols: 80, Rows: 24})
		for {
			kind, _, err := proto.ReadFrame(r)
			if err != nil {
				return
			}
			d.frames <- kind
		}
	}()
	return here, nil
}

// attachTerm gives a pane of the app a stream whose frames come to the
// channel returned.
func attachTerm(t *testing.T, a *App, id string) chan byte {
	t.Helper()
	d := pipeDialer{frames: make(chan byte, 16)}
	s, err := client.AttachVia(d, id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	a.terms[id] = &termEntry{stream: s}
	return d.frames
}

// claims returns the claims a pane's stream sent within a moment.
func claims(frames chan byte) int {
	n := 0
	for {
		select {
		case k := <-frames:
			if k == proto.FrameClaim {
				n++
			}
		case <-time.After(100 * time.Millisecond):
			return n
		}
	}
}

// The window claims its panes only while the user is at it: focused, on
// a machine they used just now. A machine they left, its window still
// focused, takes none, whatever its app does without them.
func TestClaimShownWhileHere(t *testing.T) {
	a := testApp(t)
	fa, fb := attachTerm(t, a, "a"), attachTerm(t, a, "b")
	idle := time.Duration(0)
	a.idleTime = func() time.Duration { return idle }

	a.focused = false
	a.claimShown()
	if n := claims(fa) + claims(fb); n != 0 {
		t.Errorf("window not focused: %d claims", n)
	}
	a.focused = true
	a.claimShown()
	if claims(fa) != 1 || claims(fb) != 1 {
		t.Error("the user here: not every pane shown claimed")
	}
	idle = time.Minute // the user went to another machine
	a.claimShown()
	if n := claims(fa) + claims(fb); n != 0 {
		t.Errorf("the user away: %d claims", n)
	}
}

// A zoomed pane alone is shown, and claimed: the others, sized for the
// layout when last shown, would take another machine's view's size with
// a size of none.
func TestClaimShownZoomed(t *testing.T) {
	a := testApp(t)
	fa, fb := attachTerm(t, a, "a"), attachTerm(t, a, "b")
	a.focused = true
	a.session("s1").Zoomed = "b"
	a.claimShown()
	if claims(fa) != 0 || claims(fb) != 1 {
		t.Error("claimed other than the zoomed pane")
	}
}

func TestShownPanes(t *testing.T) {
	a := testApp(t)
	s := a.session("s1")
	if got := shownPanes(s); !slices.Equal(got, []string{"a", "b"}) {
		t.Errorf("side by side: %q", got)
	}
	s.Zoomed = "b"
	if got := shownPanes(s); !slices.Equal(got, []string{"b"}) {
		t.Errorf("zoomed: %q", got)
	}
	s.Zoomed, s.Layout = "", nil
	if got := shownPanes(s); !slices.Equal(got, []string{"a"}) {
		t.Errorf("no layout: %q", got)
	}
}

// The selected session isn't watched once the window loses the keyboard,
// even where the app never hears it stopped being active, as on Windows:
// its agent finishing there still tells.
func TestWatchingNeedsFocus(t *testing.T) {
	a := testApp(t)
	a.selected = "s1"
	a.active, a.focused = true, true
	if !a.watching("s1") {
		t.Error("the selected session, window focused: not watched")
	}
	if a.watching("s2") {
		t.Error("another session: watched")
	}
	a.focused = false
	if a.watching("s1") {
		t.Error("window not focused: watched")
	}
}
