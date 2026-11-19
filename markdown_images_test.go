package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

func markdownPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 3))
	img.Set(1, 1, color.RGBA{R: 255, A: 255})
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestMarkdownImagesOnDocumentHost(t *testing.T) {
	data := markdownPNG(t)
	var calls atomic.Int32
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method != "fs.read" {
			return nil, fmt.Errorf("unexpected %s", method)
		}
		var p proto.FSReadParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		if p.Path != "C:/remote/repo/images/a b.png" || p.Max != maxMarkdownImageBytes+1 {
			return nil, fmt.Errorf("wrong read: %+v", p)
		}
		calls.Add(1)
		return proto.FSRead{Data: data}, nil
	})
	defer stop()
	m := newMarkdownImages("C:/remote/repo/docs/readme.md", cl, false)
	src, err := m.load("../images/a%20b.png")
	if err != nil {
		t.Fatal(err)
	}
	if w, h := ui.ImageSize(src); w != 4 || h != 3 {
		t.Fatalf("size %v x %v", w, h)
	}
	if calls.Load() != 1 {
		t.Fatal("did not read from document host")
	}
	if _, err := m.load("https://example.invalid/private.png"); err == nil ||
		!m.blocked.Load() || calls.Load() != 1 || m.failed.Load() {
		t.Fatal("network image did not require consent")
	}
}

func TestMarkdownImageDecodeLimits(t *testing.T) {
	reserve := func(int64) bool { return true }
	if _, err := decodeMarkdownImage(markdownPNG(t), reserve); err != nil {
		t.Fatal(err)
	}
	if _, err := decodeMarkdownImage(markdownPNG(t), func(int64) bool { return false }); err == nil {
		t.Fatal("ignored budget")
	}
	for _, data := range [][]byte{
		nil,
		[]byte("not an image"),
		bytes.Repeat([]byte{'x'}, maxMarkdownImageBytes+1),
		[]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="999999" height="999999"></svg>`),
	} {
		if _, err := decodeMarkdownImage(data, reserve); err == nil {
			t.Fatal("accepted invalid/oversized image")
		}
	}
	if _, err := decodeMarkdownImage([]byte(
		`<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">`+
			`<rect width="20" height="10" fill="red"/></svg>`,
	), reserve); err != nil {
		t.Fatal(err)
	}
}

func TestMarkdownHTTPImages(t *testing.T) {
	data := markdownPNG(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" ||
			r.Header.Get("Referer") != "" {
			t.Error("image request leaked credentials/referrer")
		}
		switch r.URL.Path {
		case "/image":
			w.Write(data)
		case "/large":
			w.Header().Set("Content-Length", fmt.Sprint(maxMarkdownImageBytes+1))
			w.WriteHeader(200)
		case "/redirect":
			http.Redirect(w, r, "http://127.0.0.1/private", http.StatusFound)
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	got, err := fetchMarkdownImage(srv.Client(), srv.URL+"/image")
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("fetch %v", err)
	}
	for _, url := range []string{
		srv.URL + "/large", srv.URL + "/missing",
		"file:///tmp/x", "http://name:secret@example.com/x",
	} {
		if _, err := fetchMarkdownImage(srv.Client(), url); err == nil {
			t.Errorf("accepted %q", url)
		}
	}
	if _, err := fetchMarkdownImage(markdownImageHTTPClient, srv.URL+"/image"); err == nil {
		t.Fatal("production client reached loopback")
	}
	for _, raw := range []string{
		"127.0.0.1", "::1", "10.1.2.3", "172.16.0.1", "192.168.1.1",
		"169.254.169.254", "100.100.100.100", "::ffff:127.0.0.1", "198.18.0.1",
		"fc00::1", "0.1.2.3", "64:ff9b:1::a00:1", "2002:7f00:1::1",
	} {
		if markdownPublicIP(netip.MustParseAddr(raw)) {
			t.Errorf("allowed private IP %s", raw)
		}
	}
	for _, raw := range []string{"1.1.1.1", "2606:4700:4700::1111"} {
		if !markdownPublicIP(netip.MustParseAddr(raw)) {
			t.Errorf("blocked public IP %s", raw)
		}
	}
}

func TestMarkdownImageLoaderReplacement(t *testing.T) {
	a := testApp(t)
	fv := &fileView{pane: "a", path: "/old/readme.md"}
	showFileText(fv, "[![Linked image](image.png)](next.md)\n")
	m := fv.previewer().(*markdownPreview)
	reads := make(chan string, 2)
	release := make(chan struct{})
	unblock := sync.OnceFunc(func() { close(release) })
	oldClient, stopOld := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		var p proto.FSReadParams
		if method != "fs.read" || json.Unmarshal(raw, &p) != nil {
			return nil, fmt.Errorf("unexpected image request: %s", method)
		}
		reads <- p.Path
		<-release
		return nil, fmt.Errorf("old host could not load the image")
	})
	defer stopOld()
	defer unblock()
	a.local().cl = oldClient
	tt := ui.NewTester(func(c *ui.Context) {
		ui.Column(c).Fill().Children(func() {
			fv.previewer().view(c, paletteFor(c), a, fv)
		})
	}, 480, 720)
	read := func(want string) {
		t.Helper()
		select {
		case got := <-reads:
			if got != want {
				t.Fatalf("read %q, want %q", got, want)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("image read did not start")
		}
	}
	loaded := func(images *markdownImages) ui.ImageSource {
		t.Helper()
		v, ok := images.linked.Load("image.png")
		if !ok {
			t.Fatal("missing linked image cache")
		}
		entry := v.(*markdownLinkedImage)
		select {
		case <-entry.done:
			return entry.source
		case <-time.After(3 * time.Second):
			t.Fatal("image read did not finish")
			return nil
		}
	}
	read("/old/image.png")
	oldImages := m.images
	data := markdownPNG(t)
	newClient, stopNew := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		var p proto.FSReadParams
		if method != "fs.read" || json.Unmarshal(raw, &p) != nil {
			return nil, fmt.Errorf("unexpected image request: %s", method)
		}
		reads <- p.Path
		return proto.FSRead{Data: data}, nil
	})
	defer stopNew()
	a.local().cl = newClient
	fv.path = "/new/readme.md"
	tt.Frame()
	read("/new/image.png")
	current := m.images
	if fv.previewer() != m || current == oldImages || current.client != newClient ||
		oldImages.client != oldClient || oldImages.base != "/old/readme.md" {
		t.Fatal("host/path change did not isolate image loaders")
	}
	if w, h := ui.ImageSize(loaded(current)); w != 4 || h != 3 {
		t.Fatalf("new image size: %v x %v", w, h)
	}
	unblock()
	if loaded(oldImages) != nil || !oldImages.failed.Load() {
		t.Fatal("old request did not finish in its original loader")
	}
	tt.Frame()
	if m.images != current || current.failed.Load() ||
		tt.HasText("Some images could not be loaded.") {
		t.Fatal("obsolete image failure leaked into the current preview")
	}
}

