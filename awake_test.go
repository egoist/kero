package main

import (
	"testing"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/internal/settings"
	"kero/locales"
)

func TestAnyWorking(t *testing.T) {
	local := func(id string) bool { return id != "remote" }
	for _, c := range []struct {
		name     string
		sessions []proto.Session
		want     bool
	}{
		{"none", nil, false},
		{"idle", []proto.Session{{ID: "a", Status: proto.Idle, Panes: []proto.Pane{{Status: proto.Idle}}}}, false},
		{"working", []proto.Session{{ID: "a", Status: proto.Working, Panes: []proto.Pane{{Status: proto.Working}}}}, true},
		// The session shows the waiting pane's status; the agent beside it
		// still works.
		{"behind a waiting pane", []proto.Session{{ID: "a", Status: proto.Waiting, Panes: []proto.Pane{
			{ID: "p1", Status: proto.Waiting}, {ID: "p2", Status: proto.Working},
		}}}, true},
		{"behind unread output", []proto.Session{{ID: "a", Status: proto.Idle, Panes: []proto.Pane{
			{ID: "p1", Status: proto.Idle, Unread: true}, {ID: "p2", Status: proto.Working},
		}}}, true},
		{"another host's", []proto.Session{{ID: "remote", Status: proto.Working, Panes: []proto.Pane{{Status: proto.Working}}}}, false},
	} {
		if got := anyWorking(c.sessions, local); got != c.want {
			t.Errorf("%s: anyWorking = %v, want %v", c.name, got, c.want)
		}
	}
}

// Keep display on shows in Settings, where a hold can keep the display
// on, while a mode keeps the computer awake, and its switch saves it.
func TestKeepDisplayOnRow(t *testing.T) {
	if !awakeDisplay {
		t.Skip("a hold can't keep the display on here")
	}
	a := testApp(t)
	a.ss.page = "general"
	tt := ui.NewTester(a.settingsView, 820, 2400)
	tt.Frame()
	label := locales.AwakeDisplay()
	if tt.HasText(label) {
		t.Error("Keep display on shows while Keep computer awake is off")
	}
	a.set.KeepAwake = awakeAgents
	tt.Frame()
	tt.Frame()
	r, ok := tt.Find(label)
	d, _ := tt.Find(locales.AwakeDisplayDetail())
	if !ok {
		t.Fatalf("no row %q; texts %q", label, tt.Texts())
	}
	tt.ClickAt(752, (r.Y+d.Y+d.H)/2) // its switch, at the row's end, beside the label and the detail
	tt.Frame()
	tt.Frame()
	if !a.set.KeepDisplayOn || !settings.Load().KeepDisplayOn {
		t.Errorf("Keep display on is %v, saved %v, want both on", a.set.KeepDisplayOn, settings.Load().KeepDisplayOn)
	}
}

// The tray's Keep display on is ticked as the setting is, and can't be
// picked while no mode keeps the computer awake.
func TestAwakeTrayDisplay(t *testing.T) {
	if !awakeDisplay {
		t.Skip("a hold can't keep the display on here")
	}
	a := testApp(t)
	item := func() *mygo.MenuItem {
		sub := a.awakeTrayItem().Submenu
		return sub[len(sub)-1]
	}
	if it := item(); it.Label != locales.AwakeDisplay() || !it.Disabled || it.Checked {
		t.Errorf("with Keep computer awake off: %q, disabled %v, checked %v", it.Label, it.Disabled, it.Checked)
	}
	a.setKeepAwake(awakeAgents)
	a.setKeepDisplayOn(true)
	if it := item(); it.Disabled || !it.Checked {
		t.Errorf("with agents and the display on: disabled %v, checked %v", it.Disabled, it.Checked)
	}
}
