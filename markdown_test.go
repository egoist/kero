package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/proto"
)

const markdownSample = "# Markdown Preview\n\n" +
	"Unsaved **bold**, *emphasis* and ~~deleted~~. [Heading](#details)\n\n" +
	"> A native, read-only preview.\n\n" +
	"- [x] Current buffer\n- [ ] No image loading\n\n" +
	"| Feature | Status |\n| --- | --- |\n| Tables | Supported |\n\n" +
	"```go\nfunc main() { println(\"A long line stays inside the preview, " +
	"without widening the entire viewer card\") }\n```\n\n" +
	"![Image description](https://example.invalid/image.png)\n\n" +
	"## Details\n\n<script>alert('not executed')</script>\n"

func TestFilePreviewExtensions(t *testing.T) {
	for _, name := range []string{"a.md", "A.MD", "a.MarkDown", "/tmp/readme.markdown"} {
		if (&fileView{path: name}).previewer() == nil {
			t.Errorf("not markdown: %s", name)
		}
	}
	for _, name := range []string{"a.mdx", "a.txt", "a.md.go", "README", "image.svg"} {
		if (&fileView{path: name}).previewer() != nil {
			t.Errorf("markdown: %s", name)
		}
	}
}

func TestFilePreviewLifetime(t *testing.T) {
	fv := &fileView{path: "/repo/readme.md", preview: true}
	first := fv.previewer()
	m, ok := first.(*markdownPreview)
	if !ok {
		t.Fatalf("wrong preview type: %T", first)
	}
	m.network = true
	m.details.setSource("<details><summary>More</summary>body</details>")
	m.details.roots[0].open = true
	for _, name := range []string{"readme.md", "README.MARKDOWN", "other.md"} {
		fv.path = "/repo/" + name
		if fv.previewer() != first {
			t.Fatal("a frame or same-format rename replaced the renderer")
		}
	}
	fv.path = "/repo/readme.txt"
	if fv.previewer() != nil || fv.renderer != first || !fv.preview {
		t.Fatal("unsupported extension either exposed or discarded the preview")
	}
	fv.path = "/repo/readme.md"
	if fv.previewer() != first || !m.network || !m.details.roots[0].open {
		t.Fatal("rename back lost preview state")
	}
	other := &fileView{pane: "other-host", path: fv.path}
	next := other.previewer().(*markdownPreview)
	if next == m || other.preview || next.network || len(next.details.roots) != 0 {
		t.Fatal("preview state leaked between file objects")
	}
}

func TestMarkdownPreviewCache(t *testing.T) {
	a := testApp(t)
	fv := &fileView{path: "/repo/readme.md"}
	showFileText(fv, "# Original\n")
	m := fv.previewer().(*markdownPreview)
	tt := ui.NewTester(func(c *ui.Context) {
		ui.Column(c).Fill().Children(func() {
			fv.previewer().view(c, paletteFor(c), a, fv)
		})
	}, 480, 720)
	options, images := m.options, m.images
	for i := 0; i < 3; i++ {
		tt.Frame()
		if fv.previewer() != m || m.options != options || m.images != images {
			t.Fatal("unchanged frame replaced preview caches")
		}
	}
	// Buffer identity matters even when its version has not changed.
	version := fv.st.Buffer.Version()
	fv.st.Buffer = editor.NewBuffer("# Replacement\n")
	if fv.st.Buffer.Version() != version {
		t.Fatal("replacement must have the same version for this check")
	}
	tt.Frame()
	if !tt.HasText("Replacement") || tt.HasText("Original") {
		t.Fatal("preview kept the previous buffer's text")
	}
	fv.st.Buffer.Edit(editor.Edit{Start: 0, End: 0, Text: "Unsaved\n\n"})
	tt.Frame()
	if !tt.HasText("Unsaved") || m.options != options || m.images != images {
		t.Fatal("edit lost content or replaced unrelated image caches")
	}
	fv.path = "/moved/readme.markdown"
	tt.Frame()
	if fv.previewer() != m || m.images == images || m.options == options ||
		m.images.base != fv.path || images.base != "/repo/readme.md" {
		t.Fatal("rename did not replace only the path-dependent image loader")
	}
	images = m.images
	m.network = true
	tt.Frame()
	if m.images == images || !m.images.network || images.network {
		t.Fatal("consent did not create an independent loader")
	}
}

