package daemon

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
	"kero/internal/remote"
)

func TestParseProcNet(t *testing.T) {
	tcp := `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
   1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23456 1 0000000000000000 100 0 0 10 0
   2: 0100007F:C350 0100007F:0BB8 01 00000000:00000000 00:00000000 00000000  1000        0 34567 1 0000000000000000 20 0 0 10 -1
`
	got := parseProcNet([]byte(tcp))
	want := map[uint64]tcpListener{12345: {addr: "127.0.0.1", port: 3000}, 23456: {addr: "0.0.0.0", port: 8080}}
	if len(got) != len(want) || got[12345] != want[12345] || got[23456] != want[23456] {
		t.Errorf("tcp: %+v", got)
	}
	tcp6 := `  sl  local_address                         remote_address                        st
   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 777 1 0000000000000000 100 0 0 10 0
   1: 00000000000000000000000000000000:0050 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 778 1 0000000000000000 100 0 0 10 0
   2: 0000000000000000FFFF00000100007F:0BB9 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 779 1 0000000000000000 100 0 0 10 0
`
	got = parseProcNet([]byte(tcp6))
	if got[777] != (tcpListener{addr: "::1", port: 8080}) || got[778] != (tcpListener{addr: "::", port: 80}) || got[779] != (tcpListener{addr: "127.0.0.1", port: 3001}) {
		t.Errorf("tcp6: %+v", got)
	}
	if len(parseProcNet([]byte("garbage\n1 2 3\n0: zz:zz 0 0A 0 0 0 0 0 x\n"))) != 0 {
		t.Error("read a listener out of garbage")
	}
}

// socketInfo lays a socket_fdinfo out as macOS does, as far as it's read.
func socketInfo(kind, state uint32, vflag byte, port uint16, addr []byte) []byte {
	b := make([]byte, 792)
	binary.LittleEndian.PutUint32(b[sockKind:], kind)
	binary.LittleEndian.PutUint32(b[sockTCPState:], state)
	binary.BigEndian.PutUint16(b[sockInLPort:], port)
	b[sockInVFlag] = vflag
	copy(b[sockInLAddr:], addr)
	return b
}

func TestParseSocketInfo(t *testing.T) {
	v4 := append(make([]byte, 12), 127, 0, 0, 1)
	v6 := append(make([]byte, 15), 1)
	if a, p, ok := parseSocketInfo(socketInfo(sockKindTCP, sockStateLis, sockFlagIPv4, 3000, v4)); !ok || a != "127.0.0.1" || p != 3000 {
		t.Errorf("v4: %s %d %v", a, p, ok)
	}
	if a, p, ok := parseSocketInfo(socketInfo(sockKindTCP, sockStateLis, sockFlagIPv6, 8080, v6)); !ok || a != "::1" || p != 8080 {
		t.Errorf("v6: %s %d %v", a, p, ok)
	}
	// IPv4 and IPv6 both, for a socket on ::: every address.
	if a, _, ok := parseSocketInfo(socketInfo(sockKindTCP, sockStateLis, sockFlagIPv4|sockFlagIPv6, 80, nil)); !ok || a != "::" {
		t.Errorf("dual: %s %v", a, ok)
	}
	if _, _, ok := parseSocketInfo(socketInfo(sockKindTCP, 4, sockFlagIPv4, 3000, v4)); ok {
		t.Error("an established socket counts as listening")
	}
	if _, _, ok := parseSocketInfo(socketInfo(1, sockStateLis, sockFlagIPv4, 3000, v4)); ok {
		t.Error("a socket of another kind counts as TCP")
	}
	if _, _, ok := parseSocketInfo(make([]byte, 10)); ok {
		t.Error("read a listener out of too few bytes")
	}
}

