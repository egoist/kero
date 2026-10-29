package main

import (
	"net/url"
	"path/filepath"
	"runtime"
	"strings"

	"kero/internal/proto"
)

// documentURL accepts only local file links and paths. In particular,
// file://server/... is not a path of this machine.
func (a *App) documentURL(id, link string) string {
	if a.hostOf(id).remote() {
		return ""
	}
	var u *url.URL
	var path string
	if strings.HasPrefix(strings.ToLower(link), "file:") {
		var err error
		u, err = url.Parse(link)
		if err != nil || u.User != nil || (u.Host != "" && !strings.EqualFold(u.Host, "localhost")) || u.Opaque != "" {
			return ""
		}
		path = documentFilePath(u.Path)
		if !filepath.IsAbs(path) {
			return ""
		}
	} else {
		parsed, err := url.Parse(lineSuffix.ReplaceAllString(link, ""))
		if err == nil && parsed.Scheme != "" && filepath.VolumeName(link) == "" || strings.HasPrefix(link, "//") || strings.HasPrefix(link, `\\`) {
			return ""
		}
		path = a.localPath(id, link)
	}
	if !filepath.IsAbs(path) || strings.HasPrefix(path, "//") || strings.HasPrefix(path, `\\`) {
		return ""
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".html", ".htm", ".md", ".markdown":
	default:
		return ""
	}
	if u == nil {
		u = &url.URL{Scheme: "file"}
	}
	urlPath := filepath.ToSlash(path)
	if runtime.GOOS == "windows" && filepath.VolumeName(path) != "" {
		urlPath = "/" + urlPath
	}
	u.Scheme, u.Host, u.Path, u.RawPath = "file", "", urlPath, ""
	return u.String()
}

// A Windows file URL has /C:/..., while its filesystem path has C:\\... .
func documentFilePath(path string) string {
	if runtime.GOOS == "windows" && len(path) >= 3 && path[0] == '/' && path[2] == ':' {
		path = path[1:]
	}
	return filepath.FromSlash(path)
}

func (a *App) openDocumentLink(id, link string) bool {
	if !a.set.OpenDocumentLinks {
		return false
	}
	u := a.documentURL(id, link)
	s := a.sessionOfPane(id)
	if u == "" || s == nil {
		return false
	}
	if _, pending := a.documentOpens[s.ID]; pending {
		a.documentOpens[s.ID] = u
		return true
	}
	for i := range s.Panes {
		p := &s.Panes[i]
		if p.Browser() && a.documentURL(p.ID, p.URL) != "" {
			e := a.ensureWeb(p)
			e.documentLinks = true
			e.load(u)
			a.tellPage(p.ID, e)
			a.setFocus(s, p.ID)
			return true
		}
	}
	if a.hostOf(id).cl == nil {
		return false
	}
	if a.documentOpens == nil {
		a.documentOpens = map[string]string{}
	}
	sid := s.ID
	a.documentOpens[sid] = u
	a.splitThen(s, proto.CreateParams{Split: id, Direction: "right", URL: u}, func(opened *proto.Session, err error) {
		latest := a.documentOpens[sid]
		delete(a.documentOpens, sid)
		if err == nil && opened != nil && latest != u {
			a.openDocumentLink(opened.Focus, latest)
		}
	})
	return true
}
