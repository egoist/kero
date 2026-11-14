package main

import (
	"path"
	"strings"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"
	"github.com/egoist/mygo/ui/markdown"
	"kero/locales"
)

// The editor owns the buffer, selection, undo history and scroll position,
// even while its view is absent. Only the presentation changes.
type fileMarkdown struct {
	preview bool
	editor  ui.Handle
	options markdown.Options
	buffer  *editor.Buffer
	version uint64
	source  string
}

func (fv *fileView) markdown() bool {
	switch strings.ToLower(path.Ext(fv.path)) {
	case ".md", ".markdown":
		return true
	}
	return false
}

func (fv *fileView) markdownSource() string {
	m, b := &fv.md, fv.st.Buffer
	if m.buffer != b || m.version != b.Version() {
		m.buffer, m.version, m.source = b, b.Version(), b.String()
	}
	return m.source
}

func (a *App) markdownButtons(c *ui.Context, pal *palette, fv *fileView) {
	ui.Row(c.Key("markdown-mode")).Gap(2).Shrink(0).Children(func() {
		for i, label := range []string{locales.ViewerSource(), locales.ViewerPreview()} {
			preview := i == 1
			b := ui.ButtonBase(c.Key(label)).Height(26).Padding(0, 7).Radius(6).Label(label).TextColor(pal.textMuted)
			if fv.md.preview == preview {
				b.Background(pal.chip).TextColor(pal.text)
			}
			b.Children(func() { ui.Text(c, label).FontSize(12).SingleLine() })
			b.OnClick(func() {
				fv.md.preview = preview
				if !preview {
					fv.md.editor.Focus(c)
				}
			})
		}
	})
}

func (a *App) markdownPreview(c *ui.Context, pal *palette, fv *fileView) {
	m := &fv.md
	m.options.Theme = &markdown.Theme{
		FontSize: max(a.set.FontSize, 12), Text: pal.text, Muted: pal.textMuted,
		CodeFont: a.termFamily(),
	}
	// No LoadImage, HTML or math renderer: images remain descriptions and
	// documents cannot fetch resources or execute HTML. Without a router,
	// MyGo opens only safe external links and handles heading anchors itself.
	ui.Scroll(c.Key(&fv.md)).Grow(1).FillWidth().MinHeight(0).MinWidth(0).Padding(16).Children(func() {
		markdown.View(c.Key("document"), fv.markdownSource(), &m.options).FillWidth().MinWidth(0)
	})
}
