package main

import (
	"time"

	"github.com/egoist/mygo/ui"
)

const (
	gestureIdle    = 140 * time.Millisecond
	swipeThreshold = float32(28)
	swipeDominance = float32(1.3)
	swipeLockY     = float32(20)
	pinchZoomIn    = float32(1.18)
	pinchZoomOut   = float32(0.85)
)

// gestureState accumulates trackpad swipe and pinch deltas until a gesture
// crosses its threshold or goes idle.
type gestureState struct {
	swipeX, swipeY float32
	swipeAt        time.Time
	swipeFired     bool
	swipeLocked    bool
	swipeMomentum  bool

	pinchScale float32
	pinchAt    time.Time
	pinchPane  string
	pinchFired bool
}

func absf(v float32) float32 {
	if v < 0 {
		return -v
	}
	return v
}

func (a *App) modalOpen() bool {
	return a.pal.open || a.picker.open || (a.confirm != nil && a.confirm.open) || a.wtAsk != nil
}

func (a *App) setSidebarHidden(hidden bool) {
	if a.prefs.SidebarHidden == hidden {
		return
	}
	a.prefs.SidebarHidden = hidden
	a.savePrefs()
}

// handleSidebarSwipe treats horizontal trackpad swipes anywhere over the main
// window as hiding (swipe left, positive DX) or showing (swipe right, negative
// DX) the left sidebar, while leaving vertical scrolls and modifier-held
// scrolls alone.
func (a *App) handleSidebarSwipe(ev ui.InputEvent) bool {
	if ev.Kind != ui.InputScroll || !a.set.TrackpadGestures || a.modalOpen() || !ev.Precise || ev.Mods != 0 {
		return false
	}
	g := &a.gestures
	if g.swipeAt.IsZero() || ev.Time.Sub(g.swipeAt) > gestureIdle || ev.Time.Before(g.swipeAt) || (g.swipeMomentum && !ev.Momentum) {
		g.swipeX, g.swipeY = 0, 0
		g.swipeFired, g.swipeLocked, g.swipeMomentum = false, false, false
	}

	absX, absY := absf(ev.DX), absf(ev.DY)
	if ev.Momentum {
		g.swipeMomentum = true
		return g.swipeFired && absX > absY
	}
	g.swipeMomentum = false
	g.swipeAt = ev.Time
	if g.swipeLocked {
		return false
	}
	if g.swipeFired {
		return absX > absY
	}
	if absY > absX {
		g.swipeX += ev.DX
		g.swipeY += ev.DY
		if absf(g.swipeY) >= swipeLockY && absf(g.swipeY) > absf(g.swipeX) {
			g.swipeLocked = true
		}
		return false
	}
	if ev.DX == 0 {
		return false
	}
	if (ev.DX > 0 && g.swipeX < 0) || (ev.DX < 0 && g.swipeX > 0) {
		g.swipeX, g.swipeY = 0, 0
	}
	g.swipeX += ev.DX
	g.swipeY += ev.DY
	if absf(g.swipeX) >= swipeThreshold && absf(g.swipeX) >= swipeDominance*absf(g.swipeY) {
		a.setSidebarHidden(g.swipeX > 0)
		g.swipeFired = true
	}
	return true
}

// handlePanePinch zooms the pane under the pointer when spreading two fingers
// and restores all panes when pinching them back together.
func (a *App) handlePanePinch(ev ui.InputEvent, sid, pid string) bool {
	if ev.Kind != ui.InputZoom || !a.set.TrackpadGestures || a.modalOpen() || ev.Scale <= 0 || ev.Scale == 1 {
		return false
	}
	// Windows precision touchpads encode pinches as Ctrl+wheel, so Ctrl may be
	// present in Mods while other modifiers skip the gesture.
	if ev.Mods&(ui.Alt|ui.Super|ui.Shift) != 0 {
		return false
	}
	s := a.session(sid)
	if s == nil || len(s.Panes) < 2 {
		return false
	}
	g := &a.gestures
	if g.pinchAt.IsZero() || ev.Time.Sub(g.pinchAt) > gestureIdle || ev.Time.Before(g.pinchAt) || g.pinchPane != pid {
		g.pinchScale = 1
		g.pinchPane = pid
		g.pinchFired = false
	}
	g.pinchAt = ev.Time
	if g.pinchFired {
		return true
	}
	g.pinchScale *= ev.Scale
	switch {
	case g.pinchScale >= pinchZoomIn:
		if s.Zoomed != pid {
			a.zoomPane(s, pid)
		}
		g.pinchFired = true
	case g.pinchScale <= pinchZoomOut:
		if s.Zoomed != "" {
			a.zoomPane(s, s.Zoomed)
		}
		g.pinchFired = true
	}
	return true
}
