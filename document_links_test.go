package main

import (
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

func testDocumentURL(path string) string {
	// RFC 8089: file URLs have an absolute URL path, including on Windows.
	return (&url.URL{Scheme: "file", Path: "/" + strings.TrimPrefix(filepath.ToSlash(path), "/")}).String()
}

func TestDocumentLocalPathsAndFileURLs(t *testing.T) {
	for _, kind := range []string{"relative", "absolute", "file-url", "localhost", "literal-percent"} {
		t.Run(kind, func(t *testing.T) {
			a := testApp(t)
			a.set.OpenDocumentLinks = true
			dir := t.TempDir()
			a.st.Sessions[0].Panes[0].Dir = dir
			path := filepath.Join(dir, "reading concepts.MD")
			want := testDocumentURL(path)
			link := want
			switch kind {
			case "relative":
				link = "reading concepts.MD"
			case "absolute":
				link = path
			case "localhost":
				link = strings.Replace(want, "file:///", "file://localhost/", 1)
			case "literal-percent":
				link = "100% done.md"
				want = testDocumentURL(filepath.Join(dir, link))
			}
			calls := make(chan proto.CreateParams, 1)
			a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
				var p proto.CreateParams
				if err := json.Unmarshal(raw, &p); err != nil {
					return nil, err
				}
				calls <- p
				return proto.Session{ID: "s1"}, nil
			})
			if !a.openLink("a", link) {
				t.Fatalf("local document link not handled: %s", link)
			}
			select {
			case got := <-calls:
				if got.URL != want {
					t.Fatalf("opened %s, want %s", got.URL, want)
				}
			case <-time.After(time.Second):
				t.Fatal("no document split")
			}
		})
	}
}

func TestDocumentLinkScope(t *testing.T) {
	for _, tc := range []struct {
		name    string
		link    string
		enabled bool
	}{
		{"off-by-default", "file:///tmp/notes.md", false},
		{"web-page", "https://example.com/notes.md", true},
		{"other-file", "file:///tmp/main.go", true},
		{"file-server", "file://server/share/notes.md", true},
		{"unc-file-url", "file:////server/share/notes.md", true},
		{"file-credentials", "file://user@localhost/tmp/notes.md", true},
		{"data-url", "data:text/plain,notes.md", true},
		{"javascript", "javascript:alert(1).md", true},
		{"network-path", "//server/share/notes.md", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := testApp(t)
			a.set.OpenDocumentLinks = tc.enabled
			a.local().cl, _ = projectClient(t, func(method string, _ json.RawMessage) (any, error) {
				return nil, errors.New("unexpected method " + method)
			})
			if a.openLink("a", tc.link) {
				t.Fatal("a link outside local document previews was intercepted")
			}
		})
	}
}

func TestDocumentClicksWhileOpeningShareOneSplit(t *testing.T) {
	a := testApp(t)
	a.set.OpenDocumentLinks = true
	calls := make(chan proto.CreateParams, 2)
	a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		var p proto.CreateParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		calls <- p
		return proto.Session{ID: "s1"}, nil
	})
	dir := t.TempDir()
	a.openLink("a", testDocumentURL(filepath.Join(dir, "first.html")))
	select {
	case <-calls:
	case <-time.After(time.Second):
		t.Fatal("first click did not create a split")
	}
	a.openLink("a", testDocumentURL(filepath.Join(dir, "second.md")))
	select {
	case <-calls:
		t.Fatal("a click during split creation created another split")
	case <-time.After(100 * time.Millisecond):
	}
}

func TestMissingDocumentPathStillOpensAPreview(t *testing.T) {
	a := testApp(t)
	a.set.OpenDocumentLinks = true
	dir := t.TempDir()
	a.st.Sessions[0].Panes[0].Dir = dir
	calls := make(chan proto.CreateParams, 1)
	a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		var p proto.CreateParams
		if method != "split" {
			return nil, errors.New("unexpected method " + method)
		}
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		calls <- p
		return proto.Session{ID: "s1"}, nil
	})
	if !a.openLink("a", "missing.md:7:2") {
		t.Fatal("a missing Markdown path should show its error in a preview")
	}
	select {
	case got := <-calls:
		want := testDocumentURL(filepath.Join(dir, "missing.md"))
		if got.URL != want {
			t.Fatalf("opened %s, want %s", got.URL, want)
		}
	case <-time.After(time.Second):
		t.Fatal("no missing-document preview")
	}
}

func TestDocumentLinkReusesAnExistingPreview(t *testing.T) {
	a := testApp(t)
	a.set.OpenDocumentLinks = true
	path := filepath.Join(t.TempDir(), "second.html")
	link := testDocumentURL(path)
	a.st.Sessions[0].Panes[1].URL = testDocumentURL(filepath.Join(t.TempDir(), "first.html"))
	calls := make(chan proto.PageParams, 1)
	a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method != "pane.page" {
			return nil, errors.New("unexpected method " + method)
		}
		var p proto.PageParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		calls <- p
		return nil, nil
	})
	if !a.openLink("a", link) {
		t.Fatal("the link was not handled")
	}
	select {
	case got := <-calls:
		if got.ID != "b" || got.URL != link {
			t.Fatalf("navigated %+v, want existing preview b at %s", got, link)
		}
	case <-time.After(time.Second):
		t.Fatal("the existing preview was not reused")
	}
	if len(a.st.Sessions[0].Panes) != 2 {
		t.Fatal("opening another document added a pane")
	}
}

func TestDocumentLinkOpensBesideItsTerminal(t *testing.T) {
	a := testApp(t)
	a.set.OpenDocumentLinks = true
	dir := t.TempDir()
	path := filepath.Join(dir, "reading concepts.html")
	if err := os.WriteFile(path, []byte("<h1>Reading concepts</h1>"), 0o600); err != nil {
		t.Fatal(err)
	}
	a.st.Sessions[0].Panes[0].Dir = dir
	wantURL := testDocumentURL(path)
	calls := make(chan proto.CreateParams, 2)
	a.local().cl, _ = projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method != "split" {
			return nil, errors.New("unexpected method " + method)
		}
		var p proto.CreateParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		calls <- p
		return proto.Session{ID: "s1"}, nil
	})
	// The destination of an OSC 8 / Markdown link, not its visible label.
	if !a.openLink("a", wantURL) {
		t.Fatal("the local HTML link was handed to the external app")
	}
	select {
	case got := <-calls:
		if got.Split != "a" || got.Direction != "right" || got.URL != wantURL {
			t.Fatalf("opened %+v; want a browser to the right of a at %s", got, wantURL)
		}
	case <-time.After(time.Second):
		t.Fatal("the click did not open a browser split")
	}
}
