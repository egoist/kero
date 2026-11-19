package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

func TestFilePeekPath(t *testing.T) {
	for _, c := range []struct {
		name, link, want string
		windows, ok      bool
	}{
		{"unix", "file:///tmp/shot.png", "/tmp/shot.png", false, true},
		{"uppercase scheme", "FILE:///tmp/shot.png", "/tmp/shot.png", false, true},
		{"CJK space and plus", "file:///tmp/%E5%9B%BE%20shot+1.png", "/tmp/图 shot+1.png", false, true},
		{"decode percent once", "file:///tmp/a%2520b.png", "/tmp/a%20b.png", false, true},
		{"localhost", "file://localhost/tmp/shot.png", "/tmp/shot.png", false, true},
		{"windows drive", "file:///C:/Users/me/shot.png", "C:/Users/me/shot.png", true, true},
		{"windows lowercase drive", "file:///c:/Users/me/shot.png", "c:/Users/me/shot.png", true, true},
		{"windows UNC rejected", "file://server/share/%E5%9B%BE%20shot.png", "", true, false},
		{"windows empty authority UNC rejected", "file:////server/share/x.png", "", true, false},
		{"windows localhost UNC rejected", "file://localhost//server/share/x.png", "", true, false},
		{"windows escaped UNC rejected", "file:///%5C%5Cserver%5Cshare%5Cx.png", "", true, false},
		{"windows localhost", "file://localhost/C:/Users/me/shot.png", "C:/Users/me/shot.png", true, true},
		{"http", "https://example.com/shot.png", "", false, false},
		{"non-local unix authority", "file://server/share/shot.png", "", false, false},
		{"not hierarchical file URL", "file:/tmp/shot.png", "", false, false},
		{"malformed escape", "file:///tmp/%zz.png", "", false, false},
		{"empty path", "file://localhost", "", false, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, ok := filePeekPath(c.link, c.windows)
			if got != c.want || ok != c.ok {
				t.Fatalf("filePeekPath(%q, %v) = %q, %v; want %q, %v", c.link, c.windows, got, ok, c.want, c.ok)
			}
		})
	}
}

// A file hyperlink on a remote pane reads that host's path through RPC,
// even when the machine showing Kero has a file at the same path.
func TestRemoteImagePeekFileLink(t *testing.T) {
	a := testApp(t)
	h := withHost(t, a, "build")
	pane := a.st.Sessions[1].Panes[0]
	remotePath := filepath.Join(t.TempDir(), "图 shot.png")
	if err := os.WriteFile(remotePath, []byte("local decoy"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := (&url.URL{Scheme: "file", Path: remotePath}).String()
	path, ok := filePeekPath(link, h.windows())
	if !ok || path != remotePath {
		t.Fatalf("filePeekPath = %q, %v; want %q", path, ok, remotePath)
	}
	data := []byte("remote image")
	stats, reads := make(chan proto.FSStatParams, 1), make(chan proto.FSReadParams, 1)
	cl, _ := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		switch method {
		case "fs.stat":
			var p proto.FSStatParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			stats <- p
			return proto.FSStat{Path: p.Path, Exists: true, Size: int64(len(data))}, nil
		case "fs.read":
			var p proto.FSReadParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			reads <- p
			return proto.FSRead{Data: data}, nil
		default:
			return nil, fmt.Errorf("unexpected method %q", method)
		}
	})
	h.cl = cl
	a.imagePeek(pane.ID, path, ui.Rect{}, ui.Rect{})
	if want := h.name + "\x00" + pane.Dir + "\x00" + remotePath; a.peek.path != want {
		t.Fatalf("remote peek key = %q, want %q; local path is %q", a.peek.path, want, remotePath)
	}
	select {
	case got := <-stats:
		if got.Path != remotePath || got.Base != pane.Dir {
			t.Errorf("fs.stat = %+v, want path %q and base %q", got, remotePath, pane.Dir)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("remote fs.stat was not called")
	}
	select {
	case got := <-reads:
		if got.Path != remotePath || got.Max != maxPeekBytes {
			t.Errorf("fs.read = %+v, want path %q and max %d", got, remotePath, maxPeekBytes)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("remote fs.read was not called")
	}
}

func TestRemoteImagePeekRejectsNonImage(t *testing.T) {
	a := testApp(t)
	h := withHost(t, a, "build")
	pane := a.st.Sessions[1].Panes[0]
	called := make(chan string, 1)
	cl, _ := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		called <- method
		return nil, fmt.Errorf("unexpected method %q", method)
	})
	h.cl = cl
	link := "file:///home/me/api/notes.txt"
	path, ok := filePeekPath(link, h.windows())
	if !ok {
		t.Fatal("file URI was not parsed")
	}
	a.imagePeek(pane.ID, path, ui.Rect{}, ui.Rect{})
	if a.peek.path != "" || a.peek.bm != nil {
		t.Fatalf("non-image produced preview state: %+v", a.peek)
	}
	select {
	case method := <-called:
		t.Fatalf("non-image caused remote RPC %q", method)
	default:
	}
}