func TestParseTCPTables(t *testing.T) {
	v4 := make([]byte, 4+24)
	binary.LittleEndian.PutUint32(v4, 1)
	copy(v4[4+4:], []byte{127, 0, 0, 1})
	binary.BigEndian.PutUint16(v4[4+8:], 3000)
	binary.LittleEndian.PutUint32(v4[4+20:], 4242)
	if got := parseTCPTable(v4); len(got) != 1 || got[0] != (tcpListener{addr: "127.0.0.1", port: 3000, pid: 4242}) {
		t.Errorf("v4: %+v", got)
	}
	v6 := make([]byte, 4+56)
	binary.LittleEndian.PutUint32(v6, 1)
	v6[4+15] = 1
	binary.BigEndian.PutUint16(v6[4+20:], 8080)
	binary.LittleEndian.PutUint32(v6[4+52:], 7)
	if got := parseTCP6Table(v6); len(got) != 1 || got[0] != (tcpListener{addr: "::1", port: 8080, pid: 7}) {
		t.Errorf("v6: %+v", got)
	}
	// A count past what was written stops at the end.
	binary.LittleEndian.PutUint32(v4, 9)
	if got := parseTCPTable(v4); len(got) != 1 {
		t.Errorf("short table: %+v", got)
	}
}

func TestPaneOfProcess(t *testing.T) {
	// 100 is a pane's shell: 300's parent's parent. 400 left its shell, as
	// a daemon does; 500's chain ends with no pane.
	parents := map[int]int{300: 200, 200: 100, 100: 50, 50: 1, 400: 1, 500: 60, 60: 1}
	parent := func(pid int) int { return parents[pid] }
	shells := map[int]paneRef{100: {"pane", "session"}}
	if r, ok := paneOfProcess(300, shells, parent); !ok || r != (paneRef{"pane", "session"}) {
		t.Errorf("descendant: %+v %v", r, ok)
	}
	if r, ok := paneOfProcess(100, shells, parent); !ok || r.pane != "pane" {
		t.Errorf("the shell itself: %+v %v", r, ok)
	}
	for _, pid := range []int{400, 500, 1, 0, 12345} {
		if r, ok := paneOfProcess(pid, shells, parent); ok {
			t.Errorf("%d is of a pane: %+v", pid, r)
		}
	}
	// A loop of parents ends.
	if _, ok := paneOfProcess(7, shells, func(int) int { return 7 }); ok {
		t.Error("a loop found a pane")
	}
}

