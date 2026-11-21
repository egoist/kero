package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/i18n"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

func viewerPNG(t *testing.T, w, h int, c color.Color) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, c)
		}
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestImageViewerURL(t *testing.T) {
	raw := imageViewerURL("build", "/home/me/图 +%20 shot.png", "/home/me/api")
	host, path, base, ok := imageViewerQuery(raw)
	if !ok || host != "build" || path != "/home/me/图 +%20 shot.png" || base != "/home/me/api" {
		t.Fatalf("imageViewerQuery(%q) = %q, %q, %q, %v", raw, host, path, base, ok)
	}
	if strings.Contains(raw, " ") {
		t.Errorf("URL did not encode its path: %q", raw)
	}
}

func TestOpenImagePane(t *testing.T) {
	a := testApp(t)
	dir := t.TempDir()
	a.st.Sessions[0].Panes[0].Dir = dir
	file := filepath.Join(dir, "图 + shot.png")
	if err := os.WriteFile(file, []byte("image"), 0o600); err != nil {
		t.Fatal(err)
	}
	splits := make(chan proto.CreateParams, 4)
	cl, _ := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		var p proto.CreateParams
		if method != "split" {
			t.Errorf("unexpected method %q", method)
		}
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		splits <- p
		return proto.Session{}, nil
	})
	// The no-client failure is synchronous and the next click must retry.
	if !a.openImagePane("a", file) || len(a.images.pending) != 0 {
		t.Fatal("disconnected split kept a pending viewer")
	}
	a.local().cl = cl
	if !a.openImagePane("a", filepath.Base(file)) {
		t.Fatal("relative file did not open a viewer")
	}
	select {
	case got := <-splits:
		host, path, base, ok := imageViewerQuery(got.URL)
		if got.Split != "a" || got.Direction != "right" || !ok || host != "" || path != file || base != dir {
			t.Fatalf("split = %+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("no split")
	}
	key := [2]string{"s1", a.local().imageKey(imageViewerURL("", file, dir))}
	// An attempted split without a client clears the key. Its survival is a
	// deterministic assertion that even the synchronous split entry was skipped.
	a.local().cl = nil
	for _, link := range []string{file, (&url.URL{Scheme: "file", Path: file}).String()} {
		if !a.openImagePane("b", link) || !a.images.pending[key] || len(a.images.pending) != 1 {
			t.Fatalf("duplicate %q changed pending splits: %v", link, a.images.pending)
		}
	}
	a.st.Sessions = append(a.st.Sessions, proto.Session{ID: "s2", Panes: []proto.Pane{{ID: "c", Dir: dir}}})
	a.local().cl = cl
	if !a.openImagePane("c", file) {
		t.Fatal("second session failed to open its own viewer")
	}
	select {
	case got := <-splits:
		if got.Split != "c" {
			t.Fatalf("second split = %+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("no split in second session")
	}
	if a.openImagePane("a", filepath.Join(dir, "notes.txt")) {
		t.Fatal("non-image opened a viewer")
	}
}

func TestOpenImagePaneFocusesExisting(t *testing.T) {
	a := testApp(t)
	dir := t.TempDir()
	file := filepath.Join(dir, "shot.png")
	if err := os.WriteFile(file, []byte("image"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := &a.st.Sessions[0]
	s.Panes = append(s.Panes, proto.Pane{ID: "viewer", URL: imageViewerURL("", file, "/another-directory")})
	focused := make(chan struct{}, 1)
	cl, _ := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		switch method {
		case "focus":
			focused <- struct{}{}
		case "view": // selecting the session also records its visit
		default:
			t.Errorf("unexpected RPC on reuse: %q", method)
		}
		return nil, nil
	})
	a.local().cl = cl
	if !a.openImagePane("a", file) || a.focus[s.ID] != "viewer" || len(a.images.pending) != 0 {
		t.Fatal("existing pane was not reused")
	}
	select {
	case <-focused:
	case <-time.After(time.Second):
		t.Fatal("missing focus RPC")
	}
}

func TestImageViewerTitle(t *testing.T) {
	a := testApp(t)
	u := imageViewerURL("", "/image.png", "")
	e := &webEntry{id: "a", app: a, nav: 1, url: u, viewer: viewerDocument{url: u, ready: true}}
	a.webs[e.id] = e
	a.st.Sessions = append(a.st.Sessions, proto.Session{ID: "s2", Panes: []proto.Pane{{ID: "other", URL: u}}})
	const first = `kero-zoom:1:1:{"kind":"toggle","toggleSeq":1,"enabled":true,"mode":"custom","zoom":2,"panX":0.2,"panY":-0.4}`
	if a.imageViewerTitle(e, "https://example.org/", first) || len(a.images.groups) != 0 {
		t.Fatal("ordinary web title was intercepted")
	}
	if !a.imageViewerTitle(e, u, first) || a.images.group("s1").zoom != (viewerZoomState{Enabled: true, Mode: "custom", Zoom: 2, PanX: 0.2, PanY: -0.4}) || a.images.groups["s2"] != nil {
		t.Fatalf("groups = %+v", a.images.groups)
	}
	for _, title := range []string{`kero-zoom:1:1:{"kind":"toggle","toggleSeq":1,"enabled":true,"mode":"custom","zoom":9}`, `kero-zoom:2:2:{"kind":"toggle","toggleSeq":2,"enabled":true,"mode":"custom","zoom":9}`} {
		if !a.imageViewerTitle(e, u, title) || a.images.group("s1").zoom.Zoom != 2 {
			t.Fatal("duplicate/stale title changed zoom")
		}
	}
	a.imageViewerTitle(e, u, `kero-zoom:1:2:{"kind":"toggle","toggleSeq":2,"enabled":false,"mode":"custom","zoom":2}`)
	a.imageViewerTitle(e, u, `kero-zoom:1:3:{"kind":"move","enabled":true,"mode":"custom","zoom":9,"epoch":1,"toggleSeq":1}`)
	if st := a.images.group("s1").zoom; st.Enabled || st.Zoom != 2 {
		t.Fatalf("independent zoom recorded: %+v", st)
	}
	e.load(u)
	if e.viewer.ready || e.viewer.seq != 0 || e.viewer.url != "" {
		t.Fatal("new navigation retained old document state")
	}
}

func TestViewerZoomOrdering(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	s.Panes = nil
	pane := func(id string) *webEntry {
		u := imageViewerURL("", "/"+id+".png", "")
		s.Panes = append(s.Panes, proto.Pane{ID: id, URL: u})
		e := &webEntry{app: a, id: id, nav: 1, url: u, viewer: viewerDocument{url: u, ready: true,
			delivery: &viewerDelivery{pending: make(chan viewerZoomSnapshot, 1), cancel: func() {}}}}
		a.webs[id] = e
		return e
	}
	first, second, slow := pane("a"), pane("b"), pane("c")
	title := func(e *webEntry, seq int, payload string) {
		t.Helper()
		if !a.imageViewerTitle(e, e.url, fmt.Sprintf("kero-zoom:1:%d:%s", seq, payload)) {
			t.Fatal("trusted title not handled")
		}
	}
	// The enable title was coalesced into the first move.
	title(first, 2, `{"kind":"move","toggleSeq":1,"epoch":0,"enabled":true,"mode":"actual","zoom":3}`)
	// Interleaved moves from both panes. The source must replace any queued
	// competing edit with its own acknowledged revision.
	title(second, 1, `{"kind":"move","epoch":1,"enabled":true,"mode":"fit","zoom":1}`)
	title(first, 3, `{"kind":"move","toggleSeq":1,"epoch":0,"enabled":true,"mode":"custom","zoom":4}`)
	for _, e := range []*webEntry{first, second, slow} {
		select {
		case got := <-e.viewer.delivery.pending:
			if got.Revision != 3 || got.Epoch != 1 || got.Zoom != 4 || got.Mode != "custom" || !got.Enabled || got.Ack != e.viewer.seq {
				t.Fatalf("pane %s received %+v", e.id, got)
			}
		default:
			t.Fatalf("missing final update for %s", e.id)
		}
	}
	title(second, 2, `{"kind":"toggle","toggleSeq":2,"enabled":false,"mode":"custom","zoom":4}`)
	title(first, 4, `{"kind":"move","toggleSeq":1,"epoch":1,"enabled":true,"mode":"custom","zoom":8}`)
	g := a.images.group(s.ID)
	// A delayed move from a third pane still carries its never-seen enable.
	title(slow, 2, `{"kind":"move","toggleSeq":1,"epoch":0,"enabled":true,"mode":"custom","zoom":99}`)
	if got := <-slow.viewer.delivery.pending; got.Enabled || got.Revision != 4 || got.ToggleEpoch != 0 {
		t.Fatalf("a stale carried enable survived the peer's disable: %+v", got)
	}
	if got := <-first.viewer.delivery.pending; got.Enabled || got.Revision != 4 || got.Ack != 4 || got.ToggleEpoch != 1 {
		t.Fatalf("stale movement re-enabled group or missed its acknowledgement: %+v", got)
	}
	title(second, 3, `{"kind":"toggle","toggleSeq":3,"enabled":true,"mode":"actual","zoom":5}`)
	title(first, 5, `{"kind":"move","toggleSeq":1,"epoch":1,"enabled":true,"mode":"custom","zoom":9}`)
	if got := g.snapshot(0); got.Revision != 5 || got.Epoch != 5 || got.Mode != "actual" || got.Zoom != 5 {
		t.Fatalf("old movement crossed disable and re-enable: %+v", got)
	}
}

func TestViewerNavigationCarriesPendingView(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	u, next := imageViewerURL("", "/a.png", ""), imageViewerURL("", "/b.png", "")
	s.Panes = []proto.Pane{{ID: "a", URL: u}, {ID: "b", URL: next}}
	e := &webEntry{app: a, id: "a", nav: 7, url: u, viewer: viewerDocument{url: u, ready: true}}
	a.webs[e.id] = e
	const view = `{"kind":"move","toggleSeq":1,"epoch":0,"enabled":true,"mode":"custom","zoom":2,"panX":0.25}`
	// This one title replaced both an enable and the last wheel sample.
	a.imageViewerTitle(e, u, `kero-nav:7:3:{"direction":"next","viewSeq":2,"view":`+view+`}`)
	g := a.images.group(s.ID)
	if e.url != next || e.nav != 8 || !g.zoom.Enabled || g.zoom.Zoom != 2 || g.zoom.PanX != .25 || g.revision != 1 {
		t.Fatalf("navigation lost state: url=%s nav=%d state=%+v", e.url, e.nav, g.snapshot(0))
	}
	// A navigation carrying an already processed edit must not replay it.
	e.viewer = viewerDocument{url: next, ready: true, seq: 2}
	a.imageViewerTitle(e, next, `kero-nav:8:3:{"direction":"prev","viewSeq":2,"view":`+view+`}`)
	if e.url != u || g.revision != 1 {
		t.Fatalf("carried edit replayed: url=%s revision=%d", e.url, g.revision)
	}
}

func TestViewerDeliverySlowPaneAndCancellation(t *testing.T) {
	started := make(chan viewerZoomSnapshot, 2)
	release, stopped := make(chan struct{}), make(chan struct{})
	slow := newViewerDelivery(func(ctx context.Context, st viewerZoomSnapshot) {
		started <- st
		select {
		case <-release:
		case <-ctx.Done():
			close(stopped)
		}
	})
	t.Cleanup(slow.cancel)
	receive := func(ch <-chan viewerZoomSnapshot) viewerZoomSnapshot {
		t.Helper()
		select {
		case st := <-ch:
			return st
		case <-time.After(time.Second):
			t.Fatal("delivery timed out")
			return viewerZoomSnapshot{}
		}
	}
	slow.offer(viewerZoomSnapshot{Revision: 1})
	receive(started)
	for rev := uint64(2); rev <= 100; rev++ {
		slow.offer(viewerZoomSnapshot{Revision: rev})
	}
	fastResult := make(chan viewerZoomSnapshot, 1)
	fast := newViewerDelivery(func(_ context.Context, st viewerZoomSnapshot) { fastResult <- st })
	t.Cleanup(fast.cancel)
	fast.offer(viewerZoomSnapshot{Revision: 100})
	if got := receive(fastResult); got.Revision != 100 {
		t.Fatalf("independent pane received %+v", got)
	}
	release <- struct{}{}
	if got := receive(started); got.Revision != 100 {
		t.Fatalf("slow pane replayed intermediate state: %+v", got)
	}
	doc := viewerDocument{url: "old", delivery: slow}
	doc.navigated("new")
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("navigation left old evaluation running")
	}
}

func TestViewerDocumentNavigation(t *testing.T) {
	a := testApp(t)
	u := imageViewerURL("", "/shot.png", "")
	// The seeded document started loading while linked. An unlink that
	// arrives before finish must still be delivered to correct its seed.
	g := a.images.group("s1")
	g.revision, g.epoch = 4, 4
	d := &viewerDelivery{pending: make(chan viewerZoomSnapshot, 1), cancel: func() {}}
	e := &webEntry{id: "a", app: a, url: u, viewer: viewerDocument{url: u, delivery: d}}
	e.viewer.navigated(u)
	if !e.finishViewerLoad(u) || !e.viewer.ready {
		t.Fatal("the loaded image did not become ready")
	}
	select {
	case st := <-d.pending:
		if st.Enabled || st.Revision != 4 || st.Epoch != 4 || st.Ack != 0 {
			t.Fatalf("received stale load state: %+v", st)
		}
	default:
		t.Fatal("missing initial delivery after disable")
	}
	e.viewer.navigated("https://example.org/")
	if e.finishViewerLoad(u) || e.viewer.ready || e.viewer.url != "" {
		t.Fatal("leaving the image let an old load reclaim the browser pane")
	}
}

func TestNavigateViewer(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	urls := []string{imageViewerURL("", "/a.png", ""), imageViewerURL("", "/b.png", ""), imageViewerURL("", "/c.png", "")}
	s.Panes = []proto.Pane{{ID: "a", URL: urls[0]}, {ID: "b", URL: urls[1]}, {ID: "c", URL: urls[2]}}
	for _, p := range s.Panes {
		a.webs[p.ID] = &webEntry{id: p.ID, app: a, url: p.URL}
	}
	assertURLs := func(indices ...int) {
		t.Helper()
		for i, n := range indices {
			if got := a.webs[s.Panes[i].ID].url; got != urls[n] {
				t.Fatalf("pane %s = %s, want %s", s.Panes[i].ID, got, urls[n])
			}
		}
	}
	from := a.webs["a"]
	a.navigateViewer(s, from, "next")
	assertURLs(1, 1, 2)
	for i := range s.Panes {
		s.Panes[i].URL = a.webs[s.Panes[i].ID].url
	}
	a.navigateViewer(s, from, "prev")
	assertURLs(0, 1, 2)
	group := a.images.group(s.ID)
	zoom := viewerZoomState{Enabled: true, Zoom: 2.5, PanX: 0.3, PanY: -0.4}
	group.zoom = zoom
	for _, target := range []int{1, 2, 0} {
		a.navigateViewer(s, from, "next")
		assertURLs(target, 1, 2)
	}
	a.navigateViewer(s, from, "prev")
	assertURLs(2, 1, 2)

	from.viewer = viewerDocument{url: from.url, ready: true}
	nav := from.nav
	pick := fmt.Sprintf("kero-nav:%d:1:pick-1", nav)
	a.imageViewerTitle(from, from.url, fmt.Sprintf("kero-nav:%d:1:pick-1", nav-1))
	assertURLs(2, 1, 2)
	a.imageViewerTitle(from, from.url, pick)
	assertURLs(1, 1, 2)
	if !a.imageViewerTitle(from, urls[2], pick) {
		t.Fatal("departing document's title escaped to the ordinary page handler during load")
	}
	from.viewer = viewerDocument{url: from.url}
	if !from.finishViewerLoad(from.url) || group.zoom != zoom {
		t.Fatal("changing images lost the active group zoom")
	}
	a.imageViewerTitle(from, from.url, fmt.Sprintf("kero-nav:%d:2:next", nav))
	assertURLs(1, 1, 2)
	if a.webs["b"].nav != 0 || a.webs["c"].nav != 0 {
		t.Fatal("changing the source image reloaded a peer")
	}

	group.zoom.Enabled = false
	a.navigateViewer(s, from, "pick-0")
	assertURLs(0, 1, 2)
	for _, bad := range []string{"pick-", "pick--1", "pick-3", "pick-+1", "pick-1.5", "pick-abc", "pick-99999999999999999999999", "pick-0"} {
		nav := from.nav
		a.navigateViewer(s, from, bad)
		assertURLs(0, 1, 2)
		if from.nav != nav {
			t.Fatalf("%q reloaded the document", bad)
		}
	}
}

func TestViewerClonePane(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	u := imageViewerURL("", "/work/shot + %.png", "/work")
	// The daemon can still have the previous URL while the viewer shows u.
	s.Panes = []proto.Pane{{ID: "a", URL: imageViewerURL("", "old.png", "/work")}}
	e := &webEntry{id: "a", app: a, nav: 3, url: u, viewer: viewerDocument{url: u, ready: true}}
	a.webs[e.id] = e
	zoom := viewerZoomState{Enabled: true, Zoom: 3, PanX: -0.2, PanY: 0.4}
	a.images.group(s.ID).zoom = zoom

	// An immediate split failure must allow a fresh click on the same document.
	a.imageViewerTitle(e, u, "kero-nav:3:1:new-pane")
	if len(a.images.pendingClones) != 0 {
		t.Fatal("disconnected split blocked retry")
	}
	splits := make(chan proto.CreateParams, 2)
	cl, _ := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method != "split" {
			return nil, fmt.Errorf("unexpected method %q", method)
		}
		var p proto.CreateParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		splits <- p
		return proto.Session{}, nil
	})
	a.local().cl = cl
	const click = "kero-nav:3:2:new-pane"
	if a.imageViewerTitle(e, "https://example.org/", click) {
		t.Fatal("intercepted ordinary page title")
	}
	a.imageViewerTitle(e, imageViewerURL("", "/old.png", ""), click)
	a.imageViewerTitle(e, u, "kero-nav:2:2:new-pane")
	a.imageViewerTitle(e, u, "kero-nav:3:1:new-pane")
	e.viewer.ready = false
	a.imageViewerTitle(e, u, click)
	e.viewer.ready = true
	departed := *e
	a.imageViewerTitle(&departed, u, click)
	if len(a.images.pendingClones) != 0 || e.viewer.seq != 1 {
		t.Fatal("stale or untrusted clone event was accepted")
	}
	assertSplit := func(source string) {
		t.Helper()
		select {
		case p := <-splits:
			if p.Split != source || p.Direction != "right" || p.URL != u {
				t.Fatalf("clone split = %+v", p)
			}
		case <-time.After(time.Second):
			t.Fatalf("missing clone split beside %s", source)
		}
	}
	a.imageViewerTitle(e, u, click)
	assertSplit(e.id)
	// Without a client a second split would clear the in-flight marker.
	a.local().cl = nil
	a.imageViewerTitle(e, u, "kero-nav:3:3:new-pane")
	if !a.images.pendingClones[e.id] || e.viewer.seq != 3 || e.nav != 3 || e.url != u {
		t.Fatal("repeated clone request changed the source or started another split")
	}
	s.Panes = append(s.Panes, proto.Pane{ID: "b", URL: u})
	clone := &webEntry{id: "b", app: a, nav: 1, url: u, viewer: viewerDocument{url: u}}
	a.webs[clone.id] = clone
	if !clone.finishViewerLoad(u) || a.images.group(s.ID).zoom != zoom || len(a.images.group(s.ID).items) != 1 {
		t.Fatal("clone did not join the existing zoom group and gallery")
	}
	a.local().cl = cl
	a.imageViewerTitle(clone, u, "kero-nav:1:1:new-pane")
	assertSplit(clone.id)
}

