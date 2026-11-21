package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"image/color"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"kero/internal/proto"
)

func awaitViewerImage(t *testing.T, load *viewerImageLoad) preparedViewerImage {
	t.Helper()
	select {
	case <-load.done:
	case <-time.After(5 * time.Second):
		t.Fatal("image preparation timed out")
	}
	if load.err != nil {
		t.Fatal(load.err)
	}
	return load.image
}

func TestViewerCacheLocal(t *testing.T) {
	var c viewerCache
	file := filepath.Join(t.TempDir(), "photo.png")
	raw := imageViewerURL("", file, "")
	original := viewerPNG(t, 2, 3, color.White)
	// PNG readers accept trailing bytes. Vary the payload without changing
	// its length, decoded format or dimensions.
	first := append(original, 1)
	second := append(append([]byte(nil), original...), 2)
	mtime := time.Unix(1000000000, 0)
	write := func(data []byte, at time.Time) {
		t.Helper()
		if err := os.WriteFile(file, data, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(file, at, at); err != nil {
			t.Fatal(err)
		}
	}
	check := func(want []byte) {
		t.Helper()
		img := awaitViewerImage(t, c.load(raw, previewSource{}, false, false))
		if img.src != "data:image/png;base64,"+base64.StdEncoding.EncodeToString(want) || img.thumbnail == "" || img.w != 2 || img.h != 3 {
			t.Fatalf("unexpected prepared image for %s", file)
		}
	}
	write(first, mtime)
	check(first)
	write(second, mtime)
	check(first) // unchanged stat reuses the prepared bytes
	mtime = mtime.Add(time.Second)
	write(second, mtime)
	check(second)
	write(original, mtime)
	check(original) // size alone changed
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	failed := c.load(raw, previewSource{}, false, false)
	<-failed.done
	if failed.err == nil || len(c.recent) != 0 {
		t.Fatal("missing file kept its previous image")
	}
	write(first, mtime)
	check(first)
}

func TestViewerCacheRemote(t *testing.T) {
	var c viewerCache
	original := viewerPNG(t, 3, 4, color.White)
	first := append(original, 1)
	second := append(append([]byte(nil), original...), 2)
	var data atomic.Pointer[[]byte]
	data.Store(&first)
	var stats, reads atomic.Int32
	cl, _ := projectClient(t, func(method string, _ json.RawMessage) (any, error) {
		switch method {
		case "fs.stat":
			stats.Add(1)
			return proto.FSStat{Path: "/remote/a.png", Exists: true, Size: int64(len(*data.Load()))}, nil
		case "fs.read":
			reads.Add(1)
			return proto.FSRead{Data: *data.Load()}, nil
		}
		return nil, errors.New("unexpected method " + method)
	})
	source := previewSource{host: "build", client: cl}
	raw := imageViewerURL("build", "a.png", "/remote")
	load := func(force bool, want []byte, count int32) *viewerImageLoad {
		t.Helper()
		job := c.load(raw, source, false, force)
		img := awaitViewerImage(t, job)
		if img.src != "data:image/png;base64,"+base64.StdEncoding.EncodeToString(want) || stats.Load() != count || reads.Load() != count {
			t.Fatalf("unexpected image or RPC count, got stat/read %d/%d, want %d/%d", stats.Load(), reads.Load(), count, count)
		}
		return job
	}
	load(false, first, 1)
	data.Store(&second)
	load(false, first, 1)
	fresh := load(true, second, 2) // explicit reload picks up same-size replacement
	load(false, second, 2)
	fresh.expires = time.Now().Add(-time.Second)
	data.Store(&first)
	load(false, first, 3)
	// A disconnected/replaced client must never reuse its predecessor's data.
	disconnected := c.load(raw, previewSource{host: "build"}, false, false)
	<-disconnected.done
	if disconnected.err == nil {
		t.Fatal("disconnected host reused an earlier connection's image")
	}
	broken := []byte("bad image")
	data.Store(&broken)
	failed := c.load(raw, source, false, true)
	<-failed.done
	if failed.err == nil {
		t.Fatal("failed reload served a cached image")
	}
	data.Store(&second)
	load(false, second, 5)
}

func TestViewerCacheConcurrentReload(t *testing.T) {
	var c viewerCache
	original := viewerPNG(t, 2, 2, color.Black)
	started := make(chan struct{})
	release := make(chan struct{})
	var reads atomic.Int32
	cl, _ := projectClient(t, func(method string, _ json.RawMessage) (any, error) {
		switch method {
		case "fs.stat":
			return proto.FSStat{Path: "/image.png", Exists: true, Size: int64(len(original)) + 1}, nil
		case "fs.read":
			n := reads.Add(1)
			if n == 1 {
				close(started)
				<-release
			}
			return proto.FSRead{Data: append(original, byte(n))}, nil
		}
		return nil, errors.New("unexpected method " + method)
	})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	raw := imageViewerURL("build", "/image.png", "")
	source := previewSource{host: "build", client: cl}
	first := c.load(raw, source, false, false)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("remote read did not start")
	}
	if c.load(raw, source, false, false) != first {
		t.Fatal("simultaneous reads of one source did not share work")
	}
	fresh := c.load(raw, source, false, true)
	if first.replacement.Load() != fresh || c.load(raw, source, false, false) != fresh {
		t.Fatal("new reads did not follow explicit reload")
	}
	close(release)
	oldImage := awaitViewerImage(t, first)
	newImage := awaitViewerImage(t, fresh)
	if oldImage.src == newImage.src || c.load(raw, source, false, false) != fresh || reads.Load() != 2 {
		t.Fatal("older result displaced the refreshed image")
	}
}

func TestViewerCacheBounds(t *testing.T) {
	var c viewerCache
	for i := 0; i < viewerCacheEntries+1; i++ {
		c.retain(&viewerImageLoad{size: int64(i)})
	}
	if len(c.recent) != viewerCacheEntries || c.recent[0].size != 1 {
		t.Fatal("entry limit did not evict the oldest image")
	}
	// Share one backing string to exercise the encoded-byte limit cheaply.
	part := strings.Repeat("a", viewerCacheBytes/viewerCacheEntries)
	large := &viewerImageLoad{image: preparedViewerImage{src: part, thumbnail: part, name: "a"}}
	for range viewerCacheEntries {
		c.retain(large)
	}
	if got, want := len(c.recent), viewerCacheBytes/(2*len(part)+1); got != want {
		t.Fatalf("byte limit retained %d images, want %d", got, want)
	}
}
