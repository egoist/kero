package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"math"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/locales"
)

const (
	imageViewerScheme = "kero-image"
	maxViewerBytes    = 32 << 20
	viewerThumbEdge   = 128
)

func viewerDownloadMessage(d *mygo.Download) string {
	name := filepath.Base(d.Path)
	if d.Err != nil {
		return locales.ViewerSaveFailed(name, d.Err.Error())
	}
	return locales.ViewerDownloaded(name)
}

type viewerZoomState struct {
	Enabled bool    `json:"enabled"`
	Mode    string  `json:"mode"`
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

// imageViewers holds the comparison for each session and the splits awaiting a reply.
type imageViewers struct {
	pending       map[[2]string]bool // terminal opens, keyed by session and image
	pendingClones map[string]bool    // explicit viewer splits, keyed by source pane
	groups        map[string]*viewerGroup
}

// viewerDocument tracks the HTML supplied by Kero for one browser navigation.
type viewerDocument struct {
	url            string
	ready          bool
	seq            uint64
	toggleSeq      uint64 // most recent explicit toggle from this document
	toggleEpoch    uint64 // native epoch assigned to that toggle
	delivery       *viewerDelivery
	palette        *palette
	locale         string
	galleryVersion uint64
}

func (v *viewerDocument) reset() {
	if v.delivery != nil {
		v.delivery.cancel()
	}
	*v = viewerDocument{}
}

func (v *viewerDocument) navigated(url string) {
	if url != v.url {
		v.reset()
	}
}

// panePansContent tells layout whether pressing near the divider could start
// a canvas drag. This runs while laying out each frame.
func panePansContent(p *proto.Pane) bool {
	return p != nil && strings.HasPrefix(p.URL, imageViewerScheme+"://view?")
}

type viewerGalleryItem struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Thumbnail string `json:"thumbnail"`
	url       string // original URL, including the base used for remote reads
}

type viewerGroup struct {
	cache    viewerCache
	zoom     viewerZoomState
	revision uint64              // total order of accepted edits within the group
	epoch    uint64              // revision of the last explicit toggle
	items    []viewerGalleryItem // append-only while the session has viewers
	index    map[string]int      // source path identity to stable gallery index
	version  uint64
}

func viewerImageName(file string, windows bool) string {
	if windows {
		if len(file) >= 2 && file[1] == ':' {
			file = file[2:] // drive-relative paths can have no separator
		}
		return pathBase(file)
	}
	return path.Base(file)
}

func (v *imageViewers) group(id string) *viewerGroup {
	if v.groups == nil {
		v.groups = make(map[string]*viewerGroup)
	}
	if v.groups[id] == nil {
		v.groups[id] = &viewerGroup{zoom: viewerZoomState{Mode: "fit", Zoom: 1}, index: make(map[string]int)}
	}
	return v.groups[id]
}

func (a *App) pruneImageViewers() {
	for id, group := range a.images.groups {
		s := a.session(id)
		if s == nil || !a.collectViewerImages(s, group) {
			delete(a.images.groups, id)
			continue
		}
		a.sendViewerGallery(s, group)
	}
}

// The daemon supplies panes in layout order. A pane can move to another
// image, so only append newly seen identities and keep the original read URL.
func (a *App) collectViewerImages(s *proto.Session, group *viewerGroup) bool {
	h := a.hostOf(s.ID)
	live := false
	for _, p := range s.Panes {
		raw := p.URL
		if e := a.webs[p.ID]; e != nil {
			raw = e.url
		}
		key := h.imageKey(raw)
		if key == "" {
			continue
		}
		live = true
		if _, seen := group.index[key]; seen {
			continue
		}
		_, file, _, _ := imageViewerQuery(raw)
		group.index[key] = len(group.items)
		group.items = append(group.items, viewerGalleryItem{Name: viewerImageName(file, h.windows()), Path: file, url: raw})
		group.version++
	}
	return live
}

