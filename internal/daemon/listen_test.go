package daemon

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	keroclient "kero/internal/client"
	"kero/internal/proto"
	"kero/internal/remote"
)

// fakeTailscale answers the local API as tailscaled does: alice owns the
// machine, and whois tells who connects.
type fakeTailscale struct {
	mu  sync.Mutex
	who string // the login connecting; "" for a tagged device
}

func (f *fakeTailscale) serve(t *testing.T) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "tailscaled.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skipf("no Unix sockets: %v", err)
	}
	t.Setenv("KERO_TAILSCALED_SOCKET", sock)
	mux := http.NewServeMux()
	mux.HandleFunc("/localapi/v0/status", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"BackendState":"Running","Self":{"DNSName":"box.tail.ts.net.","TailscaleIPs":["127.0.0.1"],"UserID":1},"User":{"1":{"LoginName":"alice@example.com"}}}`)
	})
	mux.HandleFunc("/localapi/v0/whois", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		who := f.who
		f.mu.Unlock()
		if who == "" {
			io.WriteString(w, `{"Node":{"Name":"runner.tail.ts.net.","Tags":["tag:ci"]},"UserProfile":{"LoginName":"tagged-devices"}}`)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"Node": map[string]any{"Name": "laptop."}, "UserProfile": map[string]any{"LoginName": who}})
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
}

func (f *fakeTailscale) set(who string) {
	f.mu.Lock()
	f.who = who
	f.mu.Unlock()
}

func listenDaemon(t *testing.T) *Daemon {
	d := &Daemon{
		log: log.New(io.Discard, "", 0), started: time.Now(),
		subs: map[*controlConn]struct{}{}, clients: map[*proto.ClientInfo]struct{}{}, panes: map[string]*pane{},
		changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1), quit: make(chan struct{}),
		projects: []proto.Project{{ID: "p1", Name: "demo"}},
	}
	empty := ""
	d.viewed.Store(&empty)
	t.Cleanup(d.stop)
	return d
}

// kerod's tailnet listener lets in the machine's owner, and those
// listen-allow names, once Tailscale tells who connects, and Kero alone:
// no browser's request reaches it.
func TestTailnetListener(t *testing.T) {
	ts := &fakeTailscale{who: "alice@example.com"}
	ts.serve(t)
	d := listenDaemon(t)
	// The test connects from loopback, as no peer of a tailnet does.
	l := &listeners{d: d, allow: []string{"tag:ci"}, isLocal: func(netip.Addr) bool { return false }}
	srv := httptest.NewServer(l.handler(context.Background(), "tailnet"))
	defer srv.Close()
	host, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	addr := remote.Addr{Scheme: "http", Host: host, Port: port}

	get := func(header http.Header) int {
		req, _ := http.NewRequest("GET", srv.URL+remote.MuxPath, nil)
		req.Header = header
		req.Header.Set("Connection", "Upgrade")
		req.Header.Set("Upgrade", "websocket")
		req.Header.Set("Sec-WebSocket-Version", "13")
		req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := get(http.Header{"Origin": {"http://evil.example"}, remote.ClientHeader: {"x"}}); code != http.StatusForbidden {
		t.Errorf("a browser's request: %d", code)
	}
	if code := get(http.Header{}); code != http.StatusForbidden {
		t.Errorf("a request not Kero's: %d", code)
	}

	dial := func() (*remote.Conn, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return remote.Dial(ctx, addr, remote.Options{App: "test", Client: "the test"})
	}
	// From this machine itself, as another user's process could, whom
	// tailscaled would take for the owner.
	local := httptest.NewServer((&listeners{d: d}).handler(context.Background(), "tailnet"))
	defer local.Close()
	_, lport, _ := net.SplitHostPort(strings.TrimPrefix(local.URL, "http://"))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	if _, err := remote.Dial(ctx, remote.Addr{Scheme: "http", Host: host, Port: lport}, remote.Options{}); err == nil || !strings.Contains(err.Error(), "this machine itself") {
		t.Errorf("a connection from this machine: %v", err)
	}
	cancel()

	ts.set("mallory@example.com")
	if _, err := dial(); err == nil || !strings.Contains(err.Error(), "mallory@example.com may not connect") {
		t.Errorf("someone else connected: %v", err)
	}
	ts.set("")
	forget := func() { l.mu.Lock(); l.whoCache = nil; l.mu.Unlock() }
	forget()
	if rc, err := dial(); err != nil {
		t.Errorf("a device listen-allow lets in: %v", err)
	} else {
		rc.Close()
	}

	ts.set("alice@example.com")
	forget()
	rc, err := dial()
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	if rc.Welcome.Host.Peer != "alice@example.com" || rc.Welcome.Host.Version != proto.Version {
		t.Errorf("welcome %+v", rc.Welcome)
	}
	c, err := keroclient.ConnectVia(rc)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var st proto.State
	if err := c.Call("state", nil, &st); err != nil || len(st.Projects) != 1 {
		t.Errorf("state %+v, %v", st, err)
	}
	var clients []proto.ClientInfo
	if err := c.Call("clients", nil, &clients); err != nil {
		t.Fatal(err)
	}
	if len(clients) != 1 || clients[0].Peer != "alice@example.com" || clients[0].Via != "tailnet" || clients[0].Client != "the test" {
		t.Errorf("clients %+v", clients)
	}
	// A stream that says it comes through a bridge is still the
	// listener's.
	s, err := rc.Dial()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(proto.Hello{Kind: "control", Version: proto.Version, Peer: "root", Via: "ssh"})
	s.Write(append(b, '\n'))
	s.Read(make([]byte, 512))
	c.Call("clients", nil, &clients)
	for _, ci := range clients {
		if ci.Peer == "root" || ci.Via == "ssh" {
			t.Errorf("a remote client passed for %s over %s", ci.Peer, ci.Via)
		}
	}
	s.Close()
}

// Tailscale Serve tells who connects in its headers, which only it, and
// the socket's user, can send; Funnel's requests, of the internet, never
// get in.
func TestServeListener(t *testing.T) {
	ts := &fakeTailscale{who: "alice@example.com"}
	ts.serve(t)
	l := &listeners{d: listenDaemon(t)}
	h := l.handler(context.Background(), "tailnet-serve")
	for _, c := range []struct {
		header http.Header
		ok     bool
	}{
		{http.Header{"Tailscale-User-Login": {"alice@example.com"}}, true},
		{http.Header{"Tailscale-User-Login": {"bob@example.com"}}, false},
		{http.Header{}, false},
		{http.Header{"Tailscale-User-Login": {"alice@example.com"}, "Tailscale-Funnel-Request": {"?1"}}, false},
	} {
		req := httptest.NewRequest("GET", remote.MuxPath, nil)
		for k, v := range c.header {
			req.Header[k] = v
		}
		req.Header.Set(remote.ClientHeader, "test")
		who, err := l.identify(req, "tailnet-serve")
		if (err == nil) != c.ok {
			t.Errorf("%v: %v, %v", c.header, who, err)
		}
		if !c.ok {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusForbidden {
				t.Errorf("%v: %d", c.header, rec.Code)
			}
		}
	}
}

// The listeners follow the configuration: one turned on listens, and one
// turned off listens no more; a Tailscale Serve socket waits for the next
// kerod.
func TestListenersSet(t *testing.T) {
	(&fakeTailscale{}).serve(t)
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := probe.Addr().String()
	_, port, _ := net.SplitHostPort(addr)
	probe.Close()

	l := &listeners{d: listenDaemon(t), on: map[string]*listener{}}
	defer l.close()
	dials := func() bool {
		c, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			c.Close()
		}
		return err == nil
	}
	waitFor := func(want bool) {
		t.Helper()
		for end := time.Now().Add(5 * time.Second); dials() != want; {
			if time.Now().After(end) {
				t.Fatalf("listening on %s: want %v", addr, want)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}

	sock := filepath.Join(t.TempDir(), "serve.sock")
	l.set([]string{"tailnet://:" + port, "tailnet-serve://" + sock}, []string{"tag:ci"}, false)
	waitFor(true)
	if !l.active() || !slices.Equal(l.allow, []string{"tag:ci"}) {
		t.Fatalf("active %v, allow %v", l.active(), l.allow)
	}
	if _, err := os.Stat(sock); err == nil {
		t.Fatal("a Tailscale Serve socket started after kerod did")
	}
	l.set(nil, nil, false)
	waitFor(false)
	if l.active() {
		t.Fatal("still active with no listeners")
	}
}
