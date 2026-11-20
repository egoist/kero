package daemon

import (
	"encoding/json"
	"io"
	"log"
	"net"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

func testDaemon(t *testing.T) *Daemon {
	t.Helper()
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	d := &Daemon{dir: t.TempDir(), log: log.New(io.Discard, "", 0), panes: map[string]*pane{},
		subs: map[*controlConn]struct{}{}, watchers: map[*controlConn]struct{}{},
		changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1)}
	d.viewed.Store(new(string))
	d.projects = []proto.Project{{ID: "pr", Name: "repo", Dir: t.TempDir()}}
	return d
}

// A browser pane runs no shell: it keeps its page, as the app tells it,
// which a restore brings back, and the terminal's calls leave it be.
func TestBrowserPane(t *testing.T) {
	d := testDaemon(t)
	s, err := d.create(proto.CreateParams{URL: "localhost:3000"})
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Panes) != 1 || s.Panes[0].URL != "http://localhost:3000" {
		t.Fatalf("panes %+v", s.Panes)
	}
	p := d.findPane(s.Panes[0].ID)
	if p.term != nil || p.proc != nil {
		t.Fatal("a browser pane has a terminal")
	}
	// What a terminal's pane takes, a browser's ignores.
	p.resize(80, 24, 8, 16)
	p.clear(proto.ClearScreen)
	if p.tick(time.Now()) {
		t.Error("a browser pane ticked a change")
	}
	if _, _, _, ok := p.attach(newAttachment(nil)); ok {
		t.Error("attached to a browser pane")
	}
	if p.restart() == nil {
		t.Error("restarted a browser pane")
	}
	if h := p.history(true); h != nil {
		t.Error("a browser pane has a history")
	}

	if err := p.setPage("http://localhost:3000/docs", "Docs"); err != nil {
		t.Fatal(err)
	}
	if got := p.readText(false, 0); got != "Docs\nhttp://localhost:3000/docs\n" {
		t.Errorf("read %q", got)
	}
	d.saveState()

	r := testDaemon(t)
	r.dir = d.dir
	r.restore()
	if len(r.sessions) != 1 || len(r.sessions[0].panes) != 1 {
		t.Fatalf("restored %d sessions", len(r.sessions))
	}
	info := r.sessions[0].panes[0].info
	if info.URL != "http://localhost:3000/docs" || info.Title != "Docs" || !info.Restored {
		t.Errorf("restored %+v", info)
	}
	if err := r.removeSession(r.sessions[0].id); err != nil {
		t.Fatal(err)
	}

	// A terminal's pane has no page to set.
	tp := testPane(t)
	if tp.setPage("https://kero.sh", "") == nil {
		t.Error("set a terminal's page")
	}
}

// A browser call goes to the apps, which have the page, and comes back
// with the first of them that answers with a result: one that hasn't the
// pane, or is not let, refuses.
func TestBrowse(t *testing.T) {
	d := testDaemon(t)
	s, err := d.create(proto.CreateParams{URL: "localhost:3000"})
	if err != nil {
		t.Fatal(err)
	}
	defer d.removeSession(s.ID)
	id := s.Panes[0].ID
	cli := &controlConn{done: make(chan struct{})}
	call := func(method string, params any) (any, error) {
		raw, _ := json.Marshal(params)
		return d.call(cli, method, raw)
	}
	if _, err := call("browser", proto.BrowserParams{ID: id, Op: "text"}); err == nil || !strings.Contains(err.Error(), "not open") {
		t.Fatalf("with no app: %v", err)
	}

	apps := []*controlConn{
		{out: make(chan proto.Message, 4), done: make(chan struct{})},
		{out: make(chan proto.Message, 4), done: make(chan struct{})},
	}
	d.subs = map[*controlConn]struct{}{apps[0]: {}, apps[1]: {}}
	// ask calls the pane's browser, and has each app answer as given.
	ask := func(answers ...proto.BrowserAnswer) (*proto.BrowserResult, error) {
		type result struct {
			res any
			err error
		}
		done := make(chan result, 1)
		go func() {
			res, err := call("browser", proto.BrowserParams{ID: s.ID, Op: "text", Selector: "h1", Timeout: 50})
			done <- result{res, err}
		}()
		for i, app := range apps {
			m := <-app.out
			r := m.Browser
			if m.Event != "browser" || r == nil || r.Pane != id || r.Op != "text" || r.Selector != "h1" || r.Timeout != 50 {
				t.Fatalf("app %d was asked %+v", i, m)
			}
			answers[i].Req = r.Req
			if _, err := call("browser.answer", answers[i]); err != nil {
				t.Fatal(err)
			}
		}
		r := <-done
		res, _ := r.res.(*proto.BrowserResult)
		return res, r.err
	}
	res, err := ask(proto.BrowserAnswer{Error: "no pane " + id}, proto.BrowserAnswer{Result: &proto.BrowserResult{Text: "Hello"}})
	if err != nil || res.Text != "Hello" {
		t.Errorf("answered %+v, %v", res, err)
	}
	_, err = ask(proto.BrowserAnswer{Error: "Remote Control is off"}, proto.BrowserAnswer{Error: "no pane " + id})
	if err == nil || err.Error() != "Remote Control is off" {
		t.Errorf("refused with %v", err)
	}
	if len(d.asks) != 0 {
		t.Errorf("%d asks left", len(d.asks))
	}
	// An answer to nothing asked is no error: the call may have ended.
	if ok, err := call("browser.answer", proto.BrowserAnswer{Req: 99}); err != nil || ok != false {
		t.Errorf("answered nothing: %v, %v", ok, err)
	}

	// The caller gone, the call ends.
	done := make(chan error, 1)
	go func() {
		_, err := call("browser", proto.BrowserParams{ID: id, Op: "reload"})
		done <- err
	}()
	<-apps[0].out
	<-apps[1].out
	close(cli.done)
	if err := <-done; err == nil || err.Error() != "canceled" {
		t.Errorf("canceled with %v", err)
	}

	// A terminal has no page.
	if _, err := d.browse(cli, testPane(t), proto.BrowserParams{Op: "text"}); err == nil || !strings.Contains(err.Error(), "not a browser") {
		t.Errorf("a terminal's page: %v", err)
	}
}

