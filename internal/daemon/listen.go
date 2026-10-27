package daemon

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/egoist/mygo"

	"kero/internal/build"
	"kero/internal/proto"
	"kero/internal/remote"
	"kero/internal/settings"
	"kero/internal/tailscale"
	"kero/internal/update"
)

// listeners are kerod's network listeners (Options.Listen, else the
// configuration's listen key, which they follow as it changes), which
// take remote connections as WebSockets (remote.MuxPath), each from a
// caller Tailscale tells, and only from those the machine's owner allows:
// the owner, and listen-allow. They are off unless asked for.
type listeners struct {
	d *Daemon

	mu    sync.Mutex
	allow []string
	// on are the listeners asked for, by what the configuration calls
	// them.
	on     map[string]*listener
	closed bool
	// self is this machine on the tailnet, as tailscaled last said, and
	// when; whoCache who connected from where.
	self     tailscale.Self
	selfAt   time.Time
	whoCache map[string]cachedWho
	// isLocal, for tests, tells the addresses of this machine.
	isLocal func(netip.Addr) bool
}

// listener is one of the listeners, which stops, and drops the
// connections it took, as its context ends.
type listener struct {
	spec    remote.Listen
	ctx     context.Context
	cancel  context.CancelFunc
	servers []*http.Server // listeners.mu's
	socket  string
}

// listen starts the network listeners.
func (d *Daemon) listen() *listeners {
	l := &listeners{d: d, on: map[string]*listener{}}
	set := settings.Load()
	specs := d.opts.Listen
	if specs == nil {
		specs = set.Listen
		go l.follow(set)
	}
	l.set(specs, set.ListenAllow, true)
	return l
}

// follow applies the configuration's listen and listen-allow as they
// change, as Settings › Hosts turns this machine's listener on and off.
func (l *listeners) follow(last settings.Settings) {
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-l.d.quit:
			return
		case <-t.C:
		}
		set := settings.Load()
		if slices.Equal(set.Listen, last.Listen) && slices.Equal(set.ListenAllow, last.ListenAllow) {
			continue
		}
		last = set
		l.set(set.Listen, set.ListenAllow, false)
	}
}

// set makes the listeners those of specs, stopping the others, and lets
// in whom allow says. Once kerod has started, a Tailscale Serve socket
// waits for the next kerod: the umask it takes would be any program's
// kerod started meanwhile (see Run).
func (l *listeners) set(specs, allow []string, boot bool) {
	want := map[string]remote.Listen{}
	for _, s := range specs {
		spec, err := remote.ParseListen(s)
		if err != nil {
			l.d.log.Printf("listen: %v", err)
			continue
		}
		want[spec.String()] = spec
	}
	var serve []*listener
	defer func() {
		// At once, before kerod starts any program.
		for _, ln := range serve {
			l.serve(ln)
		}
	}()
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return
	}
	l.allow = slices.Clone(allow)
	for name, ln := range l.on {
		if _, ok := want[name]; !ok {
			l.d.log.Printf("no longer listening on %s", name)
			ln.stop()
			delete(l.on, name)
		}
	}
	for name, spec := range want {
		if l.on[name] != nil {
			continue
		}
		ln := &listener{spec: spec}
		ln.ctx, ln.cancel = context.WithCancel(context.Background())
		l.on[name] = ln
		switch {
		case spec.Kind == "tailnet":
			go l.tailnet(ln)
		case boot:
			serve = append(serve, ln)
		default:
			l.d.log.Printf("listen %s: restart kerod to listen there (kero daemon restart)", name)
		}
	}
}

// active reports whether kerod listens on the network, for remote clients
// to find it there: it then never exits for being idle.
func (l *listeners) active() bool {
	if l == nil {
		return false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.on) > 0
}

func (l *listeners) close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	for _, ln := range l.on {
		ln.stop()
	}
}

// stop stops a listener, and the connections it took; listeners.mu is
// held.
func (ln *listener) stop() {
	ln.cancel()
	for _, s := range ln.servers {
		s.Close()
	}
	if ln.socket != "" {
		os.Remove(ln.socket)
	}
}

// start serves a listener, unless it stopped.
func (l *listeners) start(lis *listener, ln net.Listener, via string) bool {
	srv := &http.Server{Handler: l.handler(lis.ctx, via), ReadHeaderTimeout: 10 * time.Second, ErrorLog: l.d.log}
	l.mu.Lock()
	if lis.ctx.Err() != nil {
		l.mu.Unlock()
		ln.Close()
		return false
	}
	lis.servers = append(lis.servers, srv)
	l.mu.Unlock()
	l.d.log.Printf("listening on %s (%s)", ln.Addr(), via)
	go srv.Serve(ln)
	return true
}

