package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"kero/internal/build"
	"kero/internal/proto"
	"kero/internal/remote"
)

// The kerod of the machine the user sits at holds the forwards: both the
// app and the CLI, which ends at once, ask it, and both see them. It listens
// on its loopback, never on another address, and takes each connection
// through a remote connection of its own to the host, as a stream to the
// port there (servePort), whichever transport reaches the host.
//
// A forward starts only as a client on this machine asks. It ends as it is
// stopped, as the connection to its host ends, as kerod does, and, when the
// app asked for it, as the app goes. kerod keeps none of them on disk, so
// that a port is never opened again with no one asking.

// errForwardsHere refuses a client of another machine, to whom a port on
// this machine's loopback means nothing.
var errForwardsHere = errors.New("ports are forwarded by the machine they come to: run this there, with -H for this host")

// tunnel is what forwards go through to a host: a remote.Conn.
type tunnel interface {
	DialPort(port int) (net.Conn, error)
	Done() <-chan struct{}
	Close() error
}

// forwards are the ports forwarded to this machine.
type forwards struct {
	d *Daemon
	// dial connects to a host, for tests.
	dial func(ctx context.Context, addr string) (tunnel, error)

	mu     sync.Mutex // after d.mu
	hosts  map[string]*fwdHost
	live   []*forward
	closed bool
}

// fwdHost is a host forwarded from, with the connection forwards share,
// open while any of them needs it.
type fwdHost struct {
	addr  string
	start sync.Mutex // one start at a time: the first connects for the others
	conn  tunnel     // forwards.mu's
	users int        // forwards, and starts under way
}

// forward is a port forwarded.
type forward struct {
	info  proto.PortForward
	host  *fwdHost
	conn  tunnel
	owner *controlConn // whose end ends it, nil for none
	lns   []net.Listener
	mu    sync.Mutex
	conns map[net.Conn]struct{} // nil once closed
}

func newForwards(d *Daemon) *forwards {
	return &forwards{d: d, hosts: map[string]*fwdHost{}, dial: dialTunnel}
}

// dialTunnel connects to a host, for this kerod's forwards.
func dialTunnel(ctx context.Context, addr string) (tunnel, error) {
	a, err := remote.ParseAddr(addr)
	if err != nil {
		return nil, err
	}
	name, _ := os.Hostname()
	client := "kerod"
	if v := build.Version(); v != "" {
		client += " " + v
	}
	if name != "" {
		client += " on " + name
	}
	return remote.Dial(ctx, a, remote.Options{App: build.Version(), Client: client})
}

// active tells that a port is forwarded: kerod stays for it.
func (f *forwards) active() bool {
	if f == nil {
		return false
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.live) > 0
}

// list lists the forwards, as they started.
func (f *forwards) list() []proto.PortForward {
	if f == nil {
		return nil
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.live) == 0 {
		return nil
	}
	out := make([]proto.PortForward, len(f.live))
	for i, fw := range f.live {
		out[i] = fw.info
	}
	return out
}

// start forwards a host's port to this machine, or tells of the forward
// that does.
func (f *forwards) start(c *controlConn, p proto.PortForwardParams) (proto.PortForwarded, error) {
	var out proto.PortForwarded
	if p.Port < 1 || p.Port > 65535 {
		return out, fmt.Errorf("%d is not a port", p.Port)
	}
	if p.Local < 0 || p.Local > 65535 {
		return out, fmt.Errorf("%d is not a port", p.Local)
	}
	if p.Addr == "" {
		return out, errors.New("which host?")
	}
	h, err := f.join(p.Addr)
	if err != nil {
		return out, err
	}
	h.start.Lock()
	defer h.start.Unlock()
	if old := f.existing(p, c); old != nil {
		f.leave(h)
		if p.Local != 0 && p.Local != old.info.Local {
			return out, fmt.Errorf("port %d of %s is forwarded to localhost:%d already: stop that first", p.Port, old.info.Host, old.info.Local)
		}
		out.PortForward = old.info
		return out, nil
	}
	conn, err := f.connect(h)
	if err != nil {
		f.leave(h)
		return out, err
	}
	// A look at the port: a host of an older Kero fails here, with what to
	// do. One with nothing on the port yet is told of, and waited for.
	if probe, err := conn.DialPort(p.Port); err == nil {
		probe.Close()
	} else if errors.Is(err, remote.ErrPortRefused) {
		out.Refused = true
	} else {
		f.leave(h)
		return out, err
	}
	lns, local, err := listenLoopback(p.Local, p.Port)
	if err != nil {
		f.leave(h)
		return out, err
	}
	fw := &forward{
		info:  proto.PortForward{Host: p.Host, Addr: p.Addr, Port: p.Port, Local: local, Since: time.Now().UnixMilli()},
		host:  h,
		conn:  conn,
		lns:   lns,
		conns: map[net.Conn]struct{}{},
	}
	if fw.info.Host == "" {
		fw.info.Host = p.Addr
	}
	if !p.Keep {
		fw.owner = c
	}
	f.mu.Lock()
	// The connection may have ended meanwhile, or kerod be going, as the
	// app that asked may have gone: nothing would end this one then.
	gone := f.closed || h.conn != conn || fw.owner != nil && fw.owner.finished()
	if !gone {
		f.live = append(f.live, fw)
	}
	f.mu.Unlock()
	if gone {
		fw.close()
		f.leave(h)
		return out, fmt.Errorf("the connection to %s ended", fw.info.Host)
	}
	for _, ln := range lns {
		go fw.serve(ln)
	}
	f.logf("forwarding %s:%d to localhost:%d", fw.info.Host, p.Port, local)
	f.d.changed()
	out.PortForward = fw.info
	return out, nil
}

