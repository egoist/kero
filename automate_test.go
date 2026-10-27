package main

import (
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

// kero browser's calls are answered, always: with what the page did, or
// why the app can't, which kerod hands the caller.
func TestBrowseRefuses(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	s.Panes[1] = proto.Pane{ID: "b", URL: "http://localhost:3000", Status: proto.Idle, Progress: -1}
	ask := func(r proto.BrowserRequest) error {
		t.Helper()
		var got error
		answered := false
		a.browse(a.local(), &r, func(res *proto.BrowserResult, err error) { answered, got = true, err })
		if !answered {
			t.Fatalf("%+v: no answer", r)
		}
		return got
	}
	for _, tc := range []struct {
		r    proto.BrowserRequest
		want string
	}{
		{proto.BrowserRequest{Pane: "gone", BrowserParams: proto.BrowserParams{Op: "text"}}, "no pane gone"},
		{proto.BrowserRequest{Pane: "a", BrowserParams: proto.BrowserParams{Op: "text"}}, "not a browser"},
		// No window here, so no page; a pane never shown gets its own
		// entry as it is asked for, which would be its page.
		{proto.BrowserRequest{Pane: "b", BrowserParams: proto.BrowserParams{Op: "text"}}, "shows no pages"},
	} {
		if err := ask(tc.r); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%+v: %v, want %q", tc.r, err, tc.want)
		}
	}
	if a.webs["b"] == nil {
		t.Error("no page made for a pane never shown")
	}
	// Remote Control off, nothing the page does is let.
	a.set.RemoteControl = false
	if err := ask(proto.BrowserRequest{Pane: "b", BrowserParams: proto.BrowserParams{Op: "text"}}); err == nil || !strings.Contains(err.Error(), "Remote Control") {
		t.Errorf("with Remote Control off: %v", err)
	}
}

// The cookies are every page's: a host's programs neither read nor set
// them, though Remote Control lets them drive the host's browsers.
func TestCookiesStayHome(t *testing.T) {
	a := testApp(t)
	h := withHost(t, a, "devbox")
	h.cfg.RemoteControl = true
	s := a.sessionOfPane("rpa-devbox")
	s.Panes[0].URL = "http://localhost:3000"
	for _, op := range []string{"save", "load"} {
		var got error
		a.browse(h, &proto.BrowserRequest{Pane: "rpa-devbox", BrowserParams: proto.BrowserParams{Op: "cookies", Text: op}},
			func(_ *proto.BrowserResult, err error) { got = err })
		if got == nil || !strings.Contains(got.Error(), "cookies stay on this machine") {
			t.Errorf("%s from a host: %v", op, got)
		}
	}
}

// The page's load ends for every call waiting on it; the script those
// that wait on the page run carries what it does as JSON.
func TestLoadEnds(t *testing.T) {
	e := &webEntry{}
	one, two := e.nextLoad(), e.nextLoad()
	e.loadEnded(nil)
	if err := <-one; err != nil {
		t.Error(err)
	}
	if err := <-two; err != nil {
		t.Error(err)
	}
	if len(e.loads) != 0 {
		t.Error("waiters left")
	}
	// A selector's quotes can't break out of it.
	js := pageScript(proto.BrowserParams{Op: "click", Selector: `a[href="x"]`}, 2*time.Second)
	if !strings.HasSuffix(js, `)({"enter":false,"op":"click","ref":"","selector":"a[href=\"x\"]","text":"","timeout":2000})`) {
		t.Errorf("script ends %q", js[strings.LastIndex(js, ")("):])
	}
}