func TestMergePorts(t *testing.T) {
	parents := map[int]int{10: 1, 20: 5, 21: 5, 30: 1}
	parent := func(pid int) int { return parents[pid] }
	shells := map[int]paneRef{5: {"pane", "session"}}
	bundled := func(pid int) bool { return pid == 30 }
	got := mergePorts([]tcpListener{
		{addr: "::1", port: 3000, pid: 10, name: "other"},
		{addr: "127.0.0.1", port: 3000, pid: 20, name: "node"}, // a pane's, over the first
		{addr: "127.0.0.1", port: 3000, pid: 21, name: "node"},
		{addr: "0.0.0.0", port: 8080},                          // no one the user may see
		{addr: "127.0.0.1", port: 5000, pid: 30, name: "App"},  // an app's
		{addr: "127.0.0.1", port: 55555, pid: 10, name: "ide"}, // on a random port
		{addr: "127.0.0.1", port: 56000, pid: 20, name: "node"},
		{addr: "127.0.0.1", port: 7373, pid: 99, name: "kero"}, // kerod's own
		{addr: "100.1.2.3", port: 9000, pid: 10, name: "vpn"},  // on no loopback
		{addr: "0.0.0.0", port: 22},                            // root's, unknown
		{addr: "127.0.0.1", port: 6000, pid: 10, name: "sshd"}, // of the system by name
	}, shells, parent, bundled, 99)
	want := []proto.Port{
		{Port: 22, Addrs: []string{"0.0.0.0"}, System: true},
		{Port: 3000, Addrs: []string{"127.0.0.1", "::1"}, PID: 20, Process: "node", Pane: "pane", Session: "session"},
		{Port: 5000, Addrs: []string{"127.0.0.1"}, PID: 30, Process: "App", System: true},
		{Port: 6000, Addrs: []string{"127.0.0.1"}, PID: 10, Process: "sshd", System: true},
		{Port: 7373, Addrs: []string{"127.0.0.1"}, PID: 99, Process: "kero", System: true},
		{Port: 8080, Addrs: []string{"0.0.0.0"}},
		{Port: 9000, Addrs: []string{"100.1.2.3"}, PID: 10, Process: "vpn", System: true},
		{Port: 55555, Addrs: []string{"127.0.0.1"}, PID: 10, Process: "ide", System: true},
		// A pane's is the user's, on whatever port.
		{Port: 56000, Addrs: []string{"127.0.0.1"}, PID: 20, Process: "node", Pane: "pane", Session: "session"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range got {
		if fmt.Sprint(got[i]) != fmt.Sprint(want[i]) {
			t.Errorf("port %d:\n got %+v\nwant %+v", want[i].Port, got[i], want[i])
		}
	}
}

// This machine's list has a port listening, and tells a pane's process by
// its shell, here this test's own process.
func TestPortListOfThisMachine(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	d := testDaemon(t)
	s, err := d.create(proto.CreateParams{URL: "localhost:1"})
	if err != nil {
		t.Fatal(err)
	}
	pn := d.findPane(s.Panes[0].ID)
	pn.mu.Lock()
	pn.shellPID = pidSelf()
	pn.mu.Unlock()
	portsCache.Lock()
	portsCache.at = time.Time{}
	portsCache.Unlock()
	list, err := d.portList()
	if err != nil {
		t.Fatal(err)
	}
	i := slices.IndexFunc(list.Ports, func(p proto.Port) bool { return p.Port == port })
	if i < 0 {
		t.Fatalf("port %d not in %+v", port, list.Ports)
	}
	if p := list.Ports[i]; p.Pane != pn.info.ID || p.Session != s.ID || p.System || p.PID != pidSelf() || !slices.Contains(p.Addrs, "127.0.0.1") {
		t.Errorf("port: %+v", p)
	}
}

// Only the loopback, whatever asks: this is what keeps kerod from being a
// proxy to the machines it reaches.
func TestDialRefusesOtherThanLoopback(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for _, addr := range []string{"192.0.2.1:80", "10.0.0.1:22", "8.8.8.8:53", "[2001:db8::1]:80", "169.254.169.254:80", "0.0.0.0:80"} {
		_, err := loopbackDialer.DialContext(ctx, "tcp", addr)
		if err == nil || !strings.Contains(err.Error(), "refused: ") {
			t.Errorf("%s: %v", addr, err)
		}
	}
	for _, port := range []int{0, -1, 65536} {
		if _, err := dialLoopback(ctx, port); err == nil {
			t.Errorf("port %d: no error", port)
		}
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer ln.Close()
	c, err := dialLoopback(ctx, ln.Addr().(*net.TCPAddr).Port)
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
}

// A stream's Hello has no way to name another address, and what it adds of
// its own is read as nothing: it reaches the loopback's port.
func TestServePortNamesOnlyAPort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	got := make(chan string, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		got <- c.RemoteAddr().(*net.TCPAddr).IP.String()
	}()
	d := portDaemon(t)
	client, server := net.Pipe()
	defer client.Close()
	go d.serve(server, identity{peer: "test", via: "unix"})
	fmt.Fprintf(client, `{"kind":"port","version":%d,"port":%d,"host":"192.0.2.1","addr":"192.0.2.1:%d","network":"tcp"}`+"\n", proto.Version, port, port)
	var w proto.Welcome
	if err := json.NewDecoder(client).Decode(&w); err != nil {
		t.Fatal(err)
	}
	if w.Error != "" || w.Port != port {
		t.Fatalf("welcome: %+v", w)
	}
	select {
	case ip := <-got:
		if ip != "127.0.0.1" {
			t.Errorf("came from %s", ip)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the port got no connection")
	}
}

// portDaemon is a kerod that takes connections.
func portDaemon(t *testing.T) *Daemon {
	t.Helper()
	d := testDaemon(t)
	d.clients = map[*proto.ClientInfo]struct{}{}
	d.quit = make(chan struct{})
	d.fwd = newForwards(d)
	return d
}

// muxHost is a host, as far as a forward sees: a daemon that answers remote
// connections, here over a pipe, as any transport does.
func muxHost(t *testing.T, d *Daemon) (*remote.Conn, net.Conn) {
	t.Helper()
	clientEnd, serverEnd := net.Pipe()
	srv := &remote.Server{
		Info: func() proto.HostInfo { return proto.HostInfo{OS: "test", Version: proto.Version} },
		Stream: func(c net.Conn, hello []byte, mux proto.MuxHello) {
			d.serveHello(c, bufio.NewReader(c), hello, identity{peer: "test", via: "ssh"})
		},
		Log: log.New(io.Discard, "", 0),
	}
	go srv.Serve(serverEnd)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	rc, err := remote.Handshake(ctx, clientEnd)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { rc.Close() })
	return rc, clientEnd
}

// dialsTo connects to a host anew at each dial, as a real one does.
func dialsTo(t *testing.T, host *Daemon) func() (tunnel, error) {
	return func() (tunnel, error) {
		rc, _ := muxHost(t, host)
		return rc, nil
	}
}

// forwarder is the kerod holding a machine's forwards, conn its way to a host.
func forwarder(t *testing.T, conn func() (tunnel, error)) *forwards {
	t.Helper()
	d := portDaemon(t)
	f := newForwards(d)
	d.fwd = f
	f.dial = func(context.Context, string) (tunnel, error) { return conn() }
	t.Cleanup(f.close)
	return f
}

func testServer(t *testing.T, body string) (*httptest.Server, int) {
	t.Helper()
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, body) }))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	srv.Listener = ln
	srv.Start()
	t.Cleanup(srv.Close)
	return srv, ln.Addr().(*net.TCPAddr).Port
}