// Asked to show a session, the apps hear of it first: a session just made
// is in no state they had, as the state of a burst of changes goes out
// once it settles. The browser of a pane of one would never show.
func TestSelectSendsStateFirst(t *testing.T) {
	d := testDaemon(t)
	app := &controlConn{out: make(chan proto.Message, 4), done: make(chan struct{})}
	d.subs = map[*controlConn]struct{}{app: {}}
	s, err := d.create(proto.CreateParams{URL: "localhost:3000"})
	if err != nil {
		t.Fatal(err)
	}
	defer d.removeSession(s.ID)
	raw, _ := json.Marshal(proto.FocusParams{Session: s.ID})
	if _, err := d.call(&controlConn{done: make(chan struct{})}, "select", raw); err != nil {
		t.Fatal(err)
	}
	next := func() proto.Message {
		select {
		case m := <-app.out:
			return m
		case <-time.After(time.Second):
			t.Fatal("no event")
			return proto.Message{}
		}
	}
	first, second := next(), next()
	if first.Event != "state" || first.State == nil || len(first.State.Sessions) != 1 || first.State.Sessions[0].ID != s.ID {
		t.Fatalf("first %+v", first)
	}
	if second.Event != "select" || second.Select != s.ID {
		t.Fatalf("then %+v", second)
	}
}

// A watcher, as kero events, hears of the state and the notices, in
// order, but is no app: it has no page to answer for, nor actions to run.
func TestWatch(t *testing.T) {
	d := testDaemon(t)
	w := &controlConn{out: make(chan proto.Message, 8), done: make(chan struct{})}
	if ok, err := d.call(w, "watch", nil); err != nil || ok != true {
		t.Fatalf("watch: %v, %v", ok, err)
	}
	next := func() proto.Message {
		select {
		case m := <-w.out:
			return m
		case <-time.After(time.Second):
			t.Fatal("no event")
			return proto.Message{}
		}
	}
	if m := next(); m.Event != "state" || m.State == nil || len(m.State.Sessions) != 0 {
		t.Fatalf("first %+v", m)
	}

	go d.broadcastLoop()
	defer close(d.changeCh)
	s, err := d.create(proto.CreateParams{URL: "localhost:3000"})
	if err != nil {
		t.Fatal(err)
	}
	defer d.removeSession(s.ID)
	if m := next(); m.Event != "state" || m.State == nil || len(m.State.Sessions) != 1 {
		t.Fatalf("after create %+v", m)
	}
	d.notice(proto.Notice{Session: s.ID, Body: "done"})
	if m := next(); m.Event != "notice" || m.Notice == nil || m.Notice.Body != "done" {
		t.Fatalf("notice %+v", m)
	}

	cli := &controlConn{done: make(chan struct{})}
	call := func(method string, params any) (any, error) {
		raw, _ := json.Marshal(params)
		return d.call(cli, method, raw)
	}
	if ok, err := call("do", proto.DoParams{Action: "sidebar.toggle"}); err != nil || ok != false {
		t.Errorf("do with a watcher alone: %v, %v", ok, err)
	}
	if ok, err := call("select", proto.FocusParams{Session: s.ID}); err != nil || ok != false {
		t.Errorf("select with a watcher alone: %v, %v", ok, err)
	}
	if _, err := call("browser", proto.BrowserParams{ID: s.ID, Op: "text"}); err == nil || !strings.Contains(err.Error(), "not open") {
		t.Errorf("browser with a watcher alone: %v", err)
	}
	for {
		select {
		case m := <-w.out:
			if m.Event != "state" {
				t.Errorf("a watcher got %+v", m)
			}
			continue
		case <-time.After(100 * time.Millisecond):
		}
		break
	}
}

