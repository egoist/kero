package main

import (
	"math"
	"strconv"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/locales"
)

// Kero the frog lives in a small, transparent window of its own, perched
// on the main window's top edge: it peeks over the edge, its hands on the
// title bar, and follows the sessions. It hops when one needs the user,
// scans left and right while an agent works, cheers a finish, shakes at a
// failure, and dozes when everything is calm. A click pets it, and takes
// the user to the session that needs them.

const (
	// The pet window: wide enough for a sentence, tall enough for its
	// speech above the frog.
	petW       = 190
	petH       = 118
	petBodyH   = 87
	petScale   = 0.8 // the frog is drawn at 108, and stands this tall
	petBubbleH = 26
	// petPerch is how far the pet's hands reach over the window's top
	// edge.
	petPerch  = 12
	petFrame  = 33 * time.Millisecond // 30 frames a second
	petCalm   = 100 * time.Millisecond
	petDoze   = 45 * time.Second // all calm this long, and it sleeps
	petWink   = 700 * time.Millisecond
	petBubble = 5 * time.Second // a working or finished word stays this long
	petLinger = 9 * time.Second // a failure or a finish says so this long
)

// petMood is what the pet shows: the most urgent thing among the sessions.
type petMood int

const (
	petIdle petMood = iota
	petWorking
	petWaiting
	petDone
	petFailed
	petAsleep
)

// petState is the pet's window and what it last felt.
type petState struct {
	win  *mygo.Window
	offs []func() // the main window's events, until the pet goes
	// mood, since say what the pet felt and when it began, which its
	// reactions count from; lastActive is when a session last did
	// something, which a doze follows.
	mood       petMood
	since      time.Time
	lastActive time.Time
	wink       time.Time
	calm       bool // the desktop asks for less motion
	// dragging says the pointer is moving the pet along its edge: grab is
	// where it took the body, and startX the pointer's screen x then, so
	// that a press without a move stays a click.
	dragging bool
	moved    bool
	grab     float32
	startX   float32
}

// syncPet shows or hides the pet, as the settings and the window say.
func (a *App) syncPet() {
	if a.win == nil || a.win.IsDestroyed() {
		return
	}
	switch {
	case a.set.Pet && a.pet.win == nil:
		a.petShow()
	case !a.set.Pet && a.pet.win != nil:
		a.petClose()
	}
}

// petShow opens the pet's window over the main one, and keeps it there.
func (a *App) petShow() {
	p := &a.pet
	now := time.Now()
	p.since, p.lastActive, p.wink = now, now, time.Time{}
	p.calm = mygo.Theme.Preferences().ReduceMotion
	p.mood, _ = a.petCurrent(now)
	p.win = mygo.NewWindow(mygo.WindowOptions{
		Title:             locales.PetName(),
		Width:             petW,
		Height:            petH,
		Frameless:         true,
		Transparent:       true,
		DisableShadow:     true,
		DisableResize:     true,
		DisableMove:       true,
		DisableMinimize:   true,
		DisableMaximize:   true,
		DisableClose:      true,
		DisableFullScreen: true,
		SkipTaskbar:       true,
		Hidden:            true,
		Parent:            a.win,
		Content:           ui.View(a.petView),
	})
	win := p.win
	p.offs = []func(){
		// Closed with the app, and never in the way of quitting.
		win.OnClosed(func() {
			if a.pet.win == win {
				a.pet.win = nil
			}
		}),
		a.win.OnMove(a.petPlace),
		a.win.OnResize(a.petPlace),
		a.win.OnShow(a.petPlace),
		a.win.OnHide(win.Hide),
		a.win.OnMinimize(win.Hide),
		a.win.OnRestore(a.petPlace),
		a.win.OnEnterFullScreen(win.Hide),
		a.win.OnLeaveFullScreen(a.petPlace),
		mygo.Screen.OnDisplaysChanged(a.petPlace),
	}
	a.petPlace()
}