// existing is the forward of a host's port already there, which a CLI's
// asking keeps past the app that asked first.
func (f *forwards) existing(p proto.PortForwardParams, c *controlConn) *forward {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, fw := range f.live {
		if fw.info.Addr == p.Addr && fw.info.Port == p.Port {
			if p.Keep {
				fw.owner = nil
			}
			return fw
		}
	}
	return nil
}

// join counts one more user of a host.
func (f *forwards) join(addr string) (*fwdHost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil, errors.New("kerod is stopping")
	}
	h := f.hosts[addr]
	if h == nil {
		h = &fwdHost{addr: addr}
		f.hosts[addr] = h
	}
	h.users++
	return h, nil
}

// leave counts one less, letting go of the connection after the last.
func (f *forwards) leave(h *fwdHost) {
	f.mu.Lock()
	h.users--
	var conn tunnel
	if h.users == 0 {
		conn, h.conn = h.conn, nil
		delete(f.hosts, h.addr)
	}
	f.mu.Unlock()
	if conn != nil {
		go conn.Close() // ssh takes a moment to end
	}
}

// connect is the host's connection, opened as needed; h.start is held.
func (f *forwards) connect(h *fwdHost) (tunnel, error) {
	f.mu.Lock()
	conn := h.conn
	f.mu.Unlock()
	if conn != nil {
		return conn, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := f.dial(ctx, h.addr)
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	h.conn = conn
	f.mu.Unlock()
	go func() {
		<-conn.Done()
		f.lost(h, conn)
	}()
	return conn, nil
}

// lost ends the forwards of a connection that ended.
func (f *forwards) lost(h *fwdHost, conn tunnel) {
	f.mu.Lock()
	var gone []*forward
	f.live = slices.DeleteFunc(f.live, func(fw *forward) bool {
		if fw.conn == conn {
			gone = append(gone, fw)
			return true
		}
		return false
	})
	if h.conn == conn {
		h.conn = nil
	}
	f.mu.Unlock()
	f.finish(gone)
}

// ownerGone ends the forwards of a client that went, as the app.
func (f *forwards) ownerGone(c *controlConn) {
	if f == nil {
		return
	}
	f.mu.Lock()
	var gone []*forward
	f.live = slices.DeleteFunc(f.live, func(fw *forward) bool {
		if fw.owner == c {
			gone = append(gone, fw)
			return true
		}
		return false
	})
	f.mu.Unlock()
	f.finish(gone)
}

// stop ends the forwards of a port.
func (f *forwards) stop(p proto.PortStopParams) ([]proto.PortForward, error) {
	f.mu.Lock()
	var gone []*forward
	for _, fw := range f.live {
		if stopMatches(fw.info, p) {
			gone = append(gone, fw)
		}
	}
	// Named by a port alone, which may be of several hosts, only one.
	if p.Addr == "" && len(gone) > 1 {
		var names []string
		for _, fw := range gone {
			names = append(names, fw.info.Host+":"+strconv.Itoa(fw.info.Port))
		}
		f.mu.Unlock()
		return nil, fmt.Errorf("port %d is forwarded from %s: say which with -H", p.Port, strings.Join(names, ", "))
	}
	f.live = slices.DeleteFunc(f.live, func(fw *forward) bool { return slices.Contains(gone, fw) })
	f.mu.Unlock()
	if len(gone) == 0 {
		return nil, fmt.Errorf("port %d is not forwarded", p.Port)
	}
	out := make([]proto.PortForward, len(gone))
	for i, fw := range gone {
		out[i] = fw.info
	}
	f.finish(gone)
	return out, nil
}

func stopMatches(fw proto.PortForward, p proto.PortStopParams) bool {
	if p.Addr != "" {
		return fw.Addr == p.Addr && fw.Port == p.Port
	}
	return fw.Port == p.Port || fw.Local == p.Port
}

// finish closes forwards taken off the list, and says so.
func (f *forwards) finish(gone []*forward) {
	for _, fw := range gone {
		fw.close()
		f.leave(fw.host)
		f.logf("no longer forwarding %s:%d to localhost:%d", fw.info.Host, fw.info.Port, fw.info.Local)
	}
	if len(gone) > 0 {
		f.d.changed()
	}
}

// close ends everything, as kerod does.
func (f *forwards) close() {
	if f == nil {
		return
	}
	f.mu.Lock()
	f.closed = true
	gone := f.live
	f.live = nil
	f.mu.Unlock()
	f.finish(gone)
}

func (f *forwards) logf(format string, args ...any) {
	if f.d != nil && f.d.log != nil {
		f.d.log.Printf(format, args...)
	}
}

// serve takes a listener's connections through the tunnel.
func (fw *forward) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		if !fw.track(c) {
			c.Close()
			return
		}
		go func() {
			defer fw.untrack(c)
			defer c.Close()
			st, err := fw.conn.DialPort(fw.info.Port)
			if err != nil {
				return
			}
			pipe(c, st)
		}()
	}
}

