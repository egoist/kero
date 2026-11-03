package proto

import (
	"cmp"
	"net/netip"
	"net/url"
	"slices"
	"strconv"
	"strings"
)

// A machine's kerod lists the TCP ports listening on it (the ports.list
// method), and tunnels a remote client's connections to them, one stream
// each, opened with a Hello of kind KindPort: only to its own loopback.
//
// The other end of a tunnel is the kerod of the machine the user sits at,
// which listens on its own loopback for them (the ports.forward method,
// ports.stop, and State.Forwards). A kerod of an older Kero answers
// ports.list as an unknown method, and takes a KindPort Hello for a control
// connection's, whose Welcome then echoes no Port: the client tells the
// user to update it.

// KindPort opens a stream to a port of the host's loopback (Hello.Port).
const KindPort = "port"

// Port is a TCP port listening on a machine.
type Port struct {
	Port int `json:"port"`
	// Addrs are the addresses it listens on, as "127.0.0.1", "::1", or
	// "0.0.0.0" and "::" for all of them.
	Addrs []string `json:"addrs"`
	// PID and Process are what listens, when the machine's user may see it.
	PID     int    `json:"pid,omitempty"`
	Process string `json:"process,omitempty"`
	// Pane and Session are the pane whose shell started it, and its
	// session, when it can be told by the tree of processes.
	Pane    string `json:"pane,omitempty"`
	Session string `json:"session,omitempty"`
	// System tells what is rarely of interest: what the system, or an app
	// for itself, listens on, which lists show last, or hide.
	System bool `json:"system,omitempty"`
}

// PortList answers ports.list.
type PortList struct {
	Ports []Port `json:"ports"`
}

// Reachable tells a port a tunnel can reach, or localhost here: one that
// listens on the loopback, or on every address.
func (p Port) Reachable() bool {
	for _, a := range p.Addrs {
		if ip, err := netip.ParseAddr(a); err == nil && (ip.IsLoopback() || ip.IsUnspecified()) {
			return true
		}
	}
	return false
}

// SortPorts puts a list in the order to show it: what the session's panes
// listen on first, then other panes', then the rest, the system's last,
// each by its port.
func SortPorts(ports []Port, session string) {
	rank := func(p Port) int {
		switch {
		case p.System:
			return 3
		case session != "" && p.Session == session:
			return 0
		case p.Session != "":
			return 1
		}
		return 2
	}
	slices.SortStableFunc(ports, func(a, b Port) int {
		return cmp.Or(cmp.Compare(rank(a), rank(b)), cmp.Compare(a.Port, b.Port))
	})
}

// PortForward is a port of a host forwarded to this machine's loopback.
type PortForward struct {
	Host string `json:"host"` // what the user calls the host
	Addr string `json:"addr"` // how it is reached, as remote.ParseAddr reads it
	Port int    `json:"port"` // on the host
	// Local is the port on this machine's loopback, which may be another
	// than Port, should Port be taken here.
	Local int   `json:"local"`
	Since int64 `json:"since"` // unix ms
}

// URL is where the forward answers on this machine.
func (f PortForward) URL() string { return PortURL("localhost", f.Local, f.Port) }

// PortURL is the URL of a server on a host and port: https for the port
// that was TLS's on the machine that listens on it, and its alternative,
// http for any other, as a dev server's. orig is the port on that machine.
func PortURL(host string, port, orig int) string {
	scheme := "http"
	if orig == 443 || orig == 8443 {
		scheme = "https"
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port == 80 && scheme == "http" || port == 443 && scheme == "https" {
		return scheme + "://" + host
	}
	return scheme + "://" + host + ":" + strconv.Itoa(port)
}

// LoopbackPort tells the port of a URL on the machine that loads it, as
// "http://localhost:3000/docs": what a browser pane's page means by it
// lives where the app does, whichever host the pane's session runs on.
func LoopbackPort(raw string) (int, bool) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" && u.Scheme != "https" {
		return 0, false
	}
	host := u.Hostname()
	if host != "localhost" && !strings.HasSuffix(host, ".localhost") {
		ip, err := netip.ParseAddr(host)
		if err != nil || !ip.IsLoopback() && !ip.IsUnspecified() {
			return 0, false
		}
	}
	switch p := u.Port(); {
	case p != "":
		n, err := strconv.Atoi(p)
		return n, err == nil
	case u.Scheme == "https":
		return 443, true
	}
	return 80, true
}

// Params of the ports methods.
type (
	// PortForwardParams forward a host's port to this machine, on Local, or
	// when 0 on Port itself should it be free, else on another. Keep has it
	// outlive the connection that asks, as the CLI's, which ends at once.
	PortForwardParams struct {
		Host  string `json:"host"`
		Addr  string `json:"addr"`
		Port  int    `json:"port"`
		Local int    `json:"local,omitempty"`
		Keep  bool   `json:"keep,omitempty"`
	}
	// PortForwarded answers ports.forward. Refused tells that nothing
	// listens on the port on the host yet, which the forward waits for.
	PortForwarded struct {
		PortForward
		Refused bool `json:"refused,omitempty"`
	}
	// PortStopParams stop the forwards of a host, Addr, of Port on it; with
	// no Addr, those whose port on this machine, or on their host, is Port.
	PortStopParams struct {
		Addr string `json:"addr,omitempty"`
		Port int    `json:"port"`
	}
)
