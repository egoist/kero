package main

import (
	"fmt"
	"net/url"
	"path"
	"strings"

	"github.com/egoist/mygo/ui"

	"kero/locales"
)

// filePreview presents a file's current editor buffer. The fileView owns
// editing, mode, focus and navigation; implementations keep only their
// rendering state. view runs on the UI thread, with no second file read.
type filePreview interface {
	view(c *ui.Context, pal *palette, a *App, fv *fileView)
}

// previewer selects by the current path, reusing this file's renderer.
// An unsupported extension hides the preview without losing its state,
// so renaming back restores it. A different format replaces the renderer.
func (fv *fileView) previewer() filePreview {
	switch strings.ToLower(path.Ext(fv.path)) {
	case ".md", ".markdown":
		if _, ok := fv.renderer.(*markdownPreview); !ok {
			fv.renderer = &markdownPreview{}
		}
		return fv.renderer
	}
	return nil
}

func (a *App) previewButtons(c *ui.Context, pal *palette, fv *fileView) {
	ui.Row(c.Key("file-mode")).Gap(2).Shrink(0).Children(func() {
		for i, label := range []string{locales.ViewerSource(), locales.ViewerPreview()} {
			preview := i == 1
			b := ui.ButtonBase(c.Key(label)).Height(26).Padding(0, 7).Radius(6).
				Label(label).TextColor(pal.textMuted)
			if fv.preview == preview {
				b.Background(pal.chip).TextColor(pal.text)
			}
			b.Children(func() { ui.Text(c, label).FontSize(12).SingleLine() })
			b.OnClick(func() {
				fv.preview = preview
				if !preview {
					fv.editor.Focus(c)
				}
			})
		}
	})
}

// previewPath resolves a URL path on the document's host, not the GUI's
// machine. Host paths use slashes even when that host runs Windows.
func previewPath(base, dest string) (file, anchor string, err error) {
	u, err := url.Parse(dest)
	if err != nil || u == nil {
		return "", "", fmt.Errorf("invalid document link")
	}
	if u.Scheme != "" || u.Host != "" || u.User != nil || u.Opaque != "" ||
		strings.HasPrefix(dest, "//") {
		return "", "", fmt.Errorf("not a relative document link")
	}
	if strings.ContainsAny(u.Path, "\\\x00") || strings.Contains(u.Path, ":") ||
		strings.ContainsRune(u.Fragment, 0) {
		return "", "", fmt.Errorf("invalid document path")
	}
	if u.Path == "" {
		return base, u.Fragment, nil
	}
	// Absolute paths can unexpectedly refer outside a project, particularly
	// for remote documents. Only document-relative paths are followed.
	if path.IsAbs(u.Path) {
		return "", "", fmt.Errorf("absolute document paths are not supported")
	}
	file = path.Join(path.Dir(base), u.Path)
	// Retain a Windows host's UNC root.
	if strings.HasPrefix(base, "//") {
		file = "/" + file
	}
	return file, u.Fragment, nil
}

func (a *App) previewLink(fv *fileView, dest string, services ui.Services) {
	if ui.SafeToOpen(dest) {
		services.OpenURL(dest)
		return
	}
	file, anchor, err := previewPath(fv.path, dest)
	if err != nil {
		a.toast(locales.ViewerLinkUnsupported())
		return
	}
	if file == fv.path {
		fv.anchor = anchor
		fv.anchorVersion++
		return
	}
	// Resolve the owning session by file identity: a callback from an old
	// document must not replace another file that the user has since opened.
	var sid string
	for id, v := range a.side.views {
		if v.file == fv && v.kind == sideFiles {
			sid = id
			break
		}
	}
	if sid == "" {
		return
	}
	var targets []editTarget
	if t := a.fileTarget(fv); t.dirty() {
		targets = append(targets, t)
	}
	a.askToSave(targets, func() {
		s := a.session(sid)
		if s == nil || a.viewOf(s) == nil || a.viewOf(s).file != fv {
			return
		}
		u, _ := url.Parse(dest)
		next := &fileView{pane: fv.pane, path: file, rel: path.Clean(path.Join(path.Dir(fv.rel), u.Path))}
		next.preview = next.previewer() != nil
		next.anchor = anchor
		a.openView(s, sideFiles, next)
		a.focusViewer()
	})
}
