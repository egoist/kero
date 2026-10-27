package adblock

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLoad(t *testing.T) {
	var requests, notModified atomic.Int32
	body := "[Adblock Plus 2.0]\n||ads.example^\n"
	broken := atomic.Bool{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		switch {
		case broken.Load():
			http.Error(w, "down", http.StatusServiceUnavailable)
		case r.URL.Path == "/portal":
			w.Write([]byte("<html>sign in</html>"))
		case r.Header.Get("If-Modified-Since") != "":
			notModified.Add(1)
			w.WriteHeader(http.StatusNotModified)
		default:
			w.Write([]byte(body))
		}
	}))
	defer server.Close()
	dir := t.TempDir()
	sources := []Source{{"list", "List", server.URL + "/list"}}
	path := filepath.Join(dir, "list.txt")

	lists, err := Load(context.Background(), dir, sources)
	if err != nil || len(lists) != 1 || lists[0] != body {
		t.Fatalf("first Load = %q, %v", lists, err)
	}
	// A list of this week is not downloaded again.
	if _, err := Load(context.Background(), dir, sources); err != nil || requests.Load() != 1 {
		t.Fatalf("a fresh list was downloaded again: %d requests, %v", requests.Load(), err)
	}
	// An older one is asked for, and counts as new when it did not change.
	old := time.Now().Add(-Refresh - time.Hour)
	os.Chtimes(path, old, old)
	if lists, err := Load(context.Background(), dir, sources); err != nil || lists[0] != body || notModified.Load() != 1 {
		t.Fatalf("stale Load = %q, %v, %d not modified", lists, err, notModified.Load())
	}
	if info, _ := os.Stat(path); time.Since(info.ModTime()) > time.Hour {
		t.Errorf("the list not modified kept its time: %v", info.ModTime())
	}
	// When the server fails, the list kept serves.
	os.Chtimes(path, old, old)
	broken.Store(true)
	if lists, err := Load(context.Background(), dir, sources); err != nil || lists[0] != body {
		t.Fatalf("Load with the server down = %q, %v", lists, err)
	}
	// Without a list kept, it fails.
	if _, err := Load(context.Background(), t.TempDir(), sources); err == nil {
		t.Error("Load without a list or a server worked")
	}
	broken.Store(false)
	// What is no filter list is not kept.
	portal := t.TempDir()
	if _, err := Load(context.Background(), portal, []Source{{"list", "List", server.URL + "/portal"}}); err == nil {
		t.Error("a page that is no filter list was taken")
	}
	if _, err := os.Stat(filepath.Join(portal, "list.txt")); err == nil {
		t.Error("a page that is no filter list was kept")
	}
}

func TestFind(t *testing.T) {
	if s, ok := Find("easyprivacy"); !ok || s.Name != "EasyPrivacy" || s.file() != "easyprivacy.txt" {
		t.Errorf("Find(easyprivacy) = %+v, %v", s, ok)
	}
	a, ok := Find("https://lists.example/a.txt")
	b, _ := Find("https://lists.example/b.txt")
	if !ok || a.Name != "lists.example" || a.file() == b.file() || !strings.HasPrefix(a.file(), "url-") {
		t.Errorf("lists of URLs: %+v %s, %s", a, a.file(), b.file())
	}
	for _, id := range []string{"", "no-such-list", "ftp://lists.example/a.txt", "https://", "easylist.txt"} {
		if s, ok := Find(id); ok {
			t.Errorf("Find(%q) = %+v", id, s)
		}
	}
	for _, id := range DefaultLists {
		if _, ok := Find(id); !ok {
			t.Errorf("default list %q is not in the catalog", id)
		}
	}
}