// A watcher far behind is cut off, not left to miss what it tells
// changes from.
func TestWatcherBehind(t *testing.T) {
	ours, theirs := net.Pipe()
	defer theirs.Close()
	w := &controlConn{conn: ours, out: make(chan proto.Message, 1), done: make(chan struct{})}
	w.watchEvent(proto.Message{Event: "state"})
	w.watchEvent(proto.Message{Event: "notice"})
	if _, err := ours.Write([]byte{0}); err == nil {
		t.Fatal("a watcher behind is still connected")
	}
}

// A pane dragged onto another session lands beside the pane it was dropped
// on. The session it left goes when it was the last pane, and the program
// keeps running.
func TestPlacePane(t *testing.T) {
	d := testDaemon(t)
	home, err := d.create(proto.CreateParams{URL: "http://home.example", Name: "alpha"})
	if err != nil {
		t.Fatal(err)
	}
	guest, err := d.create(proto.CreateParams{URL: "http://guest.example", Name: "beta"})
	if err != nil {
		t.Fatal(err)
	}
	d.mu.Lock()
	d.findSessionLocked(home.ID).zoomed = home.Focus
	d.findSessionLocked(guest.ID).worktree = &proto.Worktree{Path: "/tmp/beta", Branch: "beta"}
	d.mu.Unlock()

	got, err := d.place(proto.PlaceParams{Pane: guest.Panes[0].ID, Into: home.ID, Target: home.Panes[0].ID, Side: "right"})
	if err != nil {
		t.Fatal(err)
	}
	if len(d.sessions) != 1 || got.Into.ID != home.ID || got.From.ID != "" || got.Into.Name != "alpha" {
		t.Fatalf("into %+v from %q, %d sessions", got.Into.ID, got.From.ID, len(d.sessions))
	}
	if got.Into.Zoomed != "" || got.Into.Focus != home.Panes[0].ID {
		t.Fatalf("zoom %q focus %q", got.Into.Zoomed, got.Into.Focus)
	}
	if got.Into.Worktree == nil || got.Into.Worktree.Path != "/tmp/beta" {
		t.Fatalf("worktree %+v", got.Into.Worktree)
	}
	if !slices.Equal(got.Into.Former, []string{guest.ID}) {
		t.Fatalf("former %v", got.Into.Former)
	}
	l := got.Into.Layout
	if l == nil || !l.Row || l.Ratio != 0.5 || l.A.Pane != home.Panes[0].ID || l.B.Pane != guest.Panes[0].ID {
		t.Fatalf("layout %+v", l)
	}
	d.mu.Lock()
	if p := d.panes[guest.Panes[0].ID]; p == nil || p.sid != home.ID {
		t.Fatalf("pane moved: %+v", p)
	}
	if s := d.findSessionLocked(guest.ID); s == nil || s.id != home.ID {
		t.Fatal("the old id names nothing")
	}
	d.mu.Unlock()

	if _, err := d.place(proto.PlaceParams{Pane: "missing", Into: home.ID, Target: home.Panes[0].ID, Side: "right"}); err == nil {
		t.Fatal("placed a pane that is not there")
	}
	if _, err := d.place(proto.PlaceParams{Pane: home.Panes[0].ID, Into: home.ID, Target: guest.Panes[0].ID, Side: "left"}); err == nil {
		t.Fatal("placed a pane into its own session")
	}

	d.saveState()
	r := testDaemon(t)
	r.dir = d.dir
	r.restore()
	if len(r.sessions) != 1 || !slices.Contains(r.sessions[0].former, guest.ID) {
		t.Fatalf("restored former %v", r.sessions[0].former)
	}
}