func fetch(t *testing.T, url string) string {
	t.Helper()
	cl := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	res, err := cl.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return string(b)
}

func owner() *controlConn { return &controlConn{done: make(chan struct{}), here: true} }

// freePort finds a port no one listens on, with one above it free too.
func freePort(t *testing.T) int {
	t.Helper()
	for range 50 {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Skip(err)
		}
		p := ln.Addr().(*net.TCPAddr).Port
		ln.Close()
		if p < 65000 && !portAnswers(p) && !portAnswers(p+1) {
			return p
		}
	}
	t.Skip("no free ports")
	return 0
}

func closes(t *testing.T, port int) {
	t.Helper()
	for range 100 {
		if !portAnswers(port) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Errorf("port %d still answers", port)
}

// A forward through a real mux to a real kerod's stream: what's fetched is
// the host's, on the loopback only, and it ends with stop, whose connections
// go too.
func TestForwardAndStop(t *testing.T) {
	_, port := testServer(t, "from the host")
	host := portDaemon(t)
	f := forwarder(t, dialsTo(t, host))
	local := freePort(t)
	res, err := f.start(owner(), proto.PortForwardParams{Host: "devbox", Addr: "devbox", Port: port, Local: local})
	if err != nil {
		t.Fatal(err)
	}
	if res.Local != local || res.Port != port || res.Host != "devbox" || res.Refused {
		t.Fatalf("forward: %+v", res)
	}
	if got := fetch(t, res.URL()); got != "from the host" {
		t.Errorf("fetched %q", got)
	}
	for _, ln := range f.live[0].lns {
		if ip := ln.Addr().(*net.TCPAddr).IP; !ip.IsLoopback() {
			t.Errorf("listens on %s", ip)
		}
	}
	if !f.active() || len(f.list()) != 1 {
		t.Errorf("forwards: %+v", f.list())
	}
	// A connection open as it stops ends.
	open, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(local)))
	if err != nil {
		t.Fatal(err)
	}
	defer open.Close()
	if _, err := f.stop(proto.PortStopParams{Addr: "devbox", Port: port}); err != nil {
		t.Fatal(err)
	}
	closes(t, local)
	open.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := open.Read(make([]byte, 1)); errors.Is(err, nil) || isTimeout(err) {
		t.Errorf("the open connection goes on: %v", err)
	}
	if f.active() || len(f.list()) != 0 {
		t.Errorf("forwards after stop: %+v", f.list())
	}
	if _, err := f.stop(proto.PortStopParams{Addr: "devbox", Port: port}); err == nil {
		t.Error("stopped what isn't forwarded")
	}
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// Taken here: the same number when free, else one near it, saying which; a
// port asked for by name is never swapped for another, and what's on a port
// here is never shadowed.
func TestForwardLocalPortCollision(t *testing.T) {
	_, port := testServer(t, "from the host")
	f := forwarder(t, dialsTo(t, portDaemon(t)))
	// The test server's own port is taken on this machine, the same one.
	res, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port})
	if err != nil {
		t.Fatal(err)
	}
	if res.Local == port {
		t.Fatalf("took port %d that answers here", port)
	}
	if got := fetch(t, res.URL()); got != "from the host" {
		t.Errorf("fetched %q", got)
	}
	if _, err := f.stop(proto.PortStopParams{Addr: "devbox", Port: port}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port, Local: port}); err == nil || !strings.Contains(err.Error(), "taken") {
		t.Errorf("asked for a taken port: %v", err)
	}
	// What listens on the IPv6 loopback alone takes the port too, or
	// localhost would go to either.
	v6, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skip("no IPv6 loopback")
	}
	defer v6.Close()
	if lns, _, err := listenBoth(v6.Addr().(*net.TCPAddr).Port); err == nil {
		for _, ln := range lns {
			ln.Close()
		}
		t.Error("shadowed a port of the IPv6 loopback")
	}
}