// Marshal once per broadcast. Each document gets its own current index,
// including when only that document has just finished loading.
func (a *App) sendViewerGallery(s *proto.Session, group *viewerGroup) {
	h := a.hostOf(s.ID)
	var encoded []byte
	for _, p := range s.Panes {
		e := a.webs[p.ID]
		if e == nil || e.viewer.galleryVersion == group.version || !e.viewerPageReady() {
			continue
		}
		current, ok := group.index[h.imageKey(e.url)]
		if !ok {
			continue
		}
		if encoded == nil {
			encoded, _ = json.Marshal(group.items)
		}
		e.view.Page().Eval(fmt.Sprintf("if(window.__keroViewerGeneration===%d)window.__keroApplyGallery(%s,%d)", e.nav, encoded, current))
		e.viewer.galleryVersion = group.version
	}
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
	if a.images.pending[key] {
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
	if a.images.pending == nil {
		a.images.pending = map[[2]string]bool{}
	}
	a.images.pending[key] = true
	a.split(s, proto.CreateParams{Split: paneID, Direction: "right", URL: u}, func() {
		delete(a.images.pending, key)
	})
	return true
}

// Order viewer input on the UI thread without scheduling a native frame.
func (e *webEntry) handleViewerTitle(page *mygo.Page, t *mygo.TitleEvent) bool {
	a := e.app
	navigation := strings.HasPrefix(t.Title, "kero-nav:")
	if !navigation && !strings.HasPrefix(t.Title, "kero-zoom:") {
		return false
	}
	// Resolve commands against the emitting page now. The deferred title
	// handler could otherwise retry a foreign title after the page changes.
	if a.imageViewerTitle(e, page.URL(), t.Title) {
		t.PreventDefault()
		if navigation {
			a.win.Invalidate()
		}
	}
	return true
}

func (e *webEntry) finishViewerLoad(url string) bool {
	if e.viewer.url == "" || e.viewer.url != url || e.url != url {
		return false
	}
	e.viewer.ready = true
	e.viewer.palette = nil
	e.viewer.galleryVersion = 0
	if s := e.app.sessionOfPane(e.id); s != nil {
		group := e.app.images.group(s.ID)
		e.app.collectViewerImages(s, group)
		e.app.sendViewerGallery(s, group)
		e.sendViewerZoom(group.snapshot(e.viewer.seq))
	}
	return true
}

// imageViewerTitle handles synthetic zoom/navigation events from a viewer.
// The generation and sequence make stale or repeated titles harmless.
func (a *App) imageViewerTitle(e *webEntry, pageURL, title string) bool {
	parts := strings.SplitN(title, ":", 4)
	if len(parts) != 4 || parts[0] != "kero-zoom" && parts[0] != "kero-nav" {
		return false
	}
	if _, _, _, internal := imageViewerQuery(pageURL); !internal {
		return false
	}
	// Consume departing documents' titles before the ordinary title handler
	// can restore the previous URL while the next image decodes.
	if e.viewer.url != pageURL {
		return true
	}
	generation, genErr := strconv.ParseUint(parts[1], 10, 64)
	sequence, seqErr := strconv.ParseUint(parts[2], 10, 64)
	if !e.viewer.ready || e.url != pageURL || genErr != nil || generation != e.nav || seqErr != nil || sequence <= e.viewer.seq {
		return true
	}
	s := a.sessionOfPane(e.id)
	if s == nil || a.webs[e.id] != e {
		return true
	}
	previous := e.viewer.seq
	e.viewer.seq = sequence
	if parts[0] == "kero-nav" {
		direction := parts[3]
		if strings.HasPrefix(direction, "{") {
			var nav struct {
				Direction string           `json:"direction"`
				ViewSeq   uint64           `json:"viewSeq"`
				View      *viewerZoomInput `json:"view"`
			}
			if json.Unmarshal([]byte(direction), &nav) != nil {
				return true
			}
			direction = nav.Direction
			// WebKit may report only the navigation title after a gesture.
			if nav.View != nil && previous < nav.ViewSeq && nav.ViewSeq < sequence {
				a.updateViewerZoom(s, e, *nav.View, previous, nav.ViewSeq)
			}
		}
		a.navigateViewer(s, e, direction)
		if e.nav == generation && e.viewerPageReady() {
			e.view.Page().Eval(fmt.Sprintf("window.__keroViewerGeneration===%d && window.__keroAckNav(%d)", generation, sequence))
		}
		return true
	}
	var input viewerZoomInput
	if json.Unmarshal([]byte(parts[3]), &input) == nil {
		a.updateViewerZoom(s, e, input, previous, sequence)
	}
	return true
}

func (e *webEntry) viewerPageReady() bool {
	return e.viewer.ready && e.viewer.url != "" && e.url == e.viewer.url && e.view != nil && !e.view.IsDestroyed() && e.view.Page().URL() == e.viewer.url
}

func (a *App) navigateViewer(s *proto.Session, source *webEntry, direction string) {
	key := a.hostOf(s.ID).imageKey(source.url)
	if key == "" {
		return
	}
	if direction == "new-pane" {
		if a.images.pendingClones[source.id] {
			return
		}
		if a.images.pendingClones == nil {
			a.images.pendingClones = make(map[string]bool)
		}
		a.images.pendingClones[source.id] = true
		a.split(s, proto.CreateParams{Split: source.id, Direction: "right", URL: source.url}, func() {
			delete(a.images.pendingClones, source.id)
		})
		return
	}
	group := a.images.group(s.ID)
	a.collectViewerImages(s, group)
	current, ok := group.index[key]
	count := len(group.items)
	if !ok || count < 2 {
		return
	}
	var target int
	switch direction {
	case "next":
		target = (current + 1) % count
	case "prev":
		target = (current + count - 1) % count
	default:
		index, found := strings.CutPrefix(direction, "pick-")
		pick, err := strconv.Atoi(index)
		if !found || err != nil || pick < 0 || pick >= count || strconv.Itoa(pick) != index || pick == current {
			return
		}
		target = pick
	}
	source.load(group.items[target].url)
}

// loadImageEntry starts loading an internal image URL, or reports that text
// is an ordinary browser address. Newer navigations discard older results.
func (a *App) loadImageEntry(e *webEntry, text string) bool {
	if _, _, _, ok := imageViewerQuery(text); !ok {
		e.viewer.reset()
		return false
	}
	a.startImageEntry(e, text, false)
	return true
}

func (a *App) startImageEntry(e *webEntry, text string, force bool) {
	e.viewer.reset()
	e.url, e.address, e.err = text, text, ""
	e.loading = true
	appearance := currentViewerAppearance()
	var cache *viewerCache
	if s := a.sessionOfPane(e.id); s != nil {
		group := a.images.group(s.ID)
		if group.zoom.Enabled {
			initial := group.snapshot(0)
			appearance.InitialZoom = &initial
		}
		cache = &group.cache
		a.collectViewerImages(s, group)
		a.sendViewerGallery(s, group)
	} else {
		cache = new(viewerCache)
	}
	if e.view == nil {
		err := errors.New("image viewer is unavailable")
		e.err, e.loading = err.Error(), false
		e.loadEnded(err)
		return
	}
	host := a.hostOf(e.id)
	load := cache.load(text, host.previewSource(), host.windows(), force)
	e.showViewerImage(load, text, e.nav, appearance)
}

func (e *webEntry) showViewerImage(load *viewerImageLoad, text string, seq uint64, appearance viewerAppearance) {
	a := e.app
	go func() {
		<-load.done
		img := load.image
		var html string
		if load.err == nil && load.replacement.Load() == nil {
			html = appearance.render(img, seq)
		}
		a.update(func() {
			if a.webs[e.id] != e || e.nav != seq || e.url != text || e.view.IsDestroyed() {
				return
			}
			host := a.hostOf(e.id)
			if host.name != load.key.source.host || host.remote() && host.cl != load.key.source.client {
				e.load(text)
				return
			}
			if newer := load.replacement.Load(); newer != nil {
				e.showViewerImage(newer, text, seq, appearance)
				return
			}
			if s := a.sessionOfPane(e.id); s != nil {
				group := a.images.group(s.ID)
				a.collectViewerImages(s, group)
				if i, ok := group.index[host.imageKey(text)]; ok && group.items[i].Thumbnail != img.thumbnail {
					group.items[i].Thumbnail = img.thumbnail
					group.version++
				}
				a.sendViewerGallery(s, group)
			}
			if load.err != nil {
				e.err, e.loading = load.err.Error(), false
				e.loadEnded(load.err)
				return
			}
			e.err, e.viewer.url = "", text
			e.view.Page().LoadHTML(html, text)
			e.url, e.address, e.title = text, img.name, img.name
			a.tellPage(e.id, e)
		})
	}()
}

type viewerImage struct {
	data                  []byte
	name, mime, thumbnail string
	w, h                  int
}

// readImage only reads from the host that owns the pane. The host and client
// are captured before leaving the UI thread, including for a restored pane.
func readImage(raw string, source previewSource, windows bool) (viewerImage, error) {
	host, file, base, ok := imageViewerQuery(raw)
	if !ok {
		return viewerImage{}, errors.New("invalid image viewer URL")
	}
	if host != source.host {
		return viewerImage{}, errors.New("image host differs from pane host")
	}
	data, err := source.read(file, base, maxViewerBytes)
	if err != nil {
		return viewerImage{}, err
	}
	mime := http.DetectContentType(data)
	if !strings.HasPrefix(mime, "image/") {
		return viewerImage{}, errors.New("unsupported image MIME type")
	}
	bm, err := ui.DecodeBitmap(data)
	if err != nil {
		return viewerImage{}, errors.New("unsupported image data")
	}
	w, h := bm.Size()
	return viewerImage{data: data, name: viewerImageName(file, windows), mime: mime, w: w, h: h, thumbnail: viewerThumbnail(bm)}, nil
}

func viewerThumbnail(bm *ui.Bitmap) string {
	w, h := bm.Size()
	if w < 1 || h < 1 {
		return ""
	}
	if edge := max(w, h); edge > viewerThumbEdge {
		scale := float64(viewerThumbEdge) / float64(edge)
		w, h = max(1, int(math.Round(float64(w)*scale))), max(1, int(math.Round(float64(h)*scale)))
	}
	thumb := ui.Render(func(c *ui.Context) {
		ui.Image(c, bm).Size(float32(w), float32(h))
	}, w, h, 1)
	var buf bytes.Buffer
	if err := png.Encode(&buf, thumb); err != nil {
		return ""
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(buf.Bytes())
}