// tailnet listens on the machine's Tailscale addresses, once Tailscale is
// up: kerod may start before it, as at boot.
func (l *listeners) tailnet(lis *listener) {
	logged := false
	for {
		self, err := tailscale.Status(lis.ctx)
		if err == nil && len(self.IPs) > 0 {
			ok := 0
			for _, ip := range self.IPs {
				ln, err := net.Listen("tcp", net.JoinHostPort(ip.String(), lis.spec.Port))
				if err != nil {
					l.d.log.Printf("listen: %v", err)
					continue
				}
				if !l.start(lis, ln, "tailnet") {
					return
				}
				ok++
			}
			if ok > 0 {
				return
			}
		} else if !logged && lis.ctx.Err() == nil {
			l.d.log.Printf("listen %s: %v; trying again as Tailscale comes up", lis.spec, err)
			logged = true
		}
		select {
		case <-lis.ctx.Done():
			return
		case <-time.After(10 * time.Second):
		}
	}
}

// serve listens on a socket for Tailscale Serve, which only its user, and
// tailscaled, as root, can connect to: the headers Serve adds, which tell
// who connects, are then Serve's.
func (l *listeners) serve(lis *listener) {
	path := lis.spec.Path
	if path == "" {
		path = filepath.Join(proto.Dir(), "serve.sock")
	}
	os.Remove(path)
	ln, err := listenSocket(path)
	if err != nil {
		l.d.log.Printf("listen %s: %v", lis.spec, err)
		return
	}
	l.mu.Lock()
	lis.socket = path
	l.mu.Unlock()
	if !l.start(lis, ln, "tailnet-serve") {
		os.Remove(path)
	}
}

// selfStatus is this machine on the tailnet, as tailscaled last said, at
// most a minute ago: its owner's login, "" for a tagged machine, which
// only listen-allow lets anyone in to, and its addresses.
func (l *listeners) selfStatus(ctx context.Context) tailscale.Self {
	l.mu.Lock()
	self, at := l.self, l.selfAt
	l.mu.Unlock()
	if !at.IsZero() && time.Since(at) < time.Minute {
		return self
	}
	if s, err := tailscale.Status(ctx); err == nil {
		self = s
		l.mu.Lock()
		l.self, l.selfAt = s, time.Now()
		l.mu.Unlock()
	}
	return self
}

// local reports whether a connection comes from this machine: from a
// loopback address, or from one of its own Tailscale addresses, as any
// process of any user here can connect from, which tailscaled would take
// for the machine's owner. Such connections go through kerod's socket,
// which tells its users apart.
func (l *listeners) local(ctx context.Context, ip netip.Addr) bool {
	if l.isLocal != nil {
		return l.isLocal(ip)
	}
	ip = ip.Unmap()
	return ip.IsLoopback() || ip.IsUnspecified() || slices.Contains(l.selfStatus(ctx).IPs, ip)
}

// whois tells who connects from an address, asking tailscaled once a
// while for each address, so that a flood of requests spawns nothing.
func (l *listeners) whois(ctx context.Context, addr string) (tailscale.Who, error) {
	host, _, _ := net.SplitHostPort(addr)
	l.mu.Lock()
	c, ok := l.whoCache[host]
	l.mu.Unlock()
	if ok && time.Since(c.at) < 30*time.Second {
		return c.who, nil
	}
	who, err := tailscale.WhoIs(ctx, addr)
	if err != nil {
		return who, err
	}
	l.mu.Lock()
	if l.whoCache == nil || len(l.whoCache) > 1024 {
		l.whoCache = map[string]cachedWho{}
	}
	l.whoCache[host] = cachedWho{who, time.Now()}
	l.mu.Unlock()
	return who, nil
}

type cachedWho struct {
	who tailscale.Who
	at  time.Time
}

// identify tells who a request comes from, and whether they may connect.
func (l *listeners) identify(r *http.Request, via string) (tailscale.Who, error) {
	ctx := r.Context()
	var who tailscale.Who
	switch via {
	case "tailnet":
		ap, err := netip.ParseAddrPort(r.RemoteAddr)
		if err != nil {
			return who, err
		}
		if l.local(ctx, ap.Addr()) {
			return who, errors.New("a connection from this machine itself goes through kerod's socket, not the tailnet")
		}
		w, err := l.whois(ctx, r.RemoteAddr)
		if err != nil {
			return who, err
		}
		who = w
	case "tailnet-serve":
		// Funnel's are the internet's, whom Tailscale tells nothing of.
		if r.Header.Get("Tailscale-Funnel-Request") != "" {
			return who, errors.New("Kero takes no connections through Funnel")
		}
		who = tailscale.Who{Login: r.Header.Get("Tailscale-User-Login"), Name: r.Header.Get("Tailscale-User-Name")}
		if who.Login == "" {
			return who, errors.New("Tailscale Serve did not say who connects: tagged devices connect to a tailnet:// listener")
		}
	}
	l.mu.Lock()
	allow := l.allow
	l.mu.Unlock()
	if !tailscale.Allowed(who, l.selfStatus(ctx).Owner, allow) {
		return who, errors.New(who.String() + " may not connect: the machine's owner lets them in with listen-allow")
	}
	return who, nil
}