// petClose takes the pet's window away.
func (a *App) petClose() {
	p := &a.pet
	p.dragging, p.moved = false, false
	for _, off := range p.offs {
		off()
	}
	p.offs = nil
	if p.win != nil {
		w := p.win
		p.win = nil
		w.Destroy()
	}
}

// petPlace puts the pet's window on the main window's edge: above its top
// edge where the screen leaves room, else standing inside at its bottom
// edge, as ELY does. It hides the pet while the window is away.
func (a *App) petPlace() {
	p := &a.pet
	if p.win == nil || a.win == nil || a.win.IsDestroyed() {
		return
	}
	if !a.win.IsVisible() || a.win.IsMinimized() || a.win.IsFullScreen() {
		p.win.Hide()
		return
	}
	b := a.win.Bounds()
	d := mygo.Screen.DisplayNearestPoint(mygo.Point{X: b.X + b.Width, Y: b.Y})
	r, _ := petSpot(b, d.WorkArea, a.set.PetOffset)
	was := p.win.Bounds()
	if was != r {
		p.win.SetBounds(r)
		if was.Width != r.Width || was.Height != r.Height {
			// The build tells how much room there is for its speech.
			p.win.Invalidate()
		}
	}
	if !p.win.IsVisible() {
		p.win.ShowInactive()
	}
}

// petSpot is where the pet's window goes for a main window at main, in a
// screen's work area: above the window's top edge where it fits, hands
// over the edge, else inside at its bottom edge. offset is where across
// the window its middle stands, 0 at the left to 1 at the right. bottom
// tells which edge.
func petSpot(main, work mygo.Rectangle, offset float32) (r mygo.Rectangle, bottom bool) {
	off := min(max(offset, 0), 1)
	x := main.X + int(off*float32(main.Width)) - petW/2
	// Above the window, as much of the pet as the screen leaves room for:
	// its speech gives way first, then it stands at the bottom instead.
	perch := main.Y + petPerch
	if perch-work.Y >= petBodyH {
		x = max(work.X+8, min(x, work.X+work.Width-petW-8))
		y := max(work.Y, perch-petH)
		return mygo.Rectangle{X: x, Y: y, Width: petW, Height: min(perch-y, petH)}, false
	}
	// Inside the window at its bottom, the pet stays within its width.
	x = max(main.X+8, min(x, main.X+main.Width-petW-8))
	y := max(main.Y, main.Y+main.Height-petH)
	return mygo.Rectangle{X: x, Y: y, Width: petW, Height: petH}, true
}

// petCurrent tells what the pet should feel now: the most urgent thing
// among the sessions, and how many sessions are that. A host the app lost
// says nothing, as for the sidebar's counts.
func (a *App) petCurrent(at time.Time) (petMood, int) {
	waiting, failed, done, working := 0, 0, 0, 0
	for i := range a.st.Sessions {
		s := &a.st.Sessions[i]
		if h := a.hostOf(s.ID); h.remote() && h.conn != connReady {
			continue
		}
		switch {
		case s.Status == proto.Waiting:
			waiting++
		case s.Status == proto.Failed:
			failed++
		case s.Unread && (s.Status == proto.Idle || s.Status == proto.Exited):
			done++
		case s.Status == proto.Working:
			working++
		}
	}
	switch {
	case waiting > 0:
		return petWaiting, waiting
	case failed > 0:
		return petFailed, failed
	case done > 0:
		return petDone, done
	case working > 0:
		return petWorking, working
	}
	if !a.pet.lastActive.IsZero() && at.Sub(a.pet.lastActive) > petDoze {
		return petAsleep, 0
	}
	return petIdle, 0
}

// petNote takes the sessions as they just changed: a mood that changes
// starts its reaction, and work moving keeps the pet awake. The daemon
// sends a whole state, so this is where the pet hears of it.
func (a *App) petNote(at time.Time) {
	p := &a.pet
	if p.win == nil {
		return
	}
	m, _ := a.petCurrent(at)
	if m != petIdle && m != petAsleep {
		p.lastActive = at
	}
	if m != p.mood {
		p.mood, p.since = m, at
	}
	p.win.Invalidate()
}

