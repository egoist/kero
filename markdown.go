package main

import (
	"fmt"
	"io"
	"strings"

	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"
	"github.com/egoist/mygo/ui/markdown"
	"github.com/egoist/mygo/ui/markdown/parser"
	"golang.org/x/net/html"

	"kero/locales"
)

// markdownPreview keeps native Markdown rendering state for one file.
type markdownPreview struct {
	options      *markdown.Options
	images       *markdownImages
	network      bool
	details      markdownDetailsView
	buffer       *editor.Buffer
	version      uint64
	source       string
	linkedImages bool
}

func (m *markdownPreview) text(b *editor.Buffer) string {
	if m.buffer != b || m.version != b.Version() {
		m.buffer, m.version, m.source = b, b.Version(), b.String()
		m.linkedImages = strings.Contains(m.source, "[![")
	}
	return m.source
}

func (m *markdownPreview) view(c *ui.Context, pal *palette, a *App, fv *fileView) {
	cl := a.hostOf(fv.pane).cl
	if m.options == nil || m.images == nil || m.images.base != fv.path ||
		m.images.client != cl || m.images.network != m.network {
		m.images = newMarkdownImages(fv.path, cl, m.network)
		m.options = &markdown.Options{LoadImage: m.images.load}
	}
	m.options.Theme = &markdown.Theme{
		FontSize: max(a.set.FontSize, 12), Text: pal.text, Muted: pal.textMuted,
		CodeFont: a.termFamily(),
	}
	services := c.Services()
	m.options.OnLink = func(dest string) { a.previewLink(fv, dest, services) }
	source := m.text(fv.st.Buffer)
	m.options.Block = nil
	if m.linkedImages {
		m.options.Block = m.imageLinks
	}
	m.details.setSource(source)
	if m.options.AnchorVersion != fv.anchorVersion || m.options.Anchor != fv.anchor {
		m.details.reveal(fv.anchor)
	}
	m.options.Anchor, m.options.AnchorVersion = fv.anchor, fv.anchorVersion
	rendered := m.details.render()
	m.options.HTML = func(c *ui.Context, raw string) {
		if detail := m.details.headers[strings.TrimSpace(raw)]; detail != nil {
			label := detail.label
			if label == "" {
				label = locales.MarkdownDetails()
			}
			wasOpen := detail.open
			ui.Collapsible(c.Key(detail), label, &detail.open, func() {})
			if wasOpen != detail.open {
				m.details.dirty = true
			}
			return
		}
		ui.Text(c, raw).Font(a.termFamily()).TextColor(pal.textMuted)
	}
	if len(m.details.roots) == 0 {
		m.options.HTML = nil
	}
	ui.Column(c.Key("markdown-preview")).Grow(1).FillWidth().MinHeight(0).Children(func() {
		if m.images.blocked.Load() {
			ui.Button(c.Key("load-network-images"), locales.MarkdownLoadNetworkImages()).
				Tooltip(locales.MarkdownNetworkImagesHint()).
				OnClick(func() { m.network = true })
		}
		if m.images.failed.Load() {
			ui.Row(c.Key("image-errors")).Gap(8).Children(func() {
				ui.Text(c, locales.MarkdownImagesFailed()).TextColor(pal.textMuted).Grow(1)
				ui.Button(c, locales.MarkdownReloadImages()).OnClick(func() { m.options = nil })
			})
		}
		ui.Scroll(c.Key(m)).Grow(1).FillWidth().MinHeight(0).MinWidth(0).
			Padding(16).Children(func() {
			copySource := func() {
				services.WriteClipboardData(transfer.New(transfer.NewItem(
					transfer.Bytes(transfer.Text, []byte(source)),
					transfer.Bytes(transfer.Markdown, []byte(source)),
				)))
			}
			hasDetails := len(m.details.roots) != 0
			// Own selection for transformed documents so neither the default
			// clipboard formats nor shortcuts expose disclosure placeholders.
			m.options.ShareSelection = hasDetails
			view := markdown.View(c.Key("document"), rendered, m.options).FillWidth().MinWidth(0)
			if hasDetails {
				view.Selectable().OnShortcut(ui.Cmd|ui.Shift, ui.KeyC, copySource)
				view.CopyData(func(parts []ui.SelectedText) transfer.Data {
					var text []string
					for _, p := range parts {
						runes := []rune(p.Text)
						text = append(text, string(runes[max(0, p.Start):min(len(runes), p.End)]))
					}
					return transfer.TextData(strings.Join(text, "\n\n"))
				})
				view.ContextMenu(func(menu *ui.Menu) {
					menu.EditItems()
					if menu.Item(locales.MarkdownCopySource()).Chosen() {
						copySource()
					}
				})
			}
		})
	})
}

// details are a small structural extension, not an HTML renderer. Only
// balanced details/summary blocks recognized as HTML by the Markdown
// parser are used; code fences, inline code and malformed HTML keep their
// ordinary rendering. The editable Buffer is never changed. Bodies still
// go through markdown.View.
type markdownDetails struct {
	start, body, close, end int
	label                   string
	open                    bool
	children                []*markdownDetails
}

type markdownDetailsView struct {
	source   string
	roots    []*markdownDetails
	headers  map[string]*markdownDetails
	rendered string
	dirty    bool
}

