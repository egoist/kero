package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

const (
	imageViewerScheme = "kero-image"
	maxViewerBytes    = 32 << 20
)

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
	a.split(s, proto.CreateParams{Split: paneID, Direction: "right", URL: imageViewerURL(h.name, path, a.workDir(paneID))})
	return true
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
	go func() {
		data, name, w, h, mime, err := a.readImage(text)
		a.update(func() {
			if a.webs[e.id] != e || e.nav != seq {
				return
			}
			if err != nil {
				e.err, e.loading = err.Error(), false
				e.loadEnded(err)
				return
			}
			e.err = ""
			e.view.Page().LoadHTML(imageViewerHTML(name, w, h, mime, data), text)
			e.url, e.address, e.title = text, name, name
			a.tellPage(e.id, e)
		})
	}()
	return true
}

// readImage reads and validates a viewer image, returning its HTML-safe name,
// dimensions and MIME type. A remote read never falls back to a local file.
func (a *App) readImage(raw string) (data []byte, name string, w, h int, mime string, err error) {
	host, path, base, ok := imageViewerQuery(raw)
	if !ok {
		return nil, "", 0, 0, "", errors.New("invalid image viewer URL")
	}
	name = filepath.Base(path)
	hst := a.local()
	if host != "" {
		hst = a.hostNamed(host)
		if hst == nil {
			return nil, name, 0, 0, "", fmt.Errorf("unknown image host %q", host)
		}
	}
	if hst.remote() {
		if hst.cl == nil {
			return nil, name, 0, 0, "", errors.New("image host is not connected")
		}
		var st proto.FSStat
		if err = hst.cl.Call("fs.stat", proto.FSStatParams{Path: path, Base: base}, &st); err != nil {
			return nil, name, 0, 0, "", err
		}
		if !st.Exists || st.Dir || st.Size > maxViewerBytes {
			return nil, name, 0, 0, "", errors.New("remote image is missing, a directory, or too large")
		}
		var r proto.FSRead
		if err = hst.cl.Call("fs.read", proto.FSReadParams{Path: st.Path, Max: maxViewerBytes}, &r); err != nil {
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

// imageViewerHTML is a self-contained page. Its data URL lives only in the
// WebView, never in the pane's URL or kerod's session state.
func imageViewerHTML(name string, w, h int, mime string, data []byte) string {
	name = html.EscapeString(name)
	var b strings.Builder
	b.WriteString(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>`)
	b.WriteString(name)
	b.WriteString(`</title><style>
:root{color-scheme:light dark;--bg:#f5f5f7;--fg:#1d1d1f;--muted:#6e6e73;--bar:#e8e8ed}@media(prefers-color-scheme:dark){:root{--bg:#17171a;--fg:#f5f5f7;--muted:#a1a1a6;--bar:#242428}}
*{box-sizing:border-box}body{margin:0;height:100vh;display:flex;flex-direction:column;background:var(--bg);color:var(--fg);font:13px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}header{min-height:42px;display:flex;align-items:center;gap:12px;padding:7px 12px;background:var(--bar)}strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}span{color:var(--muted);white-space:nowrap}button{border:1px solid var(--muted);border-radius:6px;background:transparent;color:var(--fg);padding:3px 9px;cursor:pointer}main{flex:1;overflow:auto;display:grid;place-items:center}img{display:block;max-width:100%;max-height:100%;object-fit:contain}body.actual img{max-width:none;max-height:none}
</style></head><body><header><strong>`)
	b.WriteString(name)
	fmt.Fprintf(&b, `</strong><span>%d × %d</span><button type="button" id="fit">Fit</button><button type="button" id="actual">1:1</button></header><main><img alt="`, w, h)
	b.WriteString(name)
	b.WriteString(`" src="data:`)
	b.WriteString(mime)
	b.WriteString(";base64,")
	b.WriteString(base64.StdEncoding.EncodeToString(data))
	b.WriteString(`"><script>const img=document.querySelector('img');document.getElementById('fit').onclick=()=>document.body.classList.remove('actual');document.getElementById('actual').onclick=()=>document.body.classList.add('actual');</script></body></html>`)
	return b.String()
}
