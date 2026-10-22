package main

import (
	"encoding/json"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/actions"
)

// The strip shows one host's sessions alone, and every host's: it brings
// the session the user looked at last there, says which sessions need the
// user on each, and New Session acts on the host it shows.
func TestHostStrip(t *testing.T) {
	a := testApp(t)
	a.mergeState(a.local(), a.st)
	build := withHost(t, a, "build")
	gpu := withHost(t, a, "gpu")
	tt := ui.NewTester(a.view, 1100, 700)
	tt.Frame()
	shot(t, tt, "strip-all")
	for _, h := range []*host{nil, a.local(), build, gpu} {
		n := slices.Index(a.hosts, h) + 1
		if _, ok := tt.Find(a.spaceTip(h, n)); !ok {
			t.Errorf("no button %q: %q", a.spaceTip(h, n), tt.Texts())
		}
	}
	if tip := a.spaceTip(build, 2); tip != "build · 1 needs you ("+spaceKeyText(2)+")" {
		t.Errorf("build's button says %q", tip)
	}
	if ids := a.visibleOrder(); len(ids) != 3 {
		t.Errorf("all: %q", ids)
	}

	if err := tt.Click(a.spaceTip(build, 2)); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	shot(t, tt, "strip-build")
	if a.prefs.Space != "build" || a.selected != "rs-build" {
		t.Errorf("space %q, selected %q", a.prefs.Space, a.selected)
	}
	if ids := a.visibleOrder(); len(ids) != 1 || ids[0] != "rs-build" {
		t.Errorf("build alone: %q", ids)
	}
	if tt.HasText("agent on gpu") {
		t.Error("another host's sessions show")
	}
	if a.spaceOrSelectedHost() != build {
		t.Error("New Session acts elsewhere")
	}

	// Back to this machine, by its keys: the session looked at last there.
	tt.Key(spaceMods(), ui.Key1)
	tt.Frame()
	if a.prefs.Space != spaceLocal || a.selected != "s1" {
		t.Errorf("keys: space %q, selected %q", a.prefs.Space, a.selected)
	}
	// A session of another host selected, as by ⌘J, shows its host.
	a.selectSession("rs-gpu")
	if a.prefs.Space != "gpu" {
		t.Errorf("selecting gpu's session shows %q", a.prefs.Space)
	}
	tt.Key(spaceMods(), ui.Key0)
	tt.Frame()
	if a.prefs.Space != "" || len(a.visibleOrder()) != 3 {
		t.Errorf("all again: %q", a.prefs.Space)
	}

	// Remembered across runs.
	a.showSpace(gpu)
	var p prefs
	if b, err := os.ReadFile(prefsPath()); err != nil || json.Unmarshal(b, &p) != nil || p.Space != "gpu" || p.LastSelected["build"] != "rs-build" {
		t.Errorf("prefs %+v, %v", p, err)
	}

	// A host removed shows all.
	a.hosts = a.hosts[:2]
	if a.spaceHost() != nil || len(a.visibleOrder()) != 2 {
		t.Error("the space of a host gone still filters")
	}
}

// With this machine alone, there is no strip.
func TestHostStripAlone(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 700)
	tt.Frame()
	if _, ok := tt.Find(a.spaceTip(nil, 0)); ok {
		t.Error("a strip for one machine")
	}
	a.prefs.Space = spaceLocal
	if a.spaceHost() != nil {
		t.Error("one machine filters")
	}
}

// A host's color is its own, else its name's, which stays.
func TestHostColor(t *testing.T) {
	h := &host{name: "devbox"}
	if hostColorName(h) != hostColorName(&host{name: "DevBox"}) {
		t.Error("the color of a name changes with its case")
	}
	h.cfg.Color = "teal"
	if hostColorName(h) != "teal" {
		t.Error("the configured color is not taken")
	}
	if lightPalette.hostColor(h) == darkPalette.hostColor(h) {
		t.Error("one color for light and dark")
	}
	if lightPalette.hostColor(&host{}) != lightPalette.textMuted {
		t.Error("this machine is colored")
	}
}

// Dark, with the strip, and a remote pane's header in its host's color.
func TestHostStripDarkShot(t *testing.T) {
	a := testApp(t)
	a.mergeState(a.local(), a.st)
	withHost(t, a, "build").cfg.Color = "teal"
	withHost(t, a, "gpu")
	a.selectSession("rs-build")
	tt := ui.NewTester(a.view, 1100, 700)
	tt.SetDark(true)
	tt.Frame()
	tt.Advance(time.Second) // colors ease from the light frame's
	tt.Frame()
	shot(t, tt, "strip-dark")
}

func spaceKeyText(n int) string { return actions.Glyphs(spaceKeys(n)) }