func TestMarkdownPreview(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	fv := &fileView{pane: "a", path: "/tmp/demo/README.MD", rel: "README.MD", fetched: time.Now()}
	showFileText(fv, markdownSample+strings.Repeat("\nParagraph.\n", 100))
	m := fv.previewer().(*markdownPreview)
	a.openView(s, sideFiles, fv)
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	if fv.preview {
		t.Fatal("must open in edit mode")
	}
	st, buf := fv.st, fv.st.Buffer
	buf.Edit(editor.Edit{Start: 0, End: 0, Text: "Unsaved addition.\n\n"})
	st.Select(10, 15)
	st.SetScrollY(300)
	tt.Frame()
	selection, scroll := st.Selection(), st.ScrollY()
	version := buf.Version()
	for i := 0; i < 3; i++ {
		if err := tt.Click("Preview"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Frame()
		if fv.previewer() != m {
			t.Fatal("mode switch replaced the renderer")
		}
		if !fv.preview || !tt.HasText("Unsaved addition.") {
			t.Fatalf("missing preview: %q", tt.Texts())
		}
		if fv.st != st || fv.st.Buffer != buf || !buf.Modified() || buf.Version() != version {
			t.Fatal("toggle changed editor buffer")
		}
		if m.options.LoadImage == nil || m.network {
			t.Fatal("local images must load without granting network permission")
		}
		if err := tt.Click("Source"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Frame()
		if st.Selection() != selection || st.ScrollY() != scroll {
			t.Fatalf("lost editor position: %v/%v, %v/%v", st.Selection(), selection, st.ScrollY(), scroll)
		}
		if !st.Focused() {
			t.Fatal("returning to edit did not focus editor")
		}
	}
	if !buf.Undo() || strings.HasPrefix(buf.String(), "Unsaved addition") {
		t.Fatal("undo history lost")
	}
	// An existing reload updates the preview, not a second read path.
	showFileText(fv, "# Reloaded\n\nFresh content.\n")
	tt.Click("Preview")
	tt.Frame()
	if !tt.HasText("Fresh content.") || buf.Modified() {
		t.Fatal("preview did not follow reload")
	}
	// Temporarily showing Changes must not discard this file's mode.
	v := a.viewOf(s)
	v.kind = sideChanges
	tt.Frame()
	tt.Frame()
	v.kind = sideFiles
	tt.Frame()
	if !fv.preview || !tt.HasText("Fresh content.") {
		t.Fatal("mode or source lost after Changes")
	}
	// Another file with the same path owns its own source and mode.
	other := &fileView{pane: "b", path: fv.path, rel: fv.rel}
	showFileText(other, "# Other host\n")
	a.openView(s, sideFiles, other)
	tt.Frame()
	tt.Frame()
	if other.preview {
		t.Fatal("mode leaked between file objects")
	}
	tt.Click("Preview")
	tt.Frame()
	if !tt.HasText("Other host") || tt.HasText("Fresh content.") {
		t.Fatal("source leaked between files")
	}
}

func TestMarkdownPreviewSave(t *testing.T) {
	a := testApp(t)
	fv := &fileView{
		pane: "a", path: "/tmp/readme.md", rel: "readme.md",
		fetched: time.Now(), hash: "original",
	}
	showFileText(fv, "# Saved\r\n")
	a.openView(&a.st.Sessions[0], sideFiles, fv)
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	writes := make(chan proto.FSWriteParams, 4)
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method != "fs.write" {
			return nil, fmt.Errorf("unexpected %s", method)
		}
		var p proto.FSWriteParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		writes <- p
		return "saved", nil
	})
	defer stop()
	a.local().cl = cl
	fv.st.Buffer.Edit(editor.Edit{Start: 0, End: 0, Text: "Unsaved\n"})
	tt.Frame()
	tt.Click("Preview")
	tt.Frame()
	tt.Frame()
	select {
	case <-writes:
		t.Fatal("toggle saved file")
	default:
	}
	tt.Key(ui.Cmd, ui.KeyS)
	select {
	case p := <-writes:
		if p.Text != "Unsaved\r\n# Saved\r\n" || p.Hash != "original" {
			t.Fatalf("incorrect save: %+v", p)
		}
	case <-time.After(time.Second):
		t.Fatal("save shortcut did not reach viewer from preview")
	}
	fv.edits.saving = false
	a.local().cl = nil
	a.askOverwrite(a.fileTarget(fv), func(bool) {})
	tt.Frame()
	if !tt.HasText("“readme.md” changed on disk") {
		t.Fatal("preview bypassed save conflict confirmation")
	}
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	a.closeView(&a.st.Sessions[0])
	tt.Frame()
	if a.confirm == nil || a.viewOf(&a.st.Sessions[0]) == nil {
		t.Fatal("preview bypassed unsaved confirmation")
	}
}

