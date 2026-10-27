package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"text/tabwriter"
	"time"

	"kero/internal/build"
	"kero/internal/client"
	"kero/internal/daemon"
	"kero/internal/proto"
	"kero/internal/remote"
	"kero/internal/service"
	"kero/internal/settings"
	"kero/internal/update"
)

// splitHost takes the global -H/--host off the front of the arguments:
// the host to act on, else $KERO_HOST, else "" for this machine; env
// tells a host of $KERO_HOST's. Inside a pane, $KERO_HOST, which a
// shell's profile may set, gives way to the pane's own machine.
func splitHost(args []string) (host string, env bool, rest []string, err error) {
	if os.Getenv("KERO_PANE") == "" {
		host = os.Getenv("KERO_HOST")
		env = host != ""
	}
	for len(args) > 0 {
		a := args[0]
		switch {
		case a == "-H" || a == "--host":
			if len(args) < 2 {
				return "", false, nil, usageErr("%s needs a host: a name of kero hosts, or an address", a)
			}
			host, env, args = args[1], false, args[2:]
		case strings.HasPrefix(a, "--host="):
			host, env, args = strings.TrimPrefix(a, "--host="), false, args[1:]
		case strings.HasPrefix(a, "-H") && len(a) > 2:
			host, env, args = a[2:], false, args[1:]
		default:
			if strings.EqualFold(host, "local") {
				host = ""
			}
			return host, env, args, nil
		}
	}
	return "", false, nil, usageErr("kero -H <host> <command> (see kero help)")
}

// localOnly are the commands of this machine alone, which -H takes
// nothing of.
var localOnly = map[string]bool{"report": true, "actions": true, "skill": true, "hook": true, "config": true,
	"hosts": true, "__bridge": true, "help": true, "--help": true, "-h": true}

// onHost is the host the command acts on, "" for this machine: whose
// panes $KERO_PANE and $KERO_SESSION name nothing on another.
var onHost string

// versionCmd prints the version of Kero, and of a host's.
func versionCmd(host string) error {
	v := build.Version()
	if v == "" {
		v = "dev"
	}
	if build.Server {
		v += ", server build"
	}
	fmt.Printf("kero %s (protocol %d)\n", v, proto.Version)
	if host == "" {
		return nil
	}
	rc, err := dialHost(host)
	if err != nil {
		return err
	}
	defer rc.Close()
	h := rc.Welcome.Host
	fmt.Printf("%s: kero %s (protocol %d) on %s/%s\n", host, orDash(h.Kero), h.Version, h.OS, h.Arch)
	return nil
}

// hostAddr is the address of a host: a saved host's, by name, else the
// address given.
func hostAddr(host string) (string, remote.Addr, error) {
	set := settings.Load()
	if h := set.Host(host); h != nil {
		a, err := remote.ParseAddr(h.Addr)
		return h.Name, a, err
	}
	a, err := remote.ParseAddr(host)
	if err != nil {
		return "", a, fmt.Errorf("%w: %q is no host of kero hosts, nor an address: %v", errNotFound, host, err)
	}
	return a.Label(), a, nil
}

// dialHost connects to a host.
func dialHost(host string) (*remote.Conn, error) {
	_, a, err := hostAddr(host)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c, err := remote.Dial(ctx, a, remote.Options{App: build.Version(), Client: clientName("kero CLI")})
	if err != nil {
		return nil, fmt.Errorf("%w: %s: %v", errUnreachable, host, err)
	}
	return c, nil
}

// clientName says what a client is, for kero clients on the host.
func clientName(what string) string {
	h, _ := os.Hostname()
	s := what
	if v := build.Version(); v != "" {
		s += " " + v
	}
	if h != "" {
		s += " on " + h
	}
	return s
}

// connect opens a control connection to kerod: this machine's, started
// as needed, or a host's.
func connect(host string) (*client.Client, func(), error) {
	if host == "" {
		c, err := client.Connect(false)
		if err != nil {
			return nil, nil, err
		}
		return c, func() { c.Close() }, nil
	}
	rc, err := dialHost(host)
	if err != nil {
		return nil, nil, err
	}
	c, err := client.ConnectVia(rc)
	if err != nil {
		rc.Close()
		if errors.Is(err, client.ErrVersion) {
			return nil, nil, fmt.Errorf("%w: kerod on %s runs Kero %s: update it, or this one (kero -H %s daemon update)", errUnreachable, host, rc.Welcome.Host.Kero, host)
		}
		return nil, nil, fmt.Errorf("%w: %s: %v", errUnreachable, host, err)
	}
	return c, func() { c.Close(); rc.Close() }, nil
}

