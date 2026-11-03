package main

import (
	"slices"
	"testing"

	"kero/internal/actions"
	"kero/internal/proto"
	"kero/internal/remote"
)

func portsApp(t *testing.T) (*App, *host) {
	t.Helper()
	addr, err := remote.ParseAddr("devbox")
	if err != nil {
		t.Fatal(err)
	}
	h := &host{name: "devbox", addr: addr, conn: connReady}
	return &App{hosts: []*host{{conn: connReady}, h}}, h
}

// The session's ports first, then the others', the system's folded until
// shown; a forwarded one stays in sight, and one with no listener left has a
// row to stop it by.
func TestPortItems(t *testing.T) {
	a, h := portsApp(t)
	s := &proto.Session{ID: "mine"}
	ports := []proto.Port{
		{Port: 22, Addrs: []string{"0.0.0.0"}, System: true},
		{Port: 5000, Addrs: []string{"127.0.0.1"}, System: true},
		{Port: 8080, Addrs: []string{"127.0.0.1"}, Session: "other"},
		{Port: 3000, Addrs: []string{"127.0.0.1"}, Session: "mine"},
		{Port: 9000, Addrs: []string{"127.0.0.1"}},
	}
	shape := func(items []portItem) (out []int) {
		for _, it := range items {
			if it.head != "" {
				out = append(out, 0)
			} else {
				out = append(out, it.port.Port)
			}
		}
		return out
	}
	if got, want := shape(a.portItems(h, s, ports)), []int{0, 3000, 0, 8080, 9000, 0}; !slices.Equal(got, want) {
		t.Errorf("rows: %v, want %v", got, want)
	}
	a.side.ports.system = true
	if got, want := shape(a.portItems(h, s, ports)), []int{0, 3000, 0, 8080, 9000, 0, 22, 5000}; !slices.Equal(got, want) {
		t.Errorf("unfolded: %v, want %v", got, want)
	}
	a.side.ports.system = false
	a.side.ports.forwards = []proto.PortForward{
		{Addr: "devbox", Port: 5000, Local: 5000},
		{Addr: "devbox", Port: 7777, Local: 7777},
		{Addr: "other", Port: 6666, Local: 6666}, // another host's
	}
	if got, want := shape(a.portItems(h, s, ports)), []int{0, 3000, 0, 8080, 7777, 9000, 5000, 0}; !slices.Equal(got, want) {
		t.Errorf("forwarded: %v, want %v", got, want)
	}
	// With nothing of the session's, no titles but the system's.
	if got, want := shape(a.portItems(h, &proto.Session{ID: "none"}, ports[2:3])), []int{8080, 5000, 7777}; !slices.Equal(got, want) {
		t.Errorf("no session's: %v, want %v", got, want)
	}
	if len(a.portItems(&host{name: "empty"}, s, nil)) != 0 {
		t.Error("rows for a host with no ports")
	}
}

func TestForwardLookups(t *testing.T) {
	a, h := portsApp(t)
	a.setForwards([]proto.PortForward{{Addr: "devbox", Port: 3000, Local: 3001}, {Addr: "other", Port: 3000, Local: 3000}})
	if f := a.forwardOf(h, 3000); f == nil || f.Local != 3001 {
		t.Errorf("forwardOf: %+v", f)
	}
	if f := a.forwardAt(h, 3001); f == nil || f.Port != 3000 {
		t.Errorf("forwardAt: %+v", f)
	}
	if a.forwardAt(h, 3000) != nil {
		t.Error("another host's forward counts for this one")
	}
	// What a page's port came from stays, once the forward has gone.
	a.setForwards(nil)
	if a.forwardOf(h, 3000) != nil || a.side.ports.origins[forwardKey(h, 3001)] != 3000 {
		t.Errorf("after: %+v", a.side.ports.origins)
	}
}

func TestLocalPortURL(t *testing.T) {
	for _, c := range []struct {
		addrs []string
		want  string
	}{
		{[]string{"127.0.0.1"}, "http://localhost:3000"},
		{[]string{"::"}, "http://localhost:3000"},
		{[]string{"100.64.0.1"}, "http://100.64.0.1:3000"},
		{nil, "http://localhost:3000"},
	} {
		if got := localPortURL(proto.Port{Port: 3000, Addrs: c.addrs}); got != c.want {
			t.Errorf("%v: %s", c.addrs, got)
		}
	}
}

func TestPortsTab(t *testing.T) {
	a, _ := portsApp(t)
	a.prefs.Side = sidePorts
	if a.sideTab() != sidePorts {
		t.Errorf("tab: %s", a.sideTab())
	}
	a.prefs.Side, a.prefs.SideTab = "", sidePorts
	if a.sideTab() != sidePorts {
		t.Errorf("tab kept while hidden: %s", a.sideTab())
	}
	a.prefs.Side = "something a later Kero wrote"
	if a.sideTab() != sideChanges {
		t.Errorf("unknown tab: %s", a.sideTab())
	}
}

func TestPortsAction(t *testing.T) {
	act, ok := actions.Find("ports.toggle")
	if !ok || !act.Remote || act.Keys == "" {
		t.Fatalf("action: %+v", act)
	}
	if actionTitles["ports.toggle"] == nil {
		t.Error("no title")
	}
	// plans/screen.md keeps this one for its tab.
	for _, a := range actions.All {
		if a.Keys == "CmdOrCtrl+Alt+S" {
			t.Errorf("%s takes Screen's shortcut", a.ID)
		}
		if a.ID != act.ID && a.Keys == act.Keys {
			t.Errorf("%s shares the shortcut", a.ID)
		}
	}
}

// A remote program toggles the tab only while its own host's session shows.
func TestPortsActionFromHost(t *testing.T) {
	a, h := portsApp(t)
	a.from = h
	if a.fromMay("ports.toggle", nil) {
		t.Error("a host toggled the tab of a session of no one's")
	}
}

func TestTabsFit(t *testing.T) {
	labels := []float32{53, 28, 33}
	// The room for the tabs at the default width, past what the sidebar's
	// edge and the window controls take: the same with controls or without,
	// so that the labels show on every platform.
	room := func(controls bool) float32 {
		w := defaultRight(controls) - 10
		if controls {
			w -= controlsW + 8
		}
		return w
	}
	if room(true) != room(false) {
		t.Errorf("the tabs' room: %v under the controls, %v without", room(true), room(false))
	}
	if !tabsFit(labels, room(true)) || !tabsFit(labels, room(false)) {
		t.Error("labels don't fit the default width")
	}
	if !tabsFit(append(labels, 42), room(false)) {
		t.Log("a fourth tab shows as icons at the default width")
	}
	// A sidebar dragged narrow shows icons.
	if tabsFit(labels, 162) {
		t.Error("labels fit a narrow sidebar")
	}
}
