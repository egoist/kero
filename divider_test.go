package main

import (
	"encoding/json"
	"errors"
	"math"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

func TestDividerReleaseKeepsRatioUntilSaved(t *testing.T) {
	a := testApp(t)
	s := a.session("s1")
	stale := a.st
	stale.Sessions = []proto.Session{*s}
	stale.Sessions[0].Layout = s.Layout.Clone()
	requests := make(chan proto.LayoutParams, 1)
	reply := make(chan struct{}, 1)
	defer close(reply)
	a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method == "layout" {
			var p proto.LayoutParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			requests <- p
			<-reply
		}
		return true, nil
	})
	var bounds ui.Rect
	view := ui.NewTester(func(c *ui.Context) {
		a.view(c)
		bounds = a.paneRef("card-a").Bounds(c)
	}, 1200, 800)
	view.Frame()
	view.Frame()
	x, y := bounds.X+bounds.W+paneGap/2, bounds.Y+bounds.H/2
	view.Press(x, y)
	view.Move(x+80, y)
	view.Release(x+80, y)
	view.Frame()
	var saved proto.LayoutParams
	select {
	case saved = <-requests:
	case <-time.After(time.Second):
		t.Fatal("divider release did not send layout")
	}
	want := s.Layout.Ratio
	if want == stale.Sessions[0].Layout.Ratio || saved.Session != s.ID || saved.Layout.Ratio != want {
		t.Fatalf("release did not save the dragged ratio %v: %+v", want, saved)
	}
	h := a.local()
	a.applyLayoutState(h, stale)
	if got := a.session(s.ID).Layout.Ratio; got != want {
		t.Fatalf("pre-save snapshot reset released ratio from %v to %v", want, got)
	}
	pending := h.dividerSaves[s.ID]
	if pending == nil {
		t.Fatal("missing pending release")
	}
	reply <- struct{}{}
	select {
	case <-h.layoutWritten:
	case <-time.After(time.Second):
		t.Fatal("layout RPC did not return")
	}
	// Drive the main-thread reply explicitly. The tester has no native
	// window to dispatch it, and an RPC reply may beat queued state events.
	a.dividerWritten(h, s.ID, pending, nil)
	stale.Sessions[0].Name = "renamed while saving"
	a.applyLayoutState(h, stale)
	if got := a.session(s.ID); got.Layout.Ratio != want || got.Name != stale.Sessions[0].Name {
		t.Fatalf("pre-save snapshot reset released ratio from %v to %v or lost rename %q", want, got.Layout.Ratio, got.Name)
	}
	stale.Sessions[0].Layout = saved.Layout
	a.applyLayoutState(h, stale)
	if h.dividerSaves[s.ID] != nil {
		t.Fatal("matching snapshot did not retire the save")
	}
	stale.Sessions[0].Layout = saved.Layout.Clone()
	stale.Sessions[0].Layout.Ratio = .35
	a.applyLayoutState(h, stale)
	if got := a.session(s.ID).Layout.Ratio; got != .35 {
		t.Fatalf("external resize after ack: got %v, want .35", got)
	}
}

func TestDividerSaveOverlap(t *testing.T) {
	a := testApp(t)
	h, s := a.local(), a.session("s1")
	received := make(chan float64, 2)
	release := make(chan struct{})
	h.cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		var p proto.LayoutParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		received <- p.Layout.Ratio
		<-release
		return true, nil
	})
	defer close(release)
	before := s.Layout.Clone()
	s.Layout.Ratio = .6
	a.saveDivider(s, before)
	first := h.dividerSaves[s.ID]
	s.Layout.Ratio = .7
	a.saveDivider(s, first.layout)
	latest := h.dividerSaves[s.ID]
	for _, want := range []float64{.6, .7} {
		select {
		case got := <-received:
			if got != want {
				t.Fatalf("wire ratio %v, want %v", got, want)
			}
		case <-time.After(time.Second):
			t.Fatal("missing layout RPC")
		}
		release <- struct{}{}
	}
	a.dividerWritten(h, s.ID, first, errors.New("obsolete save"))
	st := proto.State{Sessions: []proto.Session{*s}}
	st.Sessions[0].Layout = first.layout.Clone()
	a.applyLayoutState(h, st)
	if got := a.session(s.ID).Layout.Ratio; got != .7 || a.pendingToast != "" {
		t.Fatalf("older completion affected latest release: ratio %v, toast %q", got, a.pendingToast)
	}
	a.dividerWritten(h, s.ID, latest, errors.New("save failed"))
	if got := a.session(s.ID).Layout.Ratio; got != .6 || h.dividerSaves[s.ID] != nil || a.pendingToast != "save failed" {
		t.Fatalf("failed save: ratio %v, pending %v, toast %q", got, h.dividerSaves[s.ID], a.pendingToast)
	}
}

