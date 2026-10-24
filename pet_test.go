package main

import (
	"testing"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"kero/internal/actions"
	"kero/internal/proto"
	"kero/locales"
)

// The pet follows the most urgent session: one waiting beats any number
// of failures, which beat finishes, which beat work.
func TestPetMood(t *testing.T) {
	a := testApp(t)
	a.pet.lastActive = time.Now()
	s := &a.st.Sessions[0]
	cases := []struct {
		name   string
		status proto.Status
		unread bool
		want   petMood
	}{
		{"idle", proto.Idle, false, petIdle},
		{"working", proto.Working, false, petWorking},
		{"done", proto.Idle, true, petDone},
		{"done exited", proto.Exited, true, petDone},
		{"failed", proto.Failed, true, petFailed},
		{"waiting", proto.Waiting, true, petWaiting},
	}
	for _, c := range cases {
		s.Status, s.Unread = c.status, c.unread
		if got, _ := a.petCurrent(time.Now()); got != c.want {
			t.Errorf("%s: mood %v, want %v", c.name, got, c.want)
		}
	}
	// A session that needs the user counts.
	s.Status, s.Unread = proto.Waiting, true
	a.st.Sessions = append(a.st.Sessions, proto.Session{ID: "s2", Project: "p1"})
	a.st.Sessions[1].Status, a.st.Sessions[1].Unread = proto.Waiting, true
	if got, n := a.petCurrent(time.Now()); got != petWaiting || n != 2 {
		t.Errorf("two waiting: %v, %d", got, n)
	}
}

// All calm for long enough, and the pet dozes; work wakes it.
func TestPetDozes(t *testing.T) {
	a := testApp(t)
	now := time.Now()
	a.pet.lastActive = now.Add(-petDoze - time.Second)
	if got, _ := a.petCurrent(now); got != petAsleep {
		t.Fatalf("mood %v, want asleep", got)
	}
	a.st.Sessions[0].Status = proto.Working
	a.petNote(now)
	if got, _ := a.petCurrent(now); got != petWorking {
		t.Errorf("work woke it to %v", got)
	}
}

// The pet stands over the window's top edge where the screen leaves room
// for it, at the left, center or right, and otherwise inside at the
// bottom.
func TestPetSpot(t *testing.T) {
	work := mygo.Rectangle{X: 0, Y: 25, Width: 1440, Height: 875}
	main := mygo.Rectangle{X: 100, Y: 300, Width: 1000, Height: 700}
	for _, c := range []struct {
		offset float32
		x      int
	}{{0.5, 505}, {0.25, 255}, {0, 8}} {
		r, bottom := petSpot(main, work, c.offset)
		if bottom || r.Y != 300-petH+petPerch || r.Height != petH || r.X != c.x {
			t.Errorf("offset %v: %+v bottom %v, want x %d", c.offset, r, bottom, c.x)
		}
	}
	// Little room above: the speech gives way, the frog still stands on
	// the edge.
	main.Y = 120
	r, bottom := petSpot(main, work, 0.5)
	if bottom || r.Y != work.Y || r.Height != 120+petPerch-work.Y || r.Height < petBodyH {
		t.Errorf("little room: %+v bottom %v", r, bottom)
	}
	// No room for the frog: it stands inside at the bottom.
	main.Y = 80
	r, bottom = petSpot(main, work, 0.5)
	if !bottom || r.Y != 80+700-petH || r.Height != petH {
		t.Errorf("no room: %+v bottom %v", r, bottom)
	}
}

// The middle of a pet dragged to left stands where petOffsetAt says.
func TestPetOffsetAt(t *testing.T) {
	main := mygo.Rectangle{X: 100, Width: 1000}
	for _, c := range []struct {
		left float32
		want float32
	}{{505, 0.5}, {5, 0}, {1005, 1}} {
		if got := petOffsetAt(main, c.left); got != c.want {
			t.Errorf("left %v: offset %v, want %v", c.left, got, c.want)
		}
	}
}