// hostsCmd manages the hosts the app shows and -H reaches, which the
// configuration keeps (host = name=address).
func hostsCmd(args []string) error {
	f, err := parse(args, map[string]string{"version": "version"},
		map[string]string{"remote-control": "rc", "json": "json"})
	if err != nil {
		return err
	}
	sub := "ls"
	if len(f.pos) > 0 {
		sub = f.pos[0]
	}
	set := settings.Load()
	switch sub {
	case "ls", "list":
		if f.set["json"] {
			if set.Hosts == nil {
				set.Hosts = []settings.Host{}
			}
			return printJSON(set.Hosts)
		}
		if len(set.Hosts) == 0 {
			fmt.Println("no hosts (add one with kero hosts add <name> <address>)")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tADDRESS\tREMOTE CONTROL")
		for _, h := range set.Hosts {
			rc := "off"
			if h.RemoteControl {
				rc = "on"
			}
			fmt.Fprintf(w, "%s\t%s\t%s\n", h.Name, h.Addr, rc)
		}
		return w.Flush()

	case "add":
		if len(f.pos) != 3 {
			return usageErr("kero hosts add <name> <address> [--remote-control]")
		}
		line := f.pos[1] + "=" + f.pos[2]
		if f.set["rc"] {
			line += " remote-control"
		}
		h, err := settings.ParseHost(line)
		if err != nil {
			return usageErr("%v", err)
		}
		if old := set.Host(h.Name); old != nil {
			*old = h
		} else {
			set.Hosts = append(set.Hosts, h)
		}
		if err := settings.Save(set); err != nil {
			return err
		}
		fmt.Printf("added %s (%s): kero -H %s ls\n", h.Name, h.Addr, h.Name)
		return nil

	case "remove", "rm":
		if len(f.pos) != 2 {
			return usageErr("kero hosts remove <name>")
		}
		h := set.Host(f.pos[1])
		if h == nil {
			return fmt.Errorf("%w: no host %q", errNotFound, f.pos[1])
		}
		name := h.Name
		set.Hosts = deleteHost(set.Hosts, name)
		return settings.Save(set)

	case "check":
		if len(f.pos) != 2 {
			return usageErr("kero hosts check <name|address>")
		}
		start := time.Now()
		rc, err := dialHost(f.pos[1])
		if err != nil {
			return err
		}
		defer rc.Close()
		h := rc.Welcome.Host
		fmt.Printf("%s: connected in %s, compression %s\n", f.pos[1], time.Since(start).Round(time.Millisecond), orDash(rc.Welcome.Compress))
		fmt.Printf("host: %s (%s/%s), as %s, home %s\n", h.Hostname, h.OS, h.Arch, h.User, h.Home)
		kind := "the desktop app"
		if h.Server {
			kind = "the server build"
		}
		fmt.Printf("kero: %s (protocol %d), %s\n", orDash(h.Kero), h.Version, kind)
		if rtt, err := rc.Ping(); err == nil {
			fmt.Printf("round trip: %s\n", rtt.Round(100*time.Microsecond))
		}
		c, err := client.ConnectVia(rc)
		if err != nil {
			return fmt.Errorf("kerod: %w", err)
		}
		defer c.Close()
		var st proto.State
		c.Call("state", nil, &st)
		fmt.Printf("kerod: Kero %s, pid %d, %d sessions\n", orDash(c.Welcome.App), c.Welcome.PID, len(st.Sessions))
		return nil

	case "install":
		if len(f.pos) != 2 {
			return usageErr("kero hosts install <name|address> [--version v]")
		}
		_, a, err := hostAddr(f.pos[1])
		if err != nil {
			return err
		}
		version := f.vals["version"]
		if version == "" {
			version = releasedVersion()
		}
		// A host of Windows, whose shell has no sh, installs with
		// PowerShell.
		if err := remote.FindShell(a, false); err != nil {
			return err
		}
		cmd, err := remote.InstallCommand(a, version, false)
		if err != nil {
			return err
		}
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	}
	return usageErr("kero hosts ls|add|remove|check|install")
}

// releasedVersion is this Kero's version, to install the same on a host,
// "" for a development build, which installs the latest release.
func releasedVersion() string {
	v := build.Version()
	if v == "" || strings.Contains(v, "dev") {
		return ""
	}
	return v
}

func deleteHost(hosts []settings.Host, name string) []settings.Host {
	var out []settings.Host
	for _, h := range hosts {
		if !strings.EqualFold(h.Name, name) {
			out = append(out, h)
		}
	}
	return out
}

// clientsCmd lists who is connected to kerod.
func clientsCmd(c *client.Client, args []string) error {
	f, err := parse(args, nil, map[string]string{"json": "json"})
	if err != nil {
		return err
	}
	var list []proto.ClientInfo
	if err := c.Call("clients", nil, &list); err != nil {
		return err
	}
	if f.set["json"] {
		return printJSON(list)
	}
	now := time.Now()
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "KIND\tPEER\tVIA\tSINCE\tCLIENT\tSESSION")
	for _, ci := range list {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", ci.Kind, ci.Peer, ci.Via, proto.Ago(ci.Since, now), orDash(ci.Client), orDash(ci.Session))
	}
	return w.Flush()
}