// One pane of a split leaves; the session keeps the other. The session
// that stays keeps its own name and worktree. Swapping exchanges the two
// panes' places.
func TestPlaceKeepsWhatStays(t *testing.T) {
	d := testDaemon(t)
	home, err := d.create(proto.CreateParams{URL: "http://home.example", Name: "home"})
	if err != nil {
		t.Fatal(err)
	}
	home, err = d.split(proto.CreateParams{Split: home.ID, URL: "http://home2.example", Direction: "down"})
	if err != nil {
		t.Fatal(err)
	}
	guest, err := d.create(proto.CreateParams{URL: "http://guest.example"})
	if err != nil {
		t.Fatal(err)
	}
	d.mu.Lock()
	d.findSessionLocked(home.ID).worktree = &proto.Worktree{Path: "/tmp/home", Branch: "home"}
	d.mu.Unlock()

	moved := home.Panes[1].ID
	got, err := d.place(proto.PlaceParams{Pane: moved, Into: guest.ID, Target: guest.Panes[0].ID, Side: "down"})
	if err != nil {
		t.Fatal(err)
	}
	if got.From.ID != home.ID || len(got.From.Panes) != 1 || got.From.Panes[0].ID == moved {
		t.Fatalf("left behind %+v", got.From.Panes)
	}
	if got.Into.Name != "" || got.Into.Worktree != nil || got.Into.Focus != guest.Panes[0].ID {
		t.Fatalf("into name %q worktree %+v focus %q", got.Into.Name, got.Into.Worktree, got.Into.Focus)
	}
	if got.From.Worktree == nil || got.From.Worktree.Path != "/tmp/home" {
		t.Fatalf("worktree left %+v", got.From.Worktree)
	}

	// The session dropped on keeps its name. The one the pane left does
	// not come with it, even a name the user gave.
	named, err := d.create(proto.CreateParams{URL: "http://named.example", Name: "kero1"})
	if err != nil {
		t.Fatal(err)
	}
	plain, err := d.create(proto.CreateParams{URL: "http://plain.example", Name: "kero2"})
	if err != nil {
		t.Fatal(err)
	}
	got, err = d.place(proto.PlaceParams{Pane: named.Panes[0].ID, Into: plain.ID, Target: plain.Panes[0].ID, Side: "right"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Into.Name != "kero2" || got.Into.Focus != plain.Panes[0].ID {
		t.Fatalf("name %q focus %q", got.Into.Name, got.Into.Focus)
	}
}

// A pane dropped on the empty sidebar becomes a session of its own. The
// one it leaves keeps its name, and a pane that is already alone stays.
func TestExtractPane(t *testing.T) {
	d := testDaemon(t)
	s, err := d.create(proto.CreateParams{URL: "http://kept.example", Name: "kept"})
	if err != nil {
		t.Fatal(err)
	}
	s, err = d.split(proto.CreateParams{Split: s.ID, URL: "http://out.example", Direction: "right"})
	if err != nil {
		t.Fatal(err)
	}
	out := s.Panes[1].ID
	got, err := d.extract(out)
	if err != nil {
		t.Fatal(err)
	}
	if got.From.ID != s.ID || got.From.Name != "kept" || len(got.From.Panes) != 1 || got.From.Panes[0].ID == out {
		t.Fatalf("left behind %+v", got.From)
	}
	if got.Into.Name != "" || len(got.Into.Panes) != 1 || got.Into.Panes[0].ID != out || got.Into.Focus != out {
		t.Fatalf("extracted %+v", got.Into)
	}
	if len(d.sessions) != 2 || d.sessions[0].id != s.ID || d.sessions[1].id != got.Into.ID {
		t.Fatalf("order %v", []string{d.sessions[0].id, d.sessions[1].id})
	}
	if p := d.panes[out]; p == nil || p.sid != got.Into.ID {
		t.Fatalf("pane %+v", p)
	}
	if _, err := d.extract(out); err == nil {
		t.Fatal("extracted a pane that is already its own session")
	}

	// Swap exchanges the places and leaves both sessions.
	a, err := d.create(proto.CreateParams{URL: "http://a.example", Name: "a"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := d.create(proto.CreateParams{URL: "http://b.example", Name: "b"})
	if err != nil {
		t.Fatal(err)
	}
	got, err = d.place(proto.PlaceParams{Pane: a.Panes[0].ID, Into: b.ID, Target: b.Panes[0].ID, Side: "swap"})
	if err != nil {
		t.Fatal(err)
	}
	if got.From.ID != a.ID || got.Into.ID != b.ID {
		t.Fatalf("from %s into %s", got.From.ID, got.Into.ID)
	}
	if len(got.From.Panes) != 1 || got.From.Panes[0].URL != "http://b.example" {
		t.Fatalf("a kept %+v", got.From.Panes)
	}
	if len(got.Into.Panes) != 1 || got.Into.Panes[0].URL != "http://a.example" || got.Into.Focus != a.Panes[0].ID {
		t.Fatalf("b kept %+v focus %q", got.Into.Panes, got.Into.Focus)
	}
}