func TestMarkdownImageUI(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	fv := &fileView{
		pane: "a", path: "/repo/docs/readme.md", rel: "docs/readme.md",
		fetched: time.Now(),
	}
	showFileText(fv, "# Images\n\n"+
		"![Local image](diagram.svg)\n\n"+
		"[![Linked image](diagram.svg)](next.md#target)\n\n"+
		"![Network image](http://127.0.0.1:1/private.png)\n")
	fv.preview = true
	m := fv.previewer().(*markdownPreview)
	a.openView(s, sideFiles, fv)
	reads := make(chan string, 16)
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method != "fs.read" {
			return nil, fmt.Errorf("unexpected %s", method)
		}
		var p proto.FSReadParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		reads <- p.Path
		return proto.FSRead{Data: []byte(
			`<svg xmlns="http://www.w3.org/2000/svg" width="240" height="80">` +
				`<rect width="240" height="80" rx="12" fill="#54a0ff"/></svg>`,
		)}, nil
	})
	defer stop()
	a.local().cl = cl
	tt := ui.NewTester(func(c *ui.Context) {
		ui.Column(c).Fill().Children(func() {
			fv.previewer().view(c, paletteFor(c), a, fv)
		})
	}, 600, 700)
	wait := func(ready func() bool) {
		t.Helper()
		until := time.Now().Add(3 * time.Second)
		for !ready() && time.Now().Before(until) {
			time.Sleep(time.Millisecond)
			tt.Frame()
		}
		if !ready() {
			t.Fatalf("image UI did not settle: texts=%v blocked=%v failed=%v reads=%d",
				tt.Texts(), m.images.blocked.Load(),
				m.images.failed.Load(), len(reads))
		}
	}
	wait(func() bool {
		_, ok := tt.Find("Load network images")
		local, _ := tt.Find("Local image")
		linked, _ := tt.Find("Linked image")
		return ok && local.H >= 80 && linked.H >= 80
	})
	for i := 0; i < 2; i++ {
		select {
		case file := <-reads:
			if file != "/repo/docs/diagram.svg" {
				t.Fatalf("wrong host path %s", file)
			}
		case <-time.After(time.Second):
			t.Fatal("missing image read")
		}
	}
	oldOptions := m.options
	if err := tt.Click("Load network images"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	wait(func() bool { return tt.HasText("Some images could not be loaded.") })
	if !m.network || m.options == oldOptions {
		t.Fatal("network permission did not replace stale image cache")
	}
	if _, ok := tt.Find("Load network images"); ok {
		t.Fatal("permission button still shown after consent")
	}
	shot(t, tt, "markdown-images")
	if err := tt.Click("Linked image"); err != nil {
		t.Fatal(err)
	}
	if next := a.viewOf(s).file; next == fv || next.path != "/repo/docs/next.md" ||
		next.anchor != "target" {
		t.Fatalf("image link did not navigate: %+v", next)
	}
}