// The same port twice is the same forward; another local port for it says so.
func TestForwardTwice(t *testing.T) {
	_, port := testServer(t, "x")
	f := forwarder(t, dialsTo(t, portDaemon(t)))
	a, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port})
	if err != nil {
		t.Fatal(err)
	}
	b, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port})
	if err != nil || b.Local != a.Local || len(f.list()) != 1 {
		t.Errorf("twice: %+v %v, %+v", b, err, f.list())
	}
	if _, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port, Local: a.Local + 1}); err == nil {
		t.Error("forwarded one port to two")
	}
}

// The forwards end as what they depend on goes: the app that asked, unless
// the CLI asked too; the connection to the host; kerod.
func TestForwardTeardown(t *testing.T) {
	_, port := testServer(t, "x")
	_, port2 := testServer(t, "y")
	host := portDaemon(t)

	t.Run("owner", func(t *testing.T) {
		f := forwarder(t, dialsTo(t, host))
		app := owner()
		a, err := f.start(app, proto.PortForwardParams{Addr: "devbox", Port: port})
		if err != nil {
			t.Fatal(err)
		}
		kept, err := f.start(app, proto.PortForwardParams{Addr: "devbox", Port: port2, Keep: true})
		if err != nil {
			t.Fatal(err)
		}
		f.ownerGone(app)
		closes(t, a.Local)
		if got := fetch(t, kept.URL()); got != "y" {
			t.Errorf("the CLI's forward: %q", got)
		}
		if l := f.list(); len(l) != 1 || l[0].Port != port2 {
			t.Errorf("forwards: %+v", l)
		}
		// Asked for by the CLI after the app, it's the CLI's.
		other := owner()
		b, err := f.start(other, proto.PortForwardParams{Addr: "devbox", Port: port})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port, Keep: true}); err != nil {
			t.Fatal(err)
		}
		f.ownerGone(other)
		if got := fetch(t, b.URL()); got != "x" {
			t.Errorf("kept: %q", got)
		}
	})

	t.Run("connection", func(t *testing.T) {
		rc, pipe := muxHost(t, host)
		f := forwarder(t, func() (tunnel, error) { return rc, nil })
		a, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port, Keep: true})
		if err != nil {
			t.Fatal(err)
		}
		// The link drops, as ssh's does.
		pipe.Close()
		closes(t, a.Local)
		for range 100 {
			if !f.active() {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if f.active() {
			t.Errorf("forwards after the link: %+v", f.list())
		}
		// And nothing brings it back by itself.
		time.Sleep(50 * time.Millisecond)
		if portAnswers(a.Local) {
			t.Error("the forward came back")
		}
	})

	t.Run("kerod", func(t *testing.T) {
		f := forwarder(t, dialsTo(t, host))
		a, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port, Keep: true})
		if err != nil {
			t.Fatal(err)
		}
		f.close()
		closes(t, a.Local)
		if _, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port}); err == nil {
			t.Error("started a forward after the end")
		}
	})

	t.Run("last closes the connection", func(t *testing.T) {
		rc, _ := muxHost(t, host)
		f := forwarder(t, func() (tunnel, error) { return rc, nil })
		if _, err := f.start(owner(), proto.PortForwardParams{Addr: "devbox", Port: port}); err != nil {
			t.Fatal(err)
		}
		if _, err := f.stop(proto.PortStopParams{Addr: "devbox", Port: port}); err != nil {
			t.Fatal(err)
		}
		select {
		case <-rc.Done():
		case <-time.After(3 * time.Second):
			t.Error("the connection stays with no forward")
		}
	})
}