// petView is the pet's window: its speech, when it has something to say,
// over the frog.
func (a *App) petView(c *ui.Context) {
	c.Root().Background(ui.Transparent)
	pal := paletteFor(c)
	now := c.Now()
	mood, n := a.petCurrent(now)
	label, fill, fg := a.petSpeech(pal, mood, n)
	// The window is shorter than the frog and its speech when the screen
	// leaves little room above the main window: the speech gives way, so
	// that no half a bubble shows.
	_, h := c.Size()
	roomy := h >= petH-1
	showing := roomy && a.petSays(now, mood)
	clicked := false
	ui.Column(c).Fill().Justify(ui.End).AlignItems(ui.Center).Children(func() {
		if roomy {
			speech := ui.Column(c.Key("speech")).AlignItems(ui.Center)
			speech.Opacity(speech.Animate("shown", b2f(showing), 180*time.Millisecond))
			speech.Children(func() {
				bubble := ui.Row(c.Key("bubble")).Height(petBubbleH).Padding(0, 11).Radius(petBubbleH / 2).Gap(6).
					AlignItems(ui.Center).Background(fill).MaxWidth(petW - 6).Shrink(1)
				if mood == petWorking {
					bubble.Shadow(0, 2, 10, 0, pal.floatShadow).Border(0.5, pal.cardBorder)
				}
				bubble.Children(func() {
					if mood == petWorking && showing {
						ui.Spinner(c).Size(11, 11).TextColor(fg)
					}
					ui.Text(c, label).FontSize(12).FontWeight(600).TextColor(fg).SingleLine().Ellipsis("…")
				})
				ui.Box(c.Key("tail")).Width(12).Height(5).Draw(func(p *ui.Painter, r ui.Rect) {
					tail := (&ui.Path{}).MoveTo(r.X, r.Y).LineTo(r.X+r.W, r.Y).LineTo(r.X+r.W/2, r.Y+r.H).Close()
					p.FillPath(tail, fill)
				})
				clicked = clicked || (showing && bubble.Clicked())
			})
		}

		body := ui.Box(c.Key("kero")).Size(petW, petBodyH).Shrink(0).Cursor(ui.CursorGrab).
			Description(petDescription(label))
		hovered := body.Hovered()
		body.Draw(func(p *ui.Painter, r ui.Rect) {
			a.petDraw(p, r, mood, hovered)
			p.After(a.petTick())
		})
		a.petDrag(body)
		clicked = clicked || body.Clicked()
		if a.pet.moved {
			// A drag is not a pat: it only let go.
			clicked = false
			if !a.pet.dragging {
				a.pet.moved = false
			}
		}
	})
	if clicked {
		a.petPetted(now, mood)
	}

	// Rebuild when what the pet says, or how awake it is, turns over;
	// its motion repaints without a build, in petDraw.
	if mood == petIdle {
		if at := a.pet.lastActive.Add(petDoze); at.After(now) {
			c.After(at.Sub(now) + 16*time.Millisecond)
		}
	}
	if showing && (mood == petWorking || mood == petDone || mood == petFailed) {
		if d := a.petSaysFor(mood) - now.Sub(a.pet.since); d > 0 {
			c.After(d + 16*time.Millisecond)
		}
	}
	if d := petWink - now.Sub(a.pet.wink); d > 0 {
		c.After(d + 16*time.Millisecond)
	}
}

// petDescription is what assistive technology hears of the frog: its
// name, and what it says, if anything.
func petDescription(label string) string {
	if label == "" {
		return locales.PetName()
	}
	return locales.PetName() + ": " + label
}

// petSpeech says what the pet's bubble says, and how it looks.
func (a *App) petSpeech(pal *palette, mood petMood, n int) (label string, fill, fg ui.Color) {
	switch mood {
	case petWaiting:
		return locales.FooterNeedsYou(n), pal.attention, ui.Hex("#241a08")
	case petFailed:
		label = locales.StatusFailed()
		if n > 1 {
			label += " · " + strconv.Itoa(n)
		}
		return label, pal.danger, ui.Hex("#ffffff")
	case petDone:
		return locales.FooterDone(n), pal.done, pal.onDone
	case petWorking:
		return locales.FooterWorking(n), pal.popover, pal.textMuted
	}
	return "", ui.Transparent, ui.Transparent
}

