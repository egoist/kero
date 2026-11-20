package main

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	if !a.openImagePane("a", file) || len(a.viewerPending) != 0 {
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
		if !a.openImagePane("b", link) || !a.viewerPending[key] || len(a.viewerPending) != 1 {
			t.Fatalf("duplicate %q changed pending splits: %v", link, a.viewerPending)
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
	if !a.openImagePane("a", file) || a.focus[s.ID] != "viewer" || len(a.viewerPending) != 0 {
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
	e := &webEntry{id: "a", app: a, nav: 1, url: u, viewerURL: u, viewerReady: true}
	a.webs[e.id] = e
	a.st.Sessions = append(a.st.Sessions, proto.Session{ID: "s2", Panes: []proto.Pane{{ID: "other", URL: u}}})
	const first = `kero-zoom:1:1:{"enabled":true,"zoom":2,"panX":0.2,"panY":-0.4}`
	if a.imageViewerTitle(e, "https://example.org/", first) || len(a.viewerGroups) != 0 {
		t.Fatal("ordinary web title was intercepted")
	}
	if !a.imageViewerTitle(e, u, first) || a.viewerGroup("s1").zoom != (viewerZoomState{true, 2, 0.2, -0.4}) || a.viewerGroups["s2"] != nil {
		t.Fatalf("groups = %+v", a.viewerGroups)
	}
	for _, title := range []string{`kero-zoom:1:1:{"enabled":true,"zoom":9}`, `kero-zoom:2:2:{"enabled":true,"zoom":9}`} {
		if !a.imageViewerTitle(e, u, title) || a.viewerGroup("s1").zoom.Zoom != 2 {
			t.Fatal("duplicate/stale title changed zoom")
		}
	}
	a.imageViewerTitle(e, u, `kero-zoom:1:2:{"enabled":false,"zoom":2}`)
	a.imageViewerTitle(e, u, `kero-zoom:1:3:{"enabled":false,"zoom":9}`)
	if st := a.viewerGroup("s1").zoom; st.Enabled || st.Zoom != 2 {
		t.Fatalf("independent zoom recorded: %+v", st)
	}
	e.load(u)
	if e.viewerReady || e.viewerSeq != 0 || e.viewerURL != "" {
		t.Fatal("new navigation retained old document state")
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
	a.viewerGroup(s.ID).zoom.Enabled = true
	for _, order := range [][]int{{1, 2, 0}, {2, 0, 1}, {0, 1, 2}} {
		a.navigateViewer(s, from, "next")
		assertURLs(order...)
	}
	a.navigateViewer(s, from, "prev")
	assertURLs(2, 0, 1)
}

func TestReadImageHostMismatch(t *testing.T) {
	for _, hosts := range [][2]string{{"", "remote"}, {"remote", ""}, {"remote", "other"}} {
		if _, _, _, _, _, err := readImage(imageViewerURL(hosts[0], "/tmp/shot.png", ""), hosts[1], nil); err == nil || !strings.Contains(err.Error(), "differs") {
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
	data, name, w, h, mime, err := readImage(imageViewerURL("", path, ""), "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, want) || name != "图 shot.png" || w != 2 || h != 3 || mime != "image/png" {
		t.Fatalf("readImage = %d bytes, %q, %dx%d, %q", len(data), name, w, h, mime)
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
	data, name, w, height, mime, err := readImage(imageViewerURL(h.name, remotePath, "/home/me/api"), h.name, cl)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, want) || name != "图 shot.png" || w != 4 || height != 5 || mime != "image/png" {
		t.Fatalf("readImage = %d bytes, %q, %dx%d, %q", len(data), name, w, height, mime)
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
	if _, _, _, _, _, err := readImage(imageViewerURL("", path, ""), "", nil); err == nil {
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

func TestImageViewerHTML(t *testing.T) {
	page := imageViewerHTML(`x<svg onload=alert(1)>.png`, 2, 3, "image/png", []byte{1, 2}, 1)
	if strings.Contains(page, "<svg onload") || !strings.Contains(page, "x&lt;svg") {
		t.Error("filename was not escaped")
	}
	for _, want := range []string{"2 × 3", `id="fit"`, `id="actual"`, "data:image/png;base64,"} {
		if !strings.Contains(page, want) {
			t.Errorf("page lacks %q", want)
		}
	}
}