// handler answers a listener's requests, whose connections end as ctx
// does.
func (l *listeners) handler(ctx context.Context, via string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(remote.MuxPath, func(w http.ResponseWriter, r *http.Request) {
		// Only Kero: a browser sends an Origin with every WebSocket, and
		// cannot send Kero's header, so that no web page on the tailnet
		// reaches kerod through the browser of someone it lets in.
		if r.Header.Get("Origin") != "" || r.Header.Get(remote.ClientHeader) == "" {
			http.Error(w, "this is Kero's: connect with Kero", http.StatusForbidden)
			return
		}
		who, err := l.identify(r, via)
		if err != nil {
			l.d.log.Printf("refused %s (%s): %v", r.RemoteAddr, via, err)
			http.Error(w, err.Error(), http.StatusForbidden)
			return
		}
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			CompressionMode: websocket.CompressionDisabled,
			// Origin is checked above: there is none.
			InsecureSkipVerify: true,
		})
		if err != nil {
			return
		}
		ws.SetReadLimit(64 << 20)
		conn := websocket.NetConn(ctx, ws, websocket.MessageBinary)
		client := r.Header.Get(remote.ClientHeader)
		l.d.log.Printf("%s connected over %s: %s", who, via, client)
		err = l.d.remoteServer(identity{peer: who.String(), via: via, client: client}).Serve(conn)
		l.d.log.Printf("%s disconnected (%s): %v", who, via, err)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "Kero's daemon: connect with Kero (Settings › Hosts)", http.StatusNotFound)
	})
	return mux
}

// remoteServer answers a remote connection on kerod's behalf.
func (d *Daemon) remoteServer(id identity) *remote.Server {
	s := &remote.Server{
		Info: func() proto.HostInfo {
			h := remote.LocalInfo(id.peer)
			if !h.Server {
				h.Updates = AppUpdates()
			}
			return h
		},
		Stream: func(conn net.Conn, hello []byte, mux proto.MuxHello) {
			sid := id
			if sid.client == "" {
				sid.client = mux.Client
			}
			d.serveHello(conn, bufio.NewReaderSize(conn, 64<<10), hello, sid)
		},
		Restart: d.restart,
		Log:     d.log,
	}
	if build.Server && update.Managed(filepath.Dir(d.exe)) {
		s.Update = func(app string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			d.log.Printf("updating to Kero %s, as %s asked", app, id.peer)
			if err := update.Install(ctx, app, filepath.Dir(d.exe), build.Version(), false); err != nil {
				d.log.Printf("update: %v", err)
				return err
			}
			return nil
		}
	} else if !build.Server {
		s.Update = func(app string) error {
			if !AppUpdates() {
				return errors.New("Kero on this host takes updates from other machines only with remote-updates on: update it there")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			d.log.Printf("updating the app to Kero %s, as %s asked", app, id.peer)
			if err := UpdateApp(ctx, app); err != nil {
				d.log.Printf("update: %v", err)
				return err
			}
			return nil
		}
	}
	return s
}

// AppUpdates reports whether the desktop app here takes updates from
// Kero on other machines: the user let it (remote-updates), and it can
// update itself, as a development build or a package manager's can't.
func AppUpdates() bool {
	return settings.Load().RemoteUpdates && mygo.Updater.Enabled()
}

// UpdateApp installs the newest release of the desktop app in place of
// this one, as the app of version app asks, from its own signed feed: the
// release kerod restarts into, and the window here relaunches into as it
// finds kerod newer (App.relaunchForKerod). Never back to an older one.
func UpdateApp(ctx context.Context, app string) error {
	up, err := mygo.Updater.Check(ctx)
	if err != nil {
		return err
	}
	if up == nil {
		if update.Compare(build.Version(), app) >= 0 {
			return nil
		}
		return fmt.Errorf("no release of Kero %s or newer to update to", app)
	}
	if update.Compare(up.Version, app) < 0 {
		return fmt.Errorf("the newest release is Kero %s, older than %s", up.Version, app)
	}
	return up.Install(ctx, nil)
}

// restart restarts kerod, as a remote client asks after an update: it
// saves the sessions, which the next kerod starts again, as after a
// reboot, then ends; its service's manager, or its successor, starts the
// next.
func (d *Daemon) restart() (then func(), err error) {
	d.log.Printf("restarting, as a client asked")
	// Once the answer is written.
	return func() {
		d.saveHistories(true)
		d.saveState()
		d.mu.Lock()
		d.restarting = true
		d.mu.Unlock()
		d.stop()
	}, nil
}