func (fw *forward) track(c net.Conn) bool {
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if fw.conns == nil {
		return false
	}
	fw.conns[c] = struct{}{}
	return true
}

func (fw *forward) untrack(c net.Conn) {
	fw.mu.Lock()
	defer fw.mu.Unlock()
	delete(fw.conns, c)
}

// close stops listening, and ends the connections it took.
func (fw *forward) close() {
	for _, ln := range fw.lns {
		ln.Close()
	}
	fw.mu.Lock()
	conns := fw.conns
	fw.conns = nil
	fw.mu.Unlock()
	for c := range conns {
		c.Close()
	}
}

// finished tells that the client went.
func (c *controlConn) finished() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

// listenLoopback listens on this machine's loopback, IPv4's and IPv6's, for
// a port of a host: on want, or with none wanted on that port should it be
// free, else on one near it, else on any the system gives. It reports the
// port.
func listenLoopback(want, port int) ([]net.Listener, int, error) {
	if want != 0 {
		lns, got, err := listenBoth(want)
		if err != nil {
			return nil, 0, fmt.Errorf("port %d is taken on this machine", want)
		}
		return lns, got, nil
	}
	for try := port; try <= min(port+20, 65535); try++ {
		if lns, got, err := listenBoth(try); err == nil {
			return lns, got, nil
		}
	}
	return listenBoth(0)
}

// listenBoth listens on a port of both loopbacks, 0 for any. A port that
// answers on either, or on every address, which the system may let this
// narrower listener share, is taken: the page there would no longer be the
// one the user knows.
func listenBoth(port int) ([]net.Listener, int, error) {
	if port != 0 && portAnswers(port) {
		return nil, 0, fmt.Errorf("port %d is taken", port)
	}
	v4, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return nil, 0, err
	}
	got := v4.Addr().(*net.TCPAddr).Port
	v6, err := net.Listen("tcp6", net.JoinHostPort("::1", strconv.Itoa(got)))
	if err != nil {
		// A machine with no IPv6 loopback has only the one; on another,
		// the port is taken there.
		if probe, err := net.Listen("tcp6", "[::1]:0"); err == nil {
			probe.Close()
			v4.Close()
			return nil, 0, fmt.Errorf("port %d is taken", got)
		}
		return []net.Listener{v4}, got, nil
	}
	return []net.Listener{v4, v6}, got, nil
}

// portAnswers tells that something listens on a port of the loopback.
func portAnswers(port int) bool {
	for _, ip := range []string{"127.0.0.1", "::1"} {
		c, err := net.DialTimeout("tcp", net.JoinHostPort(ip, strconv.Itoa(port)), 200*time.Millisecond)
		if err == nil {
			c.Close()
			return true
		}
	}
	return false
}