func TestForwardErrors(t *testing.T) {
	host := portDaemon(t)
	f := forwarder(t, dialsTo(t, host))
	for _, p := range []proto.PortForwardParams{{Addr: "x", Port: 0}, {Addr: "x", Port: 70000}, {Addr: "x", Port: 80, Local: 70000}, {Port: 80}} {
		if _, err := f.start(owner(), p); err == nil {
			t.Errorf("%+v: no error", p)
		}
	}
	// Nothing on the port yet: told, and waited for.
	free := freePort(t)
	res, err := f.start(owner(), proto.PortForwardParams{Addr: "x", Port: free})
	if err != nil || !res.Refused {
		t.Errorf("no listener: %+v %v", res, err)
	}
	// A host that can't be reached fails, and leaves nothing behind.
	g := forwarder(t, func() (tunnel, error) { return nil, errors.New("no route") })
	if _, err := g.start(owner(), proto.PortForwardParams{Addr: "x", Port: 80}); err == nil || !strings.Contains(err.Error(), "no route") {
		t.Errorf("unreachable: %v", err)
	}
	if len(g.hosts) != 0 || g.active() {
		t.Errorf("left %+v", g.hosts)
	}
	// By a port alone: of several hosts, not a guess.
	_, port := testServer(t, "x")
	h := forwarder(t, dialsTo(t, host))

	if _, err := h.start(owner(), proto.PortForwardParams{Addr: "a", Host: "a", Port: port}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.start(owner(), proto.PortForwardParams{Addr: "b", Host: "b", Port: port}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.stop(proto.PortStopParams{Port: port}); err == nil || !strings.Contains(err.Error(), "-H") {
		t.Errorf("ambiguous stop: %v", err)
	}
	if _, err := h.stop(proto.PortStopParams{Addr: "a", Port: port}); err != nil {
		t.Error(err)
	}
	if _, err := h.stop(proto.PortStopParams{Port: port}); err != nil {
		t.Errorf("now one: %v", err)
	}
}

// A client on another machine, through a bridge or a listener, starts no
// forward: its localhost is not this machine's, and the machine it runs on
// holds them.
func TestForwardsAreOfThisMachine(t *testing.T) {
	d := portDaemon(t)
	d.fwd = newForwards(d)
	c := &controlConn{done: make(chan struct{})}
	for method, params := range map[string]string{"ports.forward": `{"addr":"x","port":80}`, "ports.stop": `{"port":80}`} {
		if _, err := d.call(c, method, json.RawMessage(params)); !errors.Is(err, errForwardsHere) {
			t.Errorf("%s: %v", method, err)
		}
	}
	// Listing is any client's: it's what the Ports tab shows of a host.
	if _, err := d.call(c, "ports.list", nil); err != nil {
		t.Errorf("ports.list: %v", err)
	}
}

// Only what Kero's own socket takes counts as here: a bridge says it is one,
// and a listener's connection is its own.
func TestHereIsTheSocket(t *testing.T) {
	d := portDaemon(t)
	for _, c := range []struct {
		via  string
		here bool
	}{{"unix", true}, {"tailnet", false}, {"tailnet-serve", false}} {
		client, server := net.Pipe()
		go d.serve(server, identity{peer: "p", via: c.via})
		fmt.Fprintf(client, `{"kind":"control","version":%d}`+"\n", proto.Version)
		dec := json.NewDecoder(client)
		var w proto.Welcome
		if err := dec.Decode(&w); err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(client, `{"id":1,"method":"ports.stop","params":{"port":1}}`+"\n")
		var m proto.Message
		if err := dec.Decode(&m); err != nil {
			t.Fatal(err)
		}
		if got := m.Error != errForwardsHere.Error(); got != c.here {
			t.Errorf("%s: %q", c.via, m.Error)
		}
		client.Close()
	}
	// A bridge's stream, on the socket, says it comes from elsewhere.
	client, server := net.Pipe()
	defer client.Close()
	go d.serve(server, identity{peer: "p", via: "unix"})
	fmt.Fprintf(client, `{"kind":"control","version":%d,"via":"ssh","peer":"me"}`+"\n", proto.Version)
	dec := json.NewDecoder(client)
	var w proto.Welcome
	if err := dec.Decode(&w); err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(client, `{"id":1,"method":"ports.stop","params":{"port":1}}`+"\n")
	var m proto.Message
	if err := dec.Decode(&m); err != nil {
		t.Fatal(err)
	}
	if m.Error != errForwardsHere.Error() {
		t.Errorf("bridged: %q", m.Error)
	}
}

// A kerod that knows no ports takes the Hello for a control connection's:
// the client tells, rather than sending a page's bytes as methods.
func TestPortOfOlderKerod(t *testing.T) {
	clientEnd, serverEnd := net.Pipe()
	srv := &remote.Server{
		Info: func() proto.HostInfo { return proto.HostInfo{OS: "test", Version: proto.Version} },
		Stream: func(c net.Conn, hello []byte, mux proto.MuxHello) {
			defer c.Close()
			json.NewEncoder(c).Encode(proto.Welcome{Version: proto.Version, PID: 1})
		},
	}
	go srv.Serve(serverEnd)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	rc, err := remote.Handshake(ctx, clientEnd)
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	if _, err := rc.DialPort(3000); !errors.Is(err, remote.ErrNoPorts) {
		t.Errorf("older kerod: %v", err)
	}
}

// What was read with the answer stays: a server may speak first.
func TestPortServerSpeaksFirst(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.WriteString(c, "SSH-2.0-hello\r\n")
		io.Copy(io.Discard, c)
	}()
	rc, _ := muxHost(t, portDaemon(t))
	c, err := rc.DialPort(ln.Addr().(*net.TCPAddr).Port)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || line != "SSH-2.0-hello\r\n" {
		t.Errorf("%q %v", line, err)
	}
}

func pidSelf() int { return os.Getpid() }