// bridge is `kero __bridge`, which ssh or wsl.exe runs for a client on
// another machine: it answers the client's remote connection on its
// standard input and output, and passes each stream on to this machine's
// kerod, starting it as needed, as a local client would connect. It
// speaks to kerod as any client does, so that it bridges to a kerod of
// another version too, for the client to tell the user so, and to update
// and restart it.
func bridge(args []string) error {
	f, err := parse(args, map[string]string{"via": "via"}, nil)
	if err != nil {
		return err
	}
	via := f.vals["via"]
	if via == "" {
		via = "ssh"
	}
	peer := ""
	if c := strings.Fields(os.Getenv("SSH_CONNECTION")); len(c) > 0 {
		peer = c[0]
	}
	info := remote.LocalInfo("")
	if peer == "" {
		peer = info.User
	} else {
		peer = info.User + " from " + peer
	}
	info.Peer = info.User
	srv := &remote.Server{
		Info: func() proto.HostInfo { return info },
		Stream: func(s net.Conn, hello []byte, mux proto.MuxHello) {
			defer s.Close()
			conn, err := client.Local{}.Dial()
			if err != nil {
				b, _ := json.Marshal(proto.Welcome{Version: proto.Version, Error: "kerod: " + err.Error()})
				s.Write(append(b, '\n'))
				return
			}
			defer conn.Close()
			// Who connects, for kero clients, in the stream's own Hello,
			// which a kerod of any version takes.
			var h map[string]any
			if json.Unmarshal(hello, &h) == nil {
				h["peer"], h["via"], h["client"] = peer, via, mux.Client
				if b, err := json.Marshal(h); err == nil {
					hello = append(b, '\n')
				}
			}
			if _, err := conn.Write(hello); err != nil {
				return
			}
			splice(s, conn)
		},
		Restart: func() (func(), error) { return nil, restartLocal() },
		// Done once the client is: the session's end, as when ssh's link
		// dropped, can wait on a read of the standard input that only the
		// end of the process ends.
		Closed: func() { os.Exit(0) },
	}
	if !info.Server && daemon.AppUpdates() {
		// The desktop app updates itself, then kerod restarts into it.
		info.Updates = true
		srv.Update = func(app string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			return daemon.UpdateApp(ctx, app)
		}
	} else if info.Updates {
		dir := update.InstallDir()
		// kerod starts from the install, as an update moves this one aside.
		client.Exe = filepath.Join(dir, "kero")
		srv.Update = func(app string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			// Never back to an older Kero: the app asks for its own version.
			return update.Install(ctx, app, dir, build.Version(), false)
		}
	}
	return srv.Serve(stdio{})
}

// restartLocal restarts this machine's kerod into the Kero installed: its
// service's, else one this executable starts.
func restartLocal() error {
	if service.Installed() {
		if err := service.Restart(); !errors.Is(err, service.ErrUnsupported) {
			return err
		}
	}
	if err := StopDaemon(); err != nil {
		return err
	}
	return client.StartDaemon()
}

// splice copies both ways between two connections until either ends.
func splice(a, b net.Conn) {
	var once sync.Once
	done := make(chan struct{})
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		once.Do(func() { close(done) })
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	a.Close()
	b.Close()
}

// stdio is the bridge's connection: its standard input and output.
type stdio struct{}

func (stdio) Read(p []byte) (int, error)  { return os.Stdin.Read(p) }
func (stdio) Write(p []byte) (int, error) { return os.Stdout.Write(p) }
func (stdio) Close() error {
	os.Stdin.Close()
	return os.Stdout.Close()
}

// serveCmd is `kero daemon serve`: kerod in the foreground, for a service
// manager, which never exits for being idle.
func serveCmd(args []string) error {
	var listen []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--listen" || a == "-l":
			if i+1 >= len(args) {
				return usageErr("%s needs a listener: tailnet://:7373 or tailnet-serve://", a)
			}
			i++
			listen = append(listen, args[i])
		case strings.HasPrefix(a, "--listen="):
			listen = append(listen, strings.TrimPrefix(a, "--listen="))
		default:
			return usageErr("kero daemon serve [--listen tailnet://:7373]…")
		}
	}
	for _, l := range listen {
		if _, err := remote.ParseListen(l); err != nil {
			return usageErr("%v", err)
		}
	}
	return daemon.Run(daemon.Options{Serve: true, Listen: listen})
}