func TestViewerGalleryMembership(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	first := imageViewerURL("", "shot.png", "/one")
	second := imageViewerURL("", "/two/shot.png", "")
	s.Panes = []proto.Pane{{ID: "a", URL: first}, {ID: "web", URL: "https://example.org"}, {ID: "alias", URL: imageViewerURL("", "/one/shot.png", "")}, {ID: "b", URL: second}}
	g := a.images.group(s.ID)
	a.pruneImageViewers()
	if len(g.items) != 2 || g.items[0].url != first || g.items[1].url != second {
		t.Fatalf("seeded gallery = %+v", g.items)
	}
	g.items[0].Thumbnail = "thumb"
	payload, err := json.Marshal(g.items[0])
	if err != nil || string(payload) != `{"name":"shot.png","path":"shot.png","thumbnail":"thumb"}` {
		t.Fatalf("first item = %s (%v)", payload, err)
	}
	version := g.version
	s.Panes = []proto.Pane{{ID: "b", URL: second}}
	a.pruneImageViewers()
	if g.version != version || len(g.items) != 2 {
		t.Fatalf("pane removal changed stable gallery: %+v", g)
	}
	third := imageViewerURL("", "/three.png", "")
	s.Panes = append([]proto.Pane{{ID: "c", URL: third}}, s.Panes...)
	a.pruneImageViewers()
	if len(g.items) != 3 || g.items[2].url != third || g.items[0].Thumbnail != "thumb" || g.version == version {
		t.Fatalf("expanded gallery = %+v", g)
	}
	s.Panes = nil
	a.pruneImageViewers()
	if a.images.groups[s.ID] != nil {
		t.Fatal("empty session retained its gallery")
	}
}

