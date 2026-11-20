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
	for _, hyperlink := range []bool{false, true} {
		name := "plain path"
		if hyperlink {
			name = "file hyperlink"
		}
		t.Run(name, func(t *testing.T) {
			a := testApp(t)
			dir := t.TempDir()
			a.st.Sessions[0].Panes[0].Dir = dir
			path := filepath.Join(dir, "shot.png")
			if err := os.WriteFile(path, []byte("image"), 0o600); err != nil {
				t.Fatal(err)
			}
			splits := make(chan proto.CreateParams, 1)
			cl, _ := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
				if method != "split" {
					t.Errorf("unexpected method %q", method)
				}
				var p proto.CreateParams
				if err := json.Unmarshal(raw, &p); err != nil {
					return nil, err
				}
				splits <- p
				return proto.Session{}, nil
			})
			a.local().cl = cl
			link := path
			if hyperlink {
				link = (&url.URL{Scheme: "file", Path: path}).String()
			}
			if !a.openImagePane("a", link) {
				t.Fatal("image did not open a viewer")
			}
			select {
			case got := <-splits:
				if got.Split != "a" || got.Direction != "right" {
					t.Errorf("split = %+v", got)
				}
				host, path, base, ok := imageViewerQuery(got.URL)
				if !ok || host != "" || path != path || base != dir {
					t.Errorf("viewer URL = %q; host %q path %q base %q", got.URL, host, path, base)
				}
			case <-time.After(time.Second):
				t.Fatal("no viewer split")
			}
			if a.openImagePane("a", filepath.Join(dir, "notes.txt")) {
				t.Error("non-image opened a viewer")
			}
		})
	}
}

func TestReadImageLocal(t *testing.T) {
	a := testApp(t)
	path := filepath.Join(t.TempDir(), "图 shot.png")
	want := viewerPNG(t, 2, 3, color.RGBA{R: 10, G: 20, B: 30, A: 255})
	if err := os.WriteFile(path, want, 0o600); err != nil {
		t.Fatal(err)
	}
	data, name, w, h, mime, err := a.readImage(imageViewerURL("", path, ""))
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
	data, name, w, height, mime, err := a.readImage(imageViewerURL(h.name, remotePath, "/home/me/api"))
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
	a := testApp(t)
	path := filepath.Join(t.TempDir(), "large.png")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(path, maxViewerBytes+1); err != nil {
		t.Fatal(err)
	}
	if _, _, _, _, _, err := a.readImage(imageViewerURL("", path, "")); err == nil {
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
	page := imageViewerHTML(`x<svg onload=alert(1)>.png`, 2, 3, "image/png", []byte{1, 2})
	if strings.Contains(page, "<svg onload") || !strings.Contains(page, "x&lt;svg") {
		t.Error("filename was not escaped")
	}
	for _, want := range []string{"2 × 3", `id="fit"`, `id="actual"`, "data:image/png;base64,"} {
		if !strings.Contains(page, want) {
			t.Errorf("page lacks %q", want)
		}
	}
}
