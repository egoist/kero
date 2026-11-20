package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/egoist/mygo/ui"

	"kero/internal/client"
	"kero/internal/proto"
)

const (
	imageViewerScheme = "kero-image"
	maxViewerBytes    = 32 << 20
)

type viewerZoomState struct {
	Enabled bool    `json:"enabled"`
	Zoom    float64 `json:"zoom"`
	PanX    float64 `json:"panX"`
	PanY    float64 `json:"panY"`
}

func finiteViewerNumber(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0)
}

// imageViewerURL keeps only what loading an image needs in the pane's saved
// URL. The image's bytes never enter kerod's session state.
func imageViewerURL(host, path, base string) string {
	q := url.Values{"host": {host}, "path": {path}, "base": {base}}
	return imageViewerScheme + "://view?" + q.Encode()
}

func imageViewerQuery(raw string) (host, path, base string, ok bool) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != imageViewerScheme || u.Host != "view" {
		return "", "", "", false
	}
	q := u.Query()
	host, path, base = q.Get("host"), q.Get("path"), q.Get("base")
	return host, path, base, path != ""
}

// imageKey compares paths using the source host's conventions. Keep the raw
// URL for reads; this identity only decides whether a pane is already open.
func (h *host) imageKey(raw string) string {
	name, file, base, ok := imageViewerQuery(raw)
	if !ok || name != h.name {
		return ""
	}
	if h.windows() {
		file = strings.ReplaceAll(file, `\`, "/")
		base = strings.ReplaceAll(base, `\`, "/")
		// Keep UNC and drive-relative forms distinct from rooted paths.
		if strings.HasPrefix(file, "//") || len(file) >= 2 && file[1] == ':' {
			if strings.HasPrefix(file, "//") || len(file) > 2 && file[2] == '/' {
				base = ""
			}
			return imageViewerURL(name, file, base)
		}
	}
	if !path.IsAbs(file) && base != "" && !strings.HasPrefix(file, "~/") {
		file = path.Join(base, file)
	}
	return imageViewerURL(name, path.Clean(file), "")
}

type viewerGroup struct {
	zoom viewerZoomState
	urls []string // ordered comparison set, retained across previous/next
}

func (a *App) viewerGroup(id string) *viewerGroup {
	if a.viewerGroups == nil {
		a.viewerGroups = make(map[string]*viewerGroup)
	}
	if a.viewerGroups[id] == nil {
		a.viewerGroups[id] = new(viewerGroup)
	}
	return a.viewerGroups[id]
}

func (a *App) hasViewer(s *proto.Session) bool {
	for _, p := range s.Panes {
		if _, _, _, ok := imageViewerQuery(p.URL); ok {
			return true
		}
	}
	return false
}

// openImagePane opens an image path or file:// hyperlink as a full viewer
// beside the pane that printed it. Everything else keeps its old open path.
func (a *App) openImagePane(paneID, link string) bool {
	path := lineSuffix.ReplaceAllString(link, "")
	if strings.Contains(path, "://") {
		var ok bool
		path, ok = filePeekPath(path, a.hostOf(paneID).windows())
		if !ok {
			return false
		}
	}
	if !peekable[strings.ToLower(filepath.Ext(path))] {
		return false
	}
	h := a.hostOf(paneID)
	if !h.remote() {
		path = a.resolvePath(paneID, path)
		if path == "" {
			return false
		}
		if st, err := os.Stat(path); err != nil || st.IsDir() || st.Size() > maxViewerBytes {
			return false
		}
	}
	s := a.sessionOfPane(paneID)
	if s == nil {
		return false
	}
	u := imageViewerURL(h.name, path, a.workDir(paneID))
	key := [2]string{s.ID, h.imageKey(u)}
	if a.viewerPending[key] {
		return true
	}
	for _, p := range s.Panes {
		current := p.URL
		if e := a.webs[p.ID]; e != nil {
			current = e.url
		}
		if h.imageKey(current) == key[1] {
			a.selectSession(s.ID)
			a.setFocus(s, p.ID)
			return true
		}
	}
	if a.viewerPending == nil {
		a.viewerPending = map[[2]string]bool{}
	}
	a.viewerPending[key] = true
	a.split(s, proto.CreateParams{Split: paneID, Direction: "right", URL: u})
	return true
}

// imageViewerTitle handles synthetic zoom/navigation events from a viewer.
// The generation and sequence make stale or repeated titles harmless.
func (a *App) imageViewerTitle(e *webEntry, pageURL, title string) bool {
	if e.viewerURL == "" || e.viewerURL != pageURL {
		return false
	}
	parts := strings.SplitN(title, ":", 4)
	if len(parts) != 4 || parts[0] != "kero-zoom" && parts[0] != "kero-nav" {
		return false
	}
	generation, genErr := strconv.ParseUint(parts[1], 10, 64)
	sequence, seqErr := strconv.ParseUint(parts[2], 10, 64)
	if !e.viewerReady || e.url != pageURL || genErr != nil || generation != e.nav || seqErr != nil || sequence <= e.viewerSeq {
		return true
	}
	s := a.sessionOfPane(e.id)
	if s == nil || a.webs[e.id] != e {
		return true
	}
	e.viewerSeq = sequence
	if parts[0] == "kero-nav" {
		a.navigateViewer(s, e, parts[3])
		return true
	}
	var st viewerZoomState
	if json.Unmarshal([]byte(parts[3]), &st) != nil || st.Zoom <= 0 || !finiteViewerNumber(st.Zoom) || !finiteViewerNumber(st.PanX) || !finiteViewerNumber(st.PanY) {
		return true
	}
	group := a.viewerGroup(s.ID)
	if !st.Enabled && !group.zoom.Enabled {
		return true
	}
	group.zoom = st
	for _, p := range s.Panes {
		if other := a.webs[p.ID]; other != nil && other != e {
			other.sendViewerZoom(st)
		}
	}
	return true
}

func (e *webEntry) sendViewerZoom(st viewerZoomState) {
	if !e.viewerReady || e.viewerURL == "" || e.url != e.viewerURL || e.view == nil || e.view.IsDestroyed() || e.view.Page().URL() != e.viewerURL {
		return
	}
	encoded, _ := json.Marshal(st)
	e.view.Page().Eval(fmt.Sprintf("if(window.__keroViewerGeneration===%d)window.__keroApplyZoom(%s)", e.nav, encoded))
}

func (a *App) navigateViewer(s *proto.Session, source *webEntry, direction string) {
	if direction != "next" && direction != "prev" {
		return
	}
	group := a.viewerGroup(s.ID)
	h := a.hostOf(s.ID)
	for _, p := range s.Panes {
		raw := p.URL
		if e := a.webs[p.ID]; e != nil {
			raw = e.url
		}
		if key := h.imageKey(raw); key != "" && !slices.ContainsFunc(group.urls, func(u string) bool { return h.imageKey(u) == key }) {
			group.urls = append(group.urls, raw)
		}
	}
	if len(group.urls) < 2 {
		return
	}
	delta := 1
	if direction == "prev" {
		delta = -1
	}
	for _, p := range s.Panes {
		e := a.webs[p.ID]
		if e == nil || e != source && !group.zoom.Enabled {
			continue
		}
		key := h.imageKey(e.url)
		if at := slices.IndexFunc(group.urls, func(u string) bool { return h.imageKey(u) == key }); at >= 0 {
			e.load(group.urls[(at+delta+len(group.urls))%len(group.urls)])
		}
	}
}

// loadImageEntry starts loading an internal image URL, or reports that text
// is an ordinary browser address. Newer navigations discard older results.
func (a *App) loadImageEntry(e *webEntry, text string) bool {
	_, _, _, ok := imageViewerQuery(text)
	if !ok {
		return false
	}
	e.url, e.address, e.err = text, text, ""
	e.loading = true
	if e.view == nil {
		err := errors.New("image viewer is unavailable")
		e.err, e.loading = err.Error(), false
		e.loadEnded(err)
		return true
	}
	seq := e.nav
	host := a.hostOf(e.id)
	source, cl := host.name, host.cl
	go func() {
		data, name, w, h, mime, err := readImage(text, source, cl)
		a.update(func() {
			if a.webs[e.id] != e || e.nav != seq {
				return
			}
			if err != nil {
				e.err, e.loading = err.Error(), false
				e.loadEnded(err)
				return
			}
			e.err, e.viewerURL = "", text
			e.view.Page().LoadHTML(imageViewerHTML(name, w, h, mime, data, seq), text)
			e.url, e.address, e.title = text, name, name
			a.tellPage(e.id, e)
		})
	}()
	return true
}

// readImage only reads from the host that owns the pane. The host and client
// are captured before leaving the UI thread, including for a restored pane.
func readImage(raw, source string, cl *client.Client) (data []byte, name string, w, h int, mime string, err error) {
	host, path, base, ok := imageViewerQuery(raw)
	if !ok {
		return nil, "", 0, 0, "", errors.New("invalid image viewer URL")
	}
	name = filepath.Base(path)
	if host != source {
		return nil, name, 0, 0, "", errors.New("image host differs from pane host")
	}
	if source != "" {
		if cl == nil {
			return nil, name, 0, 0, "", errors.New("image host is not connected")
		}
		var st proto.FSStat
		if err = cl.Call("fs.stat", proto.FSStatParams{Path: path, Base: base}, &st); err != nil {
			return nil, name, 0, 0, "", err
		}
		if !st.Exists || st.Dir || st.Size > maxViewerBytes {
			return nil, name, 0, 0, "", errors.New("remote image is missing, a directory, or too large")
		}
		var r proto.FSRead
		if err = cl.Call("fs.read", proto.FSReadParams{Path: st.Path, Max: maxViewerBytes}, &r); err != nil {
			return nil, name, 0, 0, "", err
		}
		data = r.Data
	} else {
		if !filepath.IsAbs(path) {
			return nil, name, 0, 0, "", errors.New("local image path is not absolute")
		}
		st, statErr := os.Stat(path)
		if statErr != nil || st.IsDir() || st.Size() > maxViewerBytes {
			return nil, name, 0, 0, "", errors.New("local image is missing, a directory, or too large")
		}
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, name, 0, 0, "", err
		}
		if len(data) > maxViewerBytes {
			return nil, name, 0, 0, "", errors.New("local image grew beyond the size limit")
		}
	}
	bm, err := ui.DecodeBitmap(data)
	if err != nil {
		return nil, name, 0, 0, "", errors.New("unsupported image data")
	}
	w, h = bm.Size()
	mime = http.DetectContentType(data)
	if !strings.HasPrefix(mime, "image/") {
		return nil, name, 0, 0, "", errors.New("unsupported image MIME type")
	}
	return data, name, w, h, mime, nil
}
