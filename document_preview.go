package main

import (
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/markdown"

	"kero/locales"
)

const maxDocumentBytes = 4 << 20

type documentText struct {
	text string
	err  error
}

// A Markdown preview is native, not a web page: HTML blocks remain text,
// scripts cannot run, and images do not make network requests.
type markdownPreview struct {
	path string
	read <-chan documentText
	text string
	err  error
	md   markdown.Options
}

func markdownPath(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "file" || u.Host != "" || u.Opaque != "" {
		return ""
	}
	switch strings.ToLower(filepath.Ext(u.Path)) {
	case ".md", ".markdown":
		return documentFilePath(u.Path)
	}
	return ""
}

func newMarkdownPreview(path string) *markdownPreview {
	ch := make(chan documentText, 1)
	go func() {
		text, err := readDocument(path)
		ch <- documentText{text, err}
	}()
	return &markdownPreview{path: path, read: ch, md: markdown.Options{WrapCode: true}}
}

func readDocument(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return "", err
	}
	if !st.Mode().IsRegular() {
		return "", fmt.Errorf("%s is not a regular file", path)
	}
	b, err := io.ReadAll(io.LimitReader(f, maxDocumentBytes+1))
	if err != nil {
		return "", err
	}
	if len(b) > maxDocumentBytes {
		return "", fmt.Errorf("%s exceeds the 4 MB preview limit", path)
	}
	if !utf8.Valid(b) || strings.ContainsRune(string(b), '\x00') {
		return "", fmt.Errorf("%s is not a UTF-8 text document", path)
	}
	return string(b), nil
}

func (a *App) markdownDocument(c *ui.Context, pal *palette, d *markdownPreview) {
	if d.read != nil {
		select {
		case result := <-d.read:
			d.text, d.err, d.read = result.text, result.err, nil
		default:
			c.After(16 * time.Millisecond)
			ui.Text(c, filepath.Base(d.path)).FontSize(13).TextColor(pal.textMuted)
			return
		}
	}
	if d.err != nil {
		a.message(c, pal, locales.BrowserCantShow(), d.err.Error(), "", nil)
		return
	}
	ui.Scroll(c.Key("document-" + d.path)).Grow(1).MinHeight(0).Children(func() {
		markdown.View(c, d.text, &d.md).Padding(24).Grow(1).MinWidth(0)
	})
}