func TestFilePreviewToolbarStable(t *testing.T) {
	for _, width := range []int{320, 480, 800} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			a := testApp(t)
			fv := &fileView{pane: "a", path: "/tmp/README.md", rel: "README.md"}
			showFileText(fv, markdownSample)
			tt := ui.NewTester(func(c *ui.Context) {
				ui.Column(c).Fill().Children(func() { a.fileViewer(c, paletteFor(c), &a.st.Sessions[0], fv) })
			}, width, 800)
			tt.Frame()
			tt.Frame()
			positions := map[string]ui.Rect{}
			for _, label := range []string{"Source", "Preview", "Wrap Lines", "Open File", "Close"} {
				r, ok := tt.Find(label)
				if !ok {
					t.Fatalf("missing %q", label)
				}
				positions[label] = r
			}
			for i := 0; i < 3; i++ {
				for _, mode := range []string{"Preview", "Source"} {
					if err := tt.Click(mode); err != nil {
						t.Fatal(err)
					}
					tt.Frame()
					tt.Frame()
					for label, want := range positions {
						if got, ok := tt.Find(label); !ok || got != want {
							t.Fatalf("%s moved in %s: %v, want %v", label, mode, got, want)
						}
					}
					wrap, ok := tt.Find("Wrap Lines")
					if !ok {
						t.Fatalf("missing wrap control in %s", mode)
					}
					// Raw pointer input also exercises the disabled control.
					tt.Press(wrap.X+wrap.W/2, wrap.Y+wrap.H/2)
					tt.Release(wrap.X+wrap.W/2, wrap.Y+wrap.H/2)
					tt.Frame()
					if a.set.WrapLines != (mode == "Source") {
						t.Fatalf("wrap setting after click in %s: %v", mode, a.set.WrapLines)
					}
					if mode == "Source" {
						if err := tt.Click("Don't Wrap Lines"); err != nil {
							t.Fatal(err)
						}
						tt.Frame()
						if a.set.WrapLines {
							t.Fatal("wrap control did not reset")
						}
					}
					if i == 0 && width == 480 {
						shot(t, tt, "markdown-toolbar-"+mode)
					}
				}
			}
		})
	}
}

func TestFilePreviewRenameToTextEnablesWrap(t *testing.T) {
	a := testApp(t)
	fv := &fileView{pane: "a", path: "/tmp/README.md", rel: "README.md"}
	showFileText(fv, "# Title\n")
	a.openView(&a.st.Sessions[0], sideFiles, fv)
	tt := ui.NewTester(func(c *ui.Context) {
		ui.Column(c).Fill().Children(func() { a.fileViewer(c, paletteFor(c), &a.st.Sessions[0], fv) })
	}, 480, 800)
	tt.Frame()
	tt.Frame()
	if err := tt.Click("Preview"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	a.renamed(a.local(), "/tmp/README.md", "/tmp/README.txt", "README.md", "README.txt")
	tt.Frame()
	tt.Frame()
	if fv.previewer() != nil {
		t.Fatal("rename did not change extension")
	}
	if _, ok := tt.Find("Preview"); ok {
		t.Fatal("preview control shown for plain text")
	}
	if err := tt.Click("Wrap Lines"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !a.set.WrapLines {
		t.Fatal("wrap remains disabled after renaming Markdown to plain text")
	}
	// Renaming back restores this file's preview mode and disables wrap again.
	a.renamed(a.local(), "/tmp/README.txt", "/tmp/README.md", "README.txt", "README.md")
	tt.Frame()
	tt.Frame()
	r, ok := tt.Find("Don't Wrap Lines")
	if !ok {
		t.Fatal("wrap control missing after rename back")
	}
	tt.Press(r.X+r.W/2, r.Y+r.H/2)
	tt.Release(r.X+r.W/2, r.Y+r.H/2)
	tt.Frame()
	if !a.set.WrapLines || !fv.preview {
		t.Fatal("preview did not disable wrap after rename back")
	}
}

func TestMarkdownPreviewAppearance(t *testing.T) {
	for _, dark := range []bool{false, true} {
		a := testApp(t)
		fv := &fileView{pane: "a", path: "/tmp/README.md", rel: "README.md"}
		showFileText(fv, markdownSample)
		fv.preview = true
		tt := ui.NewTester(func(c *ui.Context) {
			ui.Column(c).Fill().Children(func() { a.fileViewer(c, paletteFor(c), &a.st.Sessions[0], fv) })
		}, 480, 800)
		tt.SetDark(dark)
		tt.Frame()
		tt.Frame()
		shot(t, tt, fmt.Sprintf("markdown-preview-dark-%t", dark))
	}
}

func TestMarkdownPreviewLarge(t *testing.T) {
	if testing.Short() {
		t.Skip("large document rendering")
	}
	for _, count := range []int{2500, maxView / 45} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			a := testApp(t)
			fv := &fileView{path: "large.md"}
			source := strings.Repeat("## Section\n\nA paragraph with **bold** text.\n\n", count)
			showFileText(fv, source)
			tt := ui.NewTester(func(c *ui.Context) {
				ui.Column(c).Fill().Children(func() {
					fv.previewer().view(c, paletteFor(c), a, fv)
				})
			}, 480, 720)
			start := time.Now()
			tt.Frame()
			first := time.Since(start)
			start = time.Now()
			tt.Frame()
			next := time.Since(start)
			t.Logf("%d bytes: first frame %v, unchanged frame %v", len(source), first, next)
			if fv.previewer().(*markdownPreview).text(fv.st.Buffer) != source {
				t.Fatal("large document truncated")
			}
		})
	}
}