func parseMarkdownDetails(source string) []*markdownDetails {
	if !strings.Contains(strings.ToLower(source), "<details") {
		return nil
	}
	doc := parser.Parse(source)
	var roots, stack []*markdownDetails
	var summary *markdownDetails
	var label strings.Builder
	for i := 1; i < doc.Len(); i = doc.Block(i).Next {
		b := doc.Block(i)
		if b.Kind != parser.HTMLBlock {
			continue
		}
		z := html.NewTokenizer(strings.NewReader(source[b.Start:b.End]))
		pos := b.Start
		standalone := b.Start
		for {
			tt := z.Next()
			raw := z.Raw()
			start := pos
			pos += len(raw)
			if tt == html.ErrorToken {
				if z.Err() != io.EOF {
					return nil
				}
				break
			}
			if tt == html.TextToken && summary != nil {
				label.Write(z.Text())
				continue
			}
			if tt != html.StartTagToken && tt != html.EndTagToken && tt != html.SelfClosingTagToken {
				continue
			}
			tok := z.Token()
			switch {
			case tok.Data == "details" && tt == html.StartTagToken:
				if len(stack) == 0 && strings.TrimSpace(source[standalone:start]) != "" {
					continue
				}
				if summary != nil {
					return nil
				}
				if len(stack) >= 64 {
					return nil
				}
				n := &markdownDetails{start: start, body: pos}
				for _, attr := range tok.Attr {
					if attr.Key == "open" {
						n.open = true
					}
				}
				stack = append(stack, n)
			case tok.Data == "summary" && tt == html.StartTagToken && len(stack) > 0:
				n := stack[len(stack)-1]
				if n.label == "" && strings.TrimSpace(source[n.body:start]) == "" {
					summary = n
					label.Reset()
				}
			case tok.Data == "summary" && tt == html.EndTagToken && summary != nil:
				summary.label = strings.TrimSpace(label.String())
				summary.body = pos
				summary = nil
			case tok.Data == "details" && tt == html.EndTagToken && len(stack) > 0:
				n := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				n.close, n.end = start, pos
				if summary == n || n.body > n.close {
					return nil
				}
				for _, child := range n.children {
					if child.start < n.body || child.end > n.close {
						return nil
					}
				}
				if len(stack) == 0 {
					roots = append(roots, n)
					standalone = pos
				} else {
					parent := stack[len(stack)-1]
					parent.children = append(parent.children, n)
				}
			}
		}
	}
	return roots
}

func (v *markdownDetailsView) setSource(source string) {
	if v.source == source {
		return
	}
	old := make(map[string]bool)
	var remember func([]*markdownDetails)
	remember = func(nodes []*markdownDetails) {
		for _, n := range nodes {
			old[fmt.Sprintf("%d:%s", n.start, n.label)] = n.open
			remember(n.children)
		}
	}
	remember(v.roots)
	v.source = source
	v.roots = parseMarkdownDetails(source)
	var restore func([]*markdownDetails)
	restore = func(nodes []*markdownDetails) {
		for _, n := range nodes {
			if open, ok := old[fmt.Sprintf("%d:%s", n.start, n.label)]; ok {
				n.open = open
			}
			restore(n.children)
		}
	}
	restore(v.roots)
	v.dirty = true
}

func (v *markdownDetailsView) render() string {
	if !v.dirty {
		return v.rendered
	}
	if len(v.roots) == 0 {
		v.headers = nil
		v.rendered, v.dirty = v.source, false
		return v.source
	}
	v.headers = make(map[string]*markdownDetails)
	prefix := "<!-- kero-details:"
	for strings.Contains(v.source, prefix) {
		prefix += "-"
	}
	var out strings.Builder
	var appendRange func(int, int, []*markdownDetails)
	appendRange = func(start, end int, nodes []*markdownDetails) {
		for _, n := range nodes {
			out.WriteString(v.source[start:n.start])
			// A block HTML comment is consumed by our HTML callback. No
			// arbitrary document HTML is executed or passed to a browser.
			marker := fmt.Sprintf("%s%d -->", prefix, n.start)
			v.headers[marker] = n
			out.WriteString("\n\n" + marker + "\n\n")
			if n.open {
				appendRange(n.body, n.close, n.children)
			}
			out.WriteString("\n\n")
			start = n.end
		}
		out.WriteString(v.source[start:end])
	}
	appendRange(0, len(v.source), v.roots)
	v.rendered, v.dirty = out.String(), false
	return v.rendered
}

// Opening a heading inside a closed disclosure first exposes its ancestors.
func (v *markdownDetailsView) reveal(anchor string) {
	if anchor == "" || len(v.roots) == 0 {
		return
	}
	var walk func([]*markdownDetails) bool
	walk = func(nodes []*markdownDetails) bool {
		found := false
		for _, n := range nodes {
			match := walk(n.children)
			d := parser.Parse(v.source[n.body:n.close])
			for i := 1; i < d.Len(); i++ {
				if d.Block(i).Kind == parser.Heading &&
					markdown.Slug(parser.PlainText(d.Inlines(i))) == strings.TrimPrefix(anchor, "#") {
					match = true
					break
				}
			}
			if match {
				n.open = true
				v.dirty = true
				found = true
			}
		}
		return found
	}
	walk(v.roots)
}