func TestViewerImageName(t *testing.T) {
	for _, tc := range []struct {
		path, want string
		windows    bool
	}{
		{`C:\photos\图 shot.png`, "图 shot.png", true},
		{`C:shot.png`, "shot.png", true},
		{`\\server\share/mixed\shot.png`, "shot.png", true},
		{`/photos/a\b.png`, `a\b.png`, false},
	} {
		if got := viewerImageName(tc.path, tc.windows); got != tc.want {
			t.Errorf("viewerImageName(%q, %v) = %q, want %q", tc.path, tc.windows, got, tc.want)
		}
	}
}

func TestViewerThumbnail(t *testing.T) {
	for _, tc := range []struct{ w, h, wantW, wantH int }{
		{512, 256, 128, 64}, {256, 512, 64, 128}, {2048, 1, 128, 1}, {3, 5, 3, 5},
	} {
		t.Run(fmt.Sprintf("%dx%d", tc.w, tc.h), func(t *testing.T) {
			t.Parallel() // independent panes can finish decoding together
			want := color.RGBA{R: 220, G: 40, B: 10, A: 255}
			bm, err := ui.DecodeBitmap(viewerPNG(t, tc.w, tc.h, want))
			if err != nil {
				t.Fatal(err)
			}
			thumb, ok := strings.CutPrefix(viewerThumbnail(bm), "data:image/png;base64,")
			if !ok {
				t.Fatal("missing thumbnail data URL")
			}
			img, err := png.Decode(base64.NewDecoder(base64.StdEncoding, strings.NewReader(thumb)))
			if err != nil {
				t.Fatal(err)
			}
			if bounds := img.Bounds(); bounds.Dx() != tc.wantW || bounds.Dy() != tc.wantH {
				t.Fatalf("thumbnail = %v, want %dx%d", bounds, tc.wantW, tc.wantH)
			}
			if got := color.RGBAModel.Convert(img.At(tc.wantW/2, tc.wantH/2)); got != want {
				t.Fatalf("center pixel = %v, want %v", got, want)
			}
		})
	}
}

