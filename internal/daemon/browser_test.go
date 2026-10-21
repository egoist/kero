package daemon

import (
	"encoding/json"
	"io"
	"log"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

func testDaemon(t *testing.T) *Daemon {
	t.Helper()
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	d := &Daemon{dir: t.TempDir(), log: log.New(io.Discard, "", 0), panes: map[string]*pane{},
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