func TestFilePreviewPaths(t *testing.T) {
	for _, tc := range []struct{ base, dest, file, anchor string }{
		{"/repo/docs/readme.md", "../images/a%20b.png", "/repo/images/a b.png", ""},
		{"C:/repo/docs/readme.md", "./other.md#%E6%A0%87%E9%A2%98", "C:/repo/docs/other.md", "标题"},
		{"/repo/readme.md", "#section", "/repo/readme.md", "section"},
		{"//server/share/docs/readme.md", "../image.png", "//server/share/image.png", ""},
		{"/repo/readme.md", "other.md?view=1#section", "/repo/other.md", "section"},
	} {
		file, anchor, err := previewPath(tc.base, tc.dest)
		if err != nil || file != tc.file || anchor != tc.anchor {
			t.Fatalf("%q: %q %q %v", tc.dest, file, anchor, err)
		}
	}
	for _, dest := range []string{
		"//evil/x", "/etc/passwd", "javascript:alert(1)", "file:///tmp/x",
		"data:image/png;base64,AA", "C:/x", "a%00.png", "..%5Cx", "http://x/a", "%zz",
	} {
		if _, _, err := previewPath("/repo/a.md", dest); err == nil {
			t.Errorf("accepted %q", dest)
		}
	}
}

func TestFilePreviewLinkNavigation(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	fv := &fileView{pane: "a", path: "/repo/docs/start.md", rel: "docs/start.md", fetched: time.Now()}
	showFileText(fv, "[Next](next.md#target)\n")
	fv.preview = true
	a.openView(s, sideFiles, fv)
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	fv.st.Buffer.Edit(editor.Edit{Start: 0, End: 0, Text: "Unsaved\n"})
	tt.Frame()
	if err := tt.Click("Next"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.confirm == nil || a.viewOf(s).file != fv {
		t.Fatal("navigation bypassed unsaved confirmation")
	}
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.viewOf(s).file != fv || !fv.st.Buffer.Modified() {
		t.Fatal("cancel lost edits")
	}
	fv.st.Buffer.MarkSaved()
	if err := tt.Click("Next"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	next := a.viewOf(s).file
	if next == fv || next.path != "/repo/docs/next.md" || next.rel != "docs/next.md" ||
		next.pane != "a" || !next.preview || next.anchor != "target" {
		t.Fatalf("bad navigation: %+v", next)
	}
	showFileText(next, "# Target\n\nArrived here.\n\n[Notes](notes.txt)\n")
	tt.Frame()
	if !tt.HasText("Arrived here.") {
		t.Fatal("target document not previewed")
	}
	r, ok := tt.Find("Notes")
	if !ok {
		t.Fatal("missing plain-text link")
	}
	// The selectable paragraph spans the width. Click its text, not the
	// empty center of that paragraph.
	tt.ClickAt(r.X+4, r.Y+r.H/2)
	tt.Frame()
	plain := a.viewOf(s).file
	if plain.path != "/repo/docs/notes.txt" || plain.preview || plain.previewer() != nil {
		t.Fatalf("plain-text target: %q, preview=%v", plain.path, plain.preview)
	}
	showFileText(plain, "Plain text\n")
	tt.Frame()
	if _, ok := tt.Find("Preview"); ok {
		t.Fatal("plain-text target shows preview controls")
	}
}

func TestMarkdownDetails(t *testing.T) {
	source := "# Before\n\n[Jump inside](#inside)\n\n" +
		"<details>\n<summary>More <b>information</b></summary>\n\n" +
		"Hidden **content**.\n\n## Inside\n\n" +
		"<details open><summary>Nested</summary>\n\nNested content.\n\n" +
		"</details>\n\n</details>\n\n# After\n"
	a := testApp(t)
	fv := &fileView{path: "/repo/a.md"}
	showFileText(fv, source)
	tt := ui.NewTester(func(c *ui.Context) {
		ui.Column(c).Fill().Children(func() {
			fv.previewer().view(c, paletteFor(c), a, fv)
		})
	}, 600, 800)
	tt.Frame()
	tt.Frame()
	if tt.HasText("Hidden content.") || !tt.HasText("Before") || !tt.HasText("After") {
		t.Fatalf("bad collapsed content: %v", tt.Texts())
	}
	if err := tt.Click("More information"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	tt.Frame()
	if !tt.HasText("Hidden content.") || !tt.HasText("Nested content.") {
		t.Fatalf("not expanded: %v", tt.Texts())
	}
	if err := tt.Click("More information"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	tt.Frame()
	if tt.HasText("Hidden content.") {
		t.Fatal("not collapsed")
	}
	for i := 0; i < 2; i++ {
		r, ok := tt.Find("Jump inside")
		if !ok {
			t.Fatal("missing anchor link")
		}
		// Hit the link text rather than its full-width paragraph's center.
		tt.ClickAt(r.X+4, r.Y+r.H/2)
		tt.Frame()
		tt.Frame()
		if !tt.HasText("Hidden content.") || fv.anchor != "inside" ||
			fv.anchorVersion != uint64(i+1) {
			t.Fatalf("anchor request %d: %q/%d; texts=%q", i, fv.anchor, fv.anchorVersion, tt.Texts())
		}
		if err := tt.Click("More information"); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		tt.Frame()
		if tt.HasText("Hidden content.") {
			t.Fatal("disclosure did not close between anchor requests")
		}
	}
	if fv.st.Buffer.String() != source || fv.st.Buffer.Modified() {
		t.Fatal("disclosure modified source")
	}
	// The explicit Markdown copy must not expose presentation placeholders.
	tt.Key(ui.Cmd|ui.Shift, ui.KeyC)
	if text := tt.Clipboard(); text != source {
		t.Fatalf("Markdown copy differs from original source: %q", text)
	}
}

func TestMarkdownDetailsEditing(t *testing.T) {
	var view markdownDetailsView
	view.setSource("<details><summary>Title</summary>\n\nBefore\n\n</details>")
	view.roots[0].open = true
	view.setSource("<details><summary>Title</summary>\n\nAfter\n\n</details>")
	if !view.roots[0].open {
		t.Fatal("content edit reset disclosure state")
	}
	view.render()
	view.setSource("No disclosure now.")
	if view.render() != "No disclosure now." || len(view.headers) != 0 {
		t.Fatal("stale disclosure state after edit")
	}
}

func TestMarkdownDetailsParsing(t *testing.T) {
	for _, source := range []string{
		"```html\n<details><summary>Example</summary>\ntext\n</details>\n```",
		"`<details><summary>Inline</summary></details>`",
		"<details>\n<summary>Unclosed</summary>\n\nDo not hide this.",
		"<details><summary><details>x</details></summary></details>",
		"<pre><details><summary>Literal</summary></details></pre>",
	} {
		if roots := parseMarkdownDetails(source); len(roots) != 0 {
			t.Errorf("unexpected disclosure in %q", source)
		}
		var view markdownDetailsView
		view.setSource(source)
		if view.render() != source {
			t.Errorf("changed literal or malformed HTML: %q", source)
		}
	}
	for _, source := range []string{
		"<details open><summary>A</summary>body</details>",
		"<DETAILS>\n<SUMMARY>A</SUMMARY>\n\nbody\n\n</DETAILS>",
	} {
		if roots := parseMarkdownDetails(source); len(roots) != 1 || roots[0].label != "A" {
			t.Errorf("missing disclosure in %q: %+v", source, roots)
		}
	}
}
