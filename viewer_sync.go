package main

import (
	"context"
	"encoding/json"
	"fmt"

	"kero/internal/proto"
)

// An input repeats the sequence of the last unacknowledged toggle. WebKit
// may collapse several title changes into the last one, e.g. link then drag.
type viewerZoomInput struct {
	viewerZoomState
	Kind      string `json:"kind"`
	Epoch     uint64 `json:"epoch"`
	ToggleSeq uint64 `json:"toggleSeq"`
}

type viewerZoomSnapshot struct {
	viewerZoomState
	Revision    uint64 `json:"revision"`
	Epoch       uint64 `json:"epoch"`
	Ack         uint64 `json:"ack"`         // last title processed from the receiving document
	ToggleEpoch uint64 `json:"toggleEpoch"` // epoch of its last accepted toggle
}

func (g *viewerGroup) snapshot(ack uint64) viewerZoomSnapshot {
	return viewerZoomSnapshot{viewerZoomState: g.zoom, Revision: g.revision, Epoch: g.epoch, Ack: ack}
}

func (g *viewerGroup) applyZoom(doc *viewerDocument, in viewerZoomInput, previous, seq uint64) bool {
	if in.Zoom <= 0 || !finiteViewerNumber(in.Zoom) || !finiteViewerNumber(in.PanX) || !finiteViewerNumber(in.PanY) || (in.Mode != "fit" && in.Mode != "actual" && in.Mode != "custom") {
		return false
	}
	switch in.Kind {
	case "toggle":
		if in.ToggleSeq != seq {
			return false
		}
	case "move":
		if in.ToggleSeq >= seq {
			return false
		}
	default:
		return false
	}
	if in.ToggleSeq > previous {
		// Recover a collapsed toggle from a move only within its own link
		// lifetime. A delayed sample may still carry an unseen toggle after
		// another pane has already disabled the group.
		if in.Kind == "move" && in.Epoch != g.epoch && doc.toggleEpoch != g.epoch {
			return false
		}
		g.epoch = g.revision + 1
		doc.toggleSeq, doc.toggleEpoch = in.ToggleSeq, g.epoch
	} else {
		// A move just after this document enabled sync can precede its
		// acknowledgement. No move crosses a later toggle in any pane.
		ownToggle := in.ToggleSeq != 0 && in.ToggleSeq == doc.toggleSeq && doc.toggleEpoch == g.epoch
		if !in.Enabled || !g.zoom.Enabled || (in.Epoch != g.epoch && !ownToggle) {
			return false
		}
	}
	g.revision++
	g.zoom = in.viewerZoomState
	return true
}

func (a *App) updateViewerZoom(s *proto.Session, source *webEntry, in viewerZoomInput, previous, seq uint64) {
	g := a.images.group(s.ID)
	if !g.applyZoom(&source.viewer, in, previous, seq) {
		// Settle optimistic input from a pane that missed a toggle.
		source.sendViewerZoom(g.snapshot(source.viewer.seq))
		return
	}
	for _, p := range s.Panes {
		if e := a.webs[p.ID]; e != nil {
			// Include the sender: its display may still have a competing
			// pane's older revision pending or in flight.
			e.sendViewerZoom(g.snapshot(e.viewer.seq))
		}
	}
}

// One worker per ready document. The UI thread is the sole producer, so
// replacing the single buffered item never waits for a slow WebView.
// Page.EvalContext dispatches its native call onto MyGo's main thread. The
// result wait belongs here: on the UI thread it would pump nested events.
type viewerDelivery struct {
	pending chan viewerZoomSnapshot
	cancel  context.CancelFunc
}

func newViewerDelivery(apply func(context.Context, viewerZoomSnapshot)) *viewerDelivery {
	ctx, cancel := context.WithCancel(context.Background())
	d := &viewerDelivery{pending: make(chan viewerZoomSnapshot, 1), cancel: cancel}
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case st := <-d.pending:
				if ctx.Err() != nil {
					return
				}
				apply(ctx, st)
			}
		}
	}()
	return d
}

func (d *viewerDelivery) offer(st viewerZoomSnapshot) {
	select {
	case <-d.pending:
	default:
	}
	d.pending <- st
}

func (e *webEntry) sendViewerZoom(st viewerZoomSnapshot) {
	if !e.viewer.ready || e.viewer.url == "" || e.viewer.url != e.url {
		return
	}
	if e.viewer.delivery == nil {
		if !e.viewerPageReady() {
			return
		}
		page, gen := e.view.Page(), e.nav
		e.viewer.delivery = newViewerDelivery(func(ctx context.Context, st viewerZoomSnapshot) {
			encoded, _ := json.Marshal(st)
			// Use an expression: MyGo retries statements as function bodies
			// after a syntax error, costing a second IPC round trip.
			code := fmt.Sprintf(`location.protocol==="kero-image:" && location.host==="view" && window.__keroViewerGeneration===%d && window.__keroApplyZoom(%s)`, gen, encoded)
			page.EvalContext(ctx, code)
		})
	}
	st.ToggleEpoch = e.viewer.toggleEpoch
	e.viewer.delivery.offer(st)
}
