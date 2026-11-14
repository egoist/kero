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

const markdownSample = "# Markdown Preview\n\nUnsaved **bold**, *emphasis* and ~~deleted~~. [Heading](#details)\n\n> A native, read-only preview.\n\n- [x] Current buffer\n- [ ] No image loading\n\n| Feature | Status |\n| --- | --- |\n| Tables | Supported |\n\n```go\nfunc main() { println(\"A long line stays inside the preview, without widening the entire viewer card\") }\n```\n\n![Image description](https://example.invalid/image.png)\n\n## Details\n\n<script>alert('not executed')</script>\n"

func TestMarkdownExtensions(t *testing.T) {
	for _, name := range []string{"a.md", "A.MD", "a.MarkDown", "/tmp/readme.markdown"} {
		if !(&fileView{path: name}).markdown() {
			t.Errorf("not markdown: %s", name)
		}
	}
	for _, name := range []string{"a.mdx", "a.txt", "a.md.go", "README", "image.svg"} {
		if (&fileView{path: name}).markdown() {
			t.Errorf("markdown: %s", name)
		}
	}
}

func TestMarkdownPreview(t *testing.T) {
	a := testApp(t)
	s := &a.st.Sessions[0]
	fv := &fileView{pane: "a", path: "/tmp/demo/README.MD", rel: "README.MD", fetched: time.Now()}
	showFileText(fv, markdownSample+strings.Repeat("\nParagraph.\n", 100))
	a.openView(s, sideFiles, fv)
	tt := ui.NewTester(a.view, 1280, 720)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	if fv.md.preview {
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
		if !fv.md.preview || !tt.HasText("Unsaved addition.") {
			t.Fatalf("missing preview: %q", tt.Texts())
		}
		if fv.st != st || fv.st.Buffer != buf || !buf.Modified() || buf.Version() != version {
			t.Fatal("toggle changed editor buffer")
		}
		if fv.md.options.LoadImage != nil {
			t.Fatal("images must not load")
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
	if !fv.md.preview || !tt.HasText("Fresh content.") {
		t.Fatal("mode or source lost after Changes")
	}
	// Another file with the same path owns its own source and mode.
	other := &fileView{pane: "b", path: fv.path, rel: fv.rel}
	showFileText(other, "# Other host\n")
	a.openView(s, sideFiles, other)
	tt.Frame()
	tt.Frame()
	if other.md.preview {
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
	fv := &fileView{pane: "a", path: "/tmp/readme.md", rel: "readme.md", fetched: time.Now(), hash: "original"}
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

func TestMarkdownToolbarStable(t *testing.T) {
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

func TestMarkdownRenameToTextEnablesWrap(t *testing.T) {
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
	if fv.markdown() {
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
	if !a.set.WrapLines || !fv.md.preview {
		t.Fatal("preview did not disable wrap after rename back")
	}
}

func TestMarkdownPreviewAppearance(t *testing.T) {
	for _, dark := range []bool{false, true} {
		a := testApp(t)
		fv := &fileView{pane: "a", path: "/tmp/README.md", rel: "README.md"}
		showFileText(fv, markdownSample)
		fv.md.preview = true
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
			tt := ui.NewTester(func(c *ui.Context) { ui.Column(c).Fill().Children(func() { a.markdownPreview(c, paletteFor(c), fv) }) }, 480, 720)
			start := time.Now()
			tt.Frame()
			first := time.Since(start)
			start = time.Now()
			tt.Frame()
			next := time.Since(start)
			t.Logf("%d bytes: first frame %v, unchanged frame %v", len(source), first, next)
			if fv.markdownSource() != source {
				t.Fatal("large document truncated")
			}
		})
	}
}
