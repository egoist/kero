package cli

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"

	"kero/internal/client"
	"kero/internal/proto"
)

// portRow is a port as kero ports --json prints it: where it is forwarded
// to on this machine, if it is.
type portRow struct {
	proto.Port
	Forward *proto.PortForward `json:"forward,omitempty"`
	URL     string             `json:"url,omitempty"`
}

// portsCmd is kero ports: the ports listening on a machine, and the forwards
// of a host's to this one, which this machine's kerod holds, whichever
// machine -H names.
func portsCmd(args []string, host string) error {
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "forward":
		return portsForward(args[1:], host)
	case "stop":
		return portsStop(args[1:], host)
	}
	return portsList(args, host)
}

func portsList(args []string, host string) error {
	f, err := parse(args, nil, map[string]string{"json": "json", "j": "json", "all": "all", "a": "all"})
	if err != nil {
		return err
	}
	if len(f.pos) > 1 {
		return usageErr("kero ports [target] [--all] [--json]")
	}
	c, done, err := connectFor(host)
	if err != nil {
		return err
	}
	defer done()
	var st proto.State
	if err := c.Call("state", nil, &st); err != nil {
		return err
	}
	// The ports of the target's session first: this pane's by default, none
	// outside Kero.
	session := ""
	if len(f.pos) > 0 || current() != "" {
		t, err := findOrCurrent(st, f.pos)
		if err != nil {
			return err
		}
		session = t.s.ID
	}
	var list proto.PortList
	if err := c.Call("ports.list", nil, &list); err != nil {
		return hostTooOld(err, host)
	}
	proto.SortPorts(list.Ports, session)
	fwds, addr := []proto.PortForward(nil), ""
	if host != "" {
		_, a, err := hostAddr(host)
		if err != nil {
			return err
		}
		addr = a.String()
		fwds = localForwards()
	}
	rows := make([]portRow, len(list.Ports))
	hidden := 0
	for i, p := range list.Ports {
		rows[i].Port = p
		if p.Reachable() && host == "" {
			rows[i].URL = proto.PortURL("localhost", p.Port, p.Port)
		}
		for _, fw := range fwds {
			if fw.Addr == addr && fw.Port == p.Port {
				rows[i].Forward = &fw
				rows[i].URL = fw.URL()
			}
		}
		if p.System && rows[i].Forward == nil {
			hidden++
		}
	}
	if f.set["json"] {
		return printJSON(rows)
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "PORT\tADDRESS\tPROCESS\tPID\tSESSION\tPANE\tLOCAL")
	for _, r := range rows {
		if r.System && !f.set["all"] && r.Forward == nil {
			continue
		}
		pid := ""
		if r.PID != 0 {
			pid = strconv.Itoa(r.PID)
		}
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", r.Port.Port, strings.Join(r.Addrs, ","), orDash(r.Process), orDash(pid), orDash(r.Session), orDash(r.Pane), orDash(r.URL))
	}
	if err := w.Flush(); err != nil {
		return err
	}
	if hidden > 0 && !f.set["all"] {
		fmt.Printf("and %d of the system and of apps (--all shows them)\n", hidden)
	}
	return nil
}

// connectFor connects to a machine's kerod as run does for its commands.
func connectFor(host string) (*client.Client, func(), error) {
	c, done, err := connect(host)
	if err == nil {
		return c, done, nil
	}
	switch {
	case errors.Is(err, client.ErrVersion):
		return nil, nil, fmt.Errorf("%w: the running kerod is of another version: run `kero daemon restart` (it restarts sessions)", errUnreachable)
	case errors.Is(err, errUnreachable) || errors.Is(err, errNotFound):
		return nil, nil, err
	}
	return nil, nil, fmt.Errorf("%w: %v", errUnreachable, err)
}

// hostTooOld says what to do of a kerod that knows no ports methods.
func hostTooOld(err error, host string) error {
	if !strings.Contains(err.Error(), "unknown method") {
		return err
	}
	if host == "" {
		return errors.New("the running kerod is older than ports: run `kero daemon restart` (it restarts sessions)")
	}
	return fmt.Errorf("Kero on %s is older than ports: update it (kero -H %s daemon update)", host, host)
}

// localForwards are the forwards this machine's kerod holds, none when it
// doesn't run.
func localForwards() []proto.PortForward {
	c, err := client.Connect(true)
	if err != nil {
		return nil
	}
	defer c.Close()
	var st proto.State
	c.Call("state", nil, &st)
	return st.Forwards
}

func portsForward(args []string, host string) error {
	f, err := parse(args, map[string]string{"local": "local", "l": "local"}, map[string]string{"json": "json", "j": "json"})
	if err != nil {
		return err
	}
	const use = "kero ports forward <port> [--local <port>] [target]"
	if len(f.pos) < 1 || len(f.pos) > 2 {
		return usageErr(use)
	}
	port, err := parsePort(f.pos[0])
	if err != nil {
		return usageErr("%v: %s", err, use)
	}
	local := 0
	if v, ok := f.vals["local"]; ok {
		if local, err = parsePort(v); err != nil {
			return usageErr("--local: %v", err)
		}
	}
	// A target names a session of the machine the port is on, which must
	// be there.
	if len(f.pos) == 2 {
		c, done, err := connectFor(host)
		if err != nil {
			return err
		}
		defer done()
		var st proto.State
		if err := c.Call("state", nil, &st); err != nil {
			return err
		}
		if _, err := find(st, f.pos[1]); err != nil {
			return err
		}
	}
	if host == "" {
		fmt.Fprintf(os.Stderr, "port %d is on this machine: nothing to forward\n", port)
		fmt.Println(proto.PortURL("localhost", port, port))
		return nil
	}
	name, a, err := hostAddr(host)
	if err != nil {
		return err
	}
	c, done, err := connectFor("")
	if err != nil {
		return err
	}
	defer done()
	var res proto.PortForwarded
	if err := c.Call("ports.forward", proto.PortForwardParams{Host: name, Addr: a.String(), Port: port, Local: local, Keep: true}, &res); err != nil {
		return hostTooOld(err, "")
	}
	if res.Refused {
		fmt.Fprintf(os.Stderr, "nothing listens on port %d on %s yet: connections fail until something does\n", port, name)
	}
	if res.Local != port {
		fmt.Fprintf(os.Stderr, "port %d of %s is on port %d here: %d is taken on this machine\n", port, name, res.Local, port)
	}
	if f.set["json"] {
		return printJSON(res)
	}
	fmt.Println(res.URL())
	return nil
}

func portsStop(args []string, host string) error {
	f, err := parse(args, nil, nil)
	if err != nil {
		return err
	}
	if len(f.pos) != 1 {
		return usageErr("kero ports stop <port>")
	}
	port, err := parsePort(f.pos[0])
	if err != nil {
		return usageErr("%v: kero ports stop <port>", err)
	}
	p := proto.PortStopParams{Port: port}
	if host != "" {
		_, a, err := hostAddr(host)
		if err != nil {
			return err
		}
		p.Addr = a.String()
	}
	c, done, err := connectFor("")
	if err != nil {
		return err
	}
	defer done()
	var gone []proto.PortForward
	if err := c.Call("ports.stop", p, &gone); err != nil {
		return hostTooOld(err, "")
	}
	for _, fw := range gone {
		fmt.Fprintf(os.Stderr, "stopped forwarding port %d of %s from localhost:%d\n", fw.Port, fw.Host, fw.Local)
	}
	return nil
}

func parsePort(s string) (int, error) {
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 || n > 65535 {
		return 0, fmt.Errorf("%q is not a port", s)
	}
	return n, nil
}
