package proto

import (
	"slices"
	"testing"
)

func TestSortPorts(t *testing.T) {
	ports := []Port{
		{Port: 22, System: true},
		{Port: 9000},
		{Port: 8080, Session: "other"},
		{Port: 5000, Session: "mine"},
		{Port: 3000, Session: "mine"},
		{Port: 4000, Session: "other"},
		{Port: 1000},
		{Port: 5, Session: "mine", System: true},
	}
	SortPorts(ports, "mine")
	var got []int
	for _, p := range ports {
		got = append(got, p.Port)
	}
	if want := []int{3000, 5000, 4000, 8080, 1000, 9000, 5, 22}; !slices.Equal(got, want) {
		t.Errorf("mine first: %v", got)
	}
	SortPorts(ports, "")
	got = got[:0]
	for _, p := range ports {
		got = append(got, p.Port)
	}
	if want := []int{3000, 4000, 5000, 8080, 1000, 9000, 5, 22}; !slices.Equal(got, want) {
		t.Errorf("no session: %v", got)
	}
}

func TestPortReachable(t *testing.T) {
	for addrs, want := range map[string]bool{"127.0.0.1": true, "::1": true, "0.0.0.0": true, "::": true, "100.64.0.1": false, "192.168.1.2": false, "": false} {
		if got := (Port{Addrs: []string{addrs}}).Reachable(); got != want {
			t.Errorf("%q: %v", addrs, got)
		}
	}
	if !(Port{Addrs: []string{"192.168.1.2", "127.0.0.1"}}).Reachable() {
		t.Error("any loopback address reaches it")
	}
}

func TestPortURL(t *testing.T) {
	for _, c := range []struct {
		host       string
		port, orig int
		want       string
	}{
		{"localhost", 3000, 3000, "http://localhost:3000"},
		{"localhost", 3001, 3000, "http://localhost:3001"},
		{"localhost", 80, 80, "http://localhost"},
		{"localhost", 443, 443, "https://localhost"},
		{"localhost", 50443, 443, "https://localhost:50443"},
		{"localhost", 8443, 8443, "https://localhost:8443"},
		{"fd00::1", 3000, 3000, "http://[fd00::1]:3000"},
	} {
		if got := PortURL(c.host, c.port, c.orig); got != c.want {
			t.Errorf("%+v: %s", c, got)
		}
	}
	if got := (PortForward{Port: 3000, Local: 3001}).URL(); got != "http://localhost:3001" {
		t.Errorf("URL: %s", got)
	}
}

func TestLoopbackPort(t *testing.T) {
	for raw, want := range map[string]int{
		"http://localhost:3000/docs":   3000,
		"http://127.0.0.1:8080":        8080,
		"http://[::1]:5173/":           5173,
		"http://0.0.0.0:4000":          4000,
		"http://app.localhost:3001":    3001,
		"http://localhost":             80,
		"https://localhost":            443,
		"https://example.com:3000":     0,
		"http://192.168.1.2:3000":      0,
		"about:blank":                  0,
		"file:///tmp/a.html":           0,
		"http://localhost.example.com": 0,
	} {
		got, ok := LoopbackPort(raw)
		if ok != (want != 0) || got != want {
			t.Errorf("%s: %d %v", raw, got, ok)
		}
	}
}