func TestReadImageHostMismatch(t *testing.T) {
	for _, hosts := range [][2]string{{"", "remote"}, {"remote", ""}, {"remote", "other"}} {
		if _, err := readImage(imageViewerURL(hosts[0], "/tmp/shot.png", ""), previewSource{host: hosts[1]}, false); err == nil || !strings.Contains(err.Error(), "differs") {
			t.Fatalf("hosts %q: %v", hosts, err)
		}
	}
}

func TestReadImageLocal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "图 shot.png")
	want := viewerPNG(t, 2, 3, color.RGBA{R: 10, G: 20, B: 30, A: 255})
	if err := os.WriteFile(path, want, 0o600); err != nil {
		t.Fatal(err)
	}
	img, err := readImage(imageViewerURL("", path, ""), previewSource{}, (&host{}).windows())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(img.data, want) || img.name != "图 shot.png" || img.w != 2 || img.h != 3 || img.mime != "image/png" || img.thumbnail == "" {
		t.Fatalf("readImage = %d bytes, %q, %dx%d, %q", len(img.data), img.name, img.w, img.h, img.mime)
	}
}

func TestReadImageRemote(t *testing.T) {
	a := testApp(t)
	h := withHost(t, a, "build")
	remotePath := filepath.Join(t.TempDir(), "图 shot.png")
	if err := os.WriteFile(remotePath, []byte("local decoy"), 0o600); err != nil {
		t.Fatal(err)
	}
	want := viewerPNG(t, 4, 5, color.White)
	stats, reads := make(chan proto.FSStatParams, 1), make(chan proto.FSReadParams, 1)
	cl, _ := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		switch method {
		case "fs.stat":
			var p proto.FSStatParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			stats <- p
			return proto.FSStat{Path: p.Path, Exists: true, Size: int64(len(want))}, nil
		case "fs.read":
			var p proto.FSReadParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			reads <- p
			return proto.FSRead{Data: want}, nil
		default:
			t.Fatalf("unexpected method %q", method)
			return nil, nil
		}
	})
	h.cl = cl
	img, err := readImage(imageViewerURL(h.name, remotePath, "/home/me/api"), h.previewSource(), h.windows())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(img.data, want) || img.name != "图 shot.png" || img.w != 4 || img.h != 5 || img.mime != "image/png" || img.thumbnail == "" {
		t.Fatalf("readImage = %d bytes, %q, %dx%d, %q", len(img.data), img.name, img.w, img.h, img.mime)
	}
	if got := <-stats; got.Path != remotePath || got.Base != "/home/me/api" {
		t.Errorf("fs.stat = %+v", got)
	}
	if got := <-reads; got.Path != remotePath || got.Max != maxViewerBytes {
		t.Errorf("fs.read = %+v", got)
	}
}

func TestReadImageRejectsLargeFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.png")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(path, maxViewerBytes+1); err != nil {
		t.Fatal(err)
	}
	if _, err := readImage(imageViewerURL("", path, ""), previewSource{}, false); err == nil {
		t.Fatal("oversize image was accepted")
	}
}

func TestLoadImageEntryUnavailable(t *testing.T) {
	a := testApp(t)
	e := &webEntry{id: "a", app: a, nav: 1}
	a.webs["a"] = e
	if !a.loadImageEntry(e, imageViewerURL("", "/tmp/shot.png", "")) {
		t.Fatal("internal URL was not recognized")
	}
	if e.err == "" || e.loading {
		t.Fatalf("unavailable WebView did not fail cleanly: %+v", e)
	}
}

func TestImageViewerToolbarLanguage(t *testing.T) {
	for _, tc := range []struct{ tag, language, sync, previous, newPane string }{
		{"en-US", "en", "Sync zoom and pan", "Previous image", "Open current image in a new preview pane"},
		{"zh-Hans", "zh-Hans", "同步缩放和平移", "上一张图片", "在新预览窗格中打开当前图片"},
		{"ja", "ja", "表示倍率と表示位置を同期", "前の画像", "現在の画像を新しいプレビューペインで開く"},
		{"", "en", "Sync zoom and pan", "Previous image", "Open current image in a new preview pane"},
	} {
		t.Run(tc.tag, func(t *testing.T) {
			i18n.SetLocaleFunc(func() string { return tc.tag })
			t.Cleanup(func() { i18n.SetLocaleFunc(nil) })
			page := currentViewerAppearance().render(preparedViewerImage{name: "test.png", w: 2, h: 3, src: "data:image/png;base64,"}, 1)
			_, script, ok := strings.Cut(page, "window.__keroApplyLabels(")
			payload, _, _ := strings.Cut(script, ");")
			var labels viewerLabels
			if !ok || json.Unmarshal([]byte(payload), &labels) != nil || labels.Language != tc.language || labels.Sync != tc.sync || labels.Previous != tc.previous || labels.NewPane != tc.newPane {
				t.Fatalf("unexpected viewer labels for %q: %s", tc.tag, payload)
			}
		})
	}
}

func TestImageViewerHTML(t *testing.T) {
	page := currentViewerAppearance().render(preparedViewerImage{name: `x<svg onload=alert(1)>.png`, w: 2, h: 3, src: "data:image/png;base64,AQI="}, 1)
	if strings.Contains(page, "<svg onload") || !strings.Contains(page, "x&lt;svg") {
		t.Error("filename was not escaped")
	}
	for _, want := range []string{"2 × 3", `id="fit"`, `id="actual"`, `id="new-pane"`, `navigate('new-pane')`, "data:image/png;base64,"} {
		if !strings.Contains(page, want) {
			t.Errorf("page lacks %q", want)
		}
	}
}