// petSays tells whether the pet's bubble shows now.
func (a *App) petSays(now time.Time, mood petMood) bool {
	switch mood {
	case petWaiting:
		return true
	case petWorking, petDone, petFailed:
		return now.Sub(a.pet.since) < a.petSaysFor(mood)
	}
	return false
}

// petSaysFor is how long a bubbled mood says so; waiting stays until it
// is answered.
func (a *App) petSaysFor(mood petMood) time.Duration {
	switch mood {
	case petDone, petFailed:
		return petLinger
	default:
		return petBubble
	}
}

// petTick is how often the pet draws its next frame: slowly when the
// desktop asks for less motion, and when the user is elsewhere.
func (a *App) petTick() time.Duration {
	switch {
	case a.pet.calm:
		return 250 * time.Millisecond
	case !a.focused:
		return petCalm
	}
	return petFrame
}

// petPetted is a click on the frog: it wakes, winks, and takes the user
// to a session that waits on them, if another one does.
func (a *App) petPetted(now time.Time, mood petMood) {
	a.pet.lastActive, a.pet.since, a.pet.wink, a.pet.mood = now, now, now, mood
	if mood == petWaiting {
		if s := a.session(a.selected); s == nil || s.Status != proto.Waiting {
			a.jumpToAttention()
		}
	}
	if a.pet.win != nil {
		a.pet.win.Invalidate()
	}
	if a.win != nil {
		a.win.Focus()
		a.focusTerminal()
	}
}

// petDrag moves the pet along its edge while the pointer drags its body.
// The pointer's screen x, not its x in the window, sets where it goes:
// the window follows it, so the local x would stand still.
func (a *App) petDrag(body ui.Element) {
	_, _, pressed := body.Dragged()
	if pressed {
		if !a.pet.dragging {
			x, _, over := body.PointerPosition()
			if !over {
				return
			}
			a.pet.dragging, a.pet.moved, a.pet.grab = true, false, x
			a.pet.lastActive = time.Now()
			if cx, ok := a.petCursorX(); ok {
				a.pet.startX = cx
			} else {
				a.pet.startX = 0
			}
		}
		if cx, ok := a.petCursorX(); ok {
			if abs(cx-a.pet.startX) > 2 {
				a.pet.moved = true
			}
			if a.pet.moved {
				a.petDragTo(cx - a.pet.grab)
			}
		}
		return
	}
	if a.pet.dragging {
		a.pet.dragging = false
		if a.pet.moved {
			a.petDrop()
		}
	}
}

// petCursorX is the pointer's x on screen, where the pet's window moves.
func (a *App) petCursorX() (float32, bool) {
	if a.pet.win == nil || a.win == nil {
		return 0, false
	}
	return float32(mygo.Screen.CursorScreenPoint().X), true
}

// petDragTo puts the pet's window at left, as a custom position across
// the main window, and moves it there.
func (a *App) petDragTo(left float32) {
	if a.pet.win == nil || a.win == nil {
		return
	}
	off := petOffsetAt(a.win.Bounds(), left)
	off = float32(math.Round(float64(off)*1000)) / 1000
	a.set.PetOffset = off
	a.petPlace()
}

// petDrop keeps where a drag left the pet.
func (a *App) petDrop() {
	if a.pet.win == nil {
		return
	}
	a.applySettings(a.set)
}

// petOffsetAt is where the middle of a pet placed at left stands across
// a main window, from 0 at its left edge to 1 at its right.
func petOffsetAt(main mygo.Rectangle, left float32) float32 {
	if main.Width <= 0 {
		return 0.5
	}
	center := left + petW/2
	return min(max((center-float32(main.X))/float32(main.Width), 0), 1)
}