func TestDividerSaveReconciliation(t *testing.T) {
	for _, tc := range []string{"snapshot before reply", "changed topology", "no matching snapshot", "slow failure", "error before snapshot"} {
		t.Run(tc, func(t *testing.T) {
			a := testApp(t)
			h, s := a.local(), a.session("s1")
			before := s.Layout.Clone()
			s.Layout.Ratio = .7
			save := &dividerSave{layout: s.Layout.Clone(), before: before}
			h.dividerSaves = map[string]*dividerSave{s.ID: save}
			st := proto.State{Sessions: []proto.Session{*s}}
			incoming := s.Layout.Clone()
			st.Sessions[0].Layout = incoming
			switch tc {
			case "snapshot before reply":
				a.applyLayoutState(h, st)
				a.dividerWritten(h, s.ID, save, nil)
			case "changed topology":
				incoming.Row = !incoming.Row
				a.applyLayoutState(h, st)
				if a.session(s.ID).Layout.Row != incoming.Row {
					t.Fatal("save hid changed split orientation")
				}
			case "no matching snapshot":
				a.dividerWritten(h, s.ID, save, nil)
				incoming.Ratio = .4
				a.applyLayoutState(h, st)
				a.expireDivider(h, s.ID, save)
				if got := a.session(s.ID).Layout.Ratio; got != .4 {
					t.Fatalf("expiry hid external ratio %v", incoming.Ratio)
				}
			case "slow failure":
				a.expireDivider(h, s.ID, save)
				incoming.Ratio = .3
				a.applyLayoutState(h, st)
				if got := a.session(s.ID).Layout.Ratio; got != .3 {
					t.Fatalf("slow RPC hid external ratio %v", incoming.Ratio)
				}
				a.dividerWritten(h, s.ID, save, errors.New("late error"))
				if a.pendingToast != "late error" || a.session(s.ID).Layout.Ratio != .3 {
					t.Fatal("lost late error or external layout")
				}
			case "error before snapshot":
				a.dividerWritten(h, s.ID, save, errors.New("rejected"))
				if got := a.session(s.ID).Layout.Ratio; got != before.Ratio {
					t.Fatalf("failed release kept %v, want %v", got, before.Ratio)
				}
			}
			if h.dividerSaves[s.ID] != nil {
				t.Fatal("local release still masks snapshots")
			}
		})
	}
}

func TestViewerPaneDividerDrag(t *testing.T) {
	for _, horizontal := range []bool{true, false} {
		name := "stacked"
		if horizontal {
			name = "side by side"
		}
		t.Run(name, func(t *testing.T) {
			a := testApp(t)
			s := &a.st.Sessions[0]
			s.Layout.Row = horizontal
			s.Panes[0].URL = imageViewerURL("", "/a.png", "")
			s.Panes[1].URL = imageViewerURL("", "/b.png", "")
			var first, second ui.Rect
			view := ui.NewTester(func(c *ui.Context) {
				a.view(c)
				first = a.paneRef("card-a").Bounds(c)
				second = a.paneRef("card-b").Bounds(c)
			}, 1200, 800)
			view.Frame()
			view.Frame()
			x, y := first.X+first.W/2, first.Y+first.H/2
			dx, dy := float32(0), float32(80)
			size := first.H + second.H
			if horizontal {
				x = (first.X + first.W + second.X) / 2
				dx, dy = 80, 0
				size = first.W + second.W
			} else {
				y = (first.Y + first.H + second.Y) / 2
			}
			if size <= 0 {
				t.Fatalf("no pane bounds: %v %v", first, second)
			}
			// Starting slightly off the center of the grip should still resize
			// the panes instead of sending the press into the image viewer.
			if horizontal {
				x += 8
			} else {
				y -= 8
			}
			start, before := s.Layout.Ratio, first
			view.Press(x, y)
			view.Move(x+dx, y+dy)
			view.Release(x+dx, y+dy)
			view.Frame()
			edgeDelta := first.Y + first.H - (before.Y + before.H)
			if horizontal {
				edgeDelta = first.X + first.W - (before.X + before.W)
			}
			if math.Abs(float64(edgeDelta)-80) > 2 {
				t.Fatalf("card edge moved %v DIP, want 80", edgeDelta)
			}
			want := start + 80/float64(size)
			if math.Abs(s.Layout.Ratio-want) > .004 || a.layoutDrag.split != "" {
				t.Fatalf("drag at %.1f, %.1f moved ratio %f to %f, want %f; active split %q", x, y, start, s.Layout.Ratio, want, a.layoutDrag.split)
			}
		})
	}
}