// A press on the frog pets it, even when it has nothing to jump to.
func TestPetClickWinks(t *testing.T) {
	a := testApp(t)
	a.pet.since, a.pet.lastActive = time.Now(), time.Now()
	tt := ui.NewTester(a.petView, petW, petH)
	tt.Frame()
	tt.ClickAt(petW/2, petH-30)
	tt.Frame()
	if a.pet.wink.IsZero() {
		t.Fatal("a click on the frog did not pet it")
	}
}

// Without room for its speech, the frog still stands on the edge, and
// no half a bubble shows.
func TestPetShortWindow(t *testing.T) {
	a := testApp(t)
	a.st.Sessions[0].Status, a.st.Sessions[0].Unread = proto.Waiting, true
	a.pet.since, a.pet.lastActive = time.Now(), time.Now()
	tt := ui.NewTester(a.petView, petW, petH-20)
	tt.Advance(400 * time.Millisecond)
	tt.Frame()
	shot(t, tt, "pet-perched-short")
	if tt.HasText("needs you") {
		t.Error("the speech shows in a window too short for it")
	}
}

// The frog's faces, for a look: KERO_SHOTS=dir writes them.
func TestPetLooks(t *testing.T) {
	for _, c := range []struct {
		name   string
		mood   petMood
		status proto.Status
		unread bool
		since  time.Duration
	}{
		{"idle", petIdle, proto.Idle, false, 900 * time.Millisecond},
		{"working", petWorking, proto.Working, false, 900 * time.Millisecond},
		{"waiting", petWaiting, proto.Waiting, true, 900 * time.Millisecond},
		{"done", petDone, proto.Idle, true, 500 * time.Millisecond},
		{"failed", petFailed, proto.Failed, true, 250 * time.Millisecond},
		{"asleep", petAsleep, proto.Idle, false, 0},
	} {
		a := testApp(t)
		a.st.Sessions[0].Status, a.st.Sessions[0].Unread = c.status, c.unread
		a.pet.lastActive = time.Now().Add(-c.since - time.Second)
		if c.mood == petAsleep {
			a.pet.lastActive = time.Now().Add(-petDoze - 2*time.Second)
		}
		a.pet.since = time.Now().Add(-c.since)
		tt := ui.NewTester(a.petView, petW, petH)
		tt.Advance(c.since + 100*time.Millisecond)
		tt.Frame()
		shot(t, tt, "pet-"+c.name)
		if got, _ := a.petCurrent(tt.Now()); c.mood != petAsleep && got != c.mood {
			t.Errorf("%s: mood %v", c.name, got)
		}
	}
}

// The Appearance page's switch, for a look: KERO_SHOTS=dir writes it.
func TestPetSettingRow(t *testing.T) {
	a := testApp(t)
	a.ss.draft = map[string]string{}
	a.ss.page = "appearance"
	tt := ui.NewTester(a.settingsView, 820, 640)
	tt.Frame()
	shot(t, tt, "settings-pet")
	if !tt.HasText(locales.SetPet()) {
		t.Errorf("the Appearance page does not offer the pet; texts %q", tt.Texts())
	}
}

// The View action turns the frog on and off, under its shortcut.
func TestPetToggleAction(t *testing.T) {
	act, ok := actions.Find("pet.toggle")
	if !ok || actions.Keys(act, nil) == "" {
		t.Fatal("no pet.toggle action, or no shortcut for it")
	}
	a := testApp(t)
	if !a.set.Pet {
		t.Fatal("the pet starts off")
	}
	a.run("pet.toggle", nil)
	if a.set.Pet || a.applied.Pet {
		t.Error("the action left the pet on")
	}
	a.run("pet.toggle", nil)
	if !a.set.Pet || !a.applied.Pet {
		t.Error("the action did not turn the pet back on")
	}
}

// The action is in the command palette, found by what it does.
func TestPetToggleInPalette(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 640)
	a.openPalette()
	tt.Frame()
	tt.Type("frog")
	tt.Frame()
	if !tt.HasText(locales.ActionTogglePet()) {
		t.Errorf("frog finds no %q; texts %q", locales.ActionTogglePet(), tt.Texts())
	}
}
