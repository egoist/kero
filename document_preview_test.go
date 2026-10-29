package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

func TestMarkdownPreviewReportsReadErrors(t *testing.T) {
	for _, tc := range []struct {
		name string
		data []byte
		want string
	}{
		{"missing", nil, "missing.md"},
		{"too-large", make([]byte, 4*1024*1024+1), "4 MB preview limit"},
		{"binary", []byte{'x', 0, 'y'}, "not a UTF-8 text document"},
		{"invalid-utf8", []byte{0xff, 0xfe}, "not a UTF-8 text document"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := testApp(t)
			a.set.OpenDocumentLinks = true
			path := filepath.Join(t.TempDir(), tc.name+".md")
			if tc.data != nil {
				if err := os.WriteFile(path, tc.data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			a.st.Sessions[0].Panes[1].URL = testDocumentURL(path)
			tt := ui.NewTester(a.view, 1400, 900)
			deadline := time.Now().Add(2 * time.Second)
			for (!tt.HasText("Can’t show the page") || !tt.HasText(tc.want)) && time.Now().Before(deadline) {
				tt.Frame()
				time.Sleep(time.Millisecond)
			}
			if !tt.HasText("Can’t show the page") || !tt.HasText(tc.want) {
				t.Fatalf("missing document error; texts %q", tt.Texts())
			}
		})
	}
}

func TestMarkdownPreviewReloadsWithoutRunningHTML(t *testing.T) {
	a := testApp(t)
	a.set.OpenDocumentLinks = true
	path := filepath.Join(t.TempDir(), "unsafe.md")
	if err := os.WriteFile(path, []byte("# Original\n\n<script>document.title='executed'</script>\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	a.st.Sessions[0].Panes[1].URL = testDocumentURL(path)
	tt := ui.NewTester(a.view, 1400, 900)
	deadline := time.Now().Add(2 * time.Second)
	for !tt.HasText("Original") && time.Now().Before(deadline) {
		tt.Frame()
		time.Sleep(time.Millisecond)
	}
	if !tt.HasText("<script>document.title='executed'</script>") {
		t.Fatalf("embedded HTML should remain text; texts %q", tt.Texts())
	}
	if err := os.WriteFile(path, []byte("# Updated after reload\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := tt.Click("Reload"); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(2 * time.Second)
	for !tt.HasText("Updated after reload") && time.Now().Before(deadline) {
		tt.Frame()
		time.Sleep(time.Millisecond)
	}
	if !tt.HasText("Updated after reload") || tt.HasText("Original") {
		t.Fatalf("reload did not replace the document; texts %q", tt.Texts())
	}
}

func TestMarkdownDocumentPreview(t *testing.T) {
	a := testApp(t)
	a.set.OpenDocumentLinks = true
	path := filepath.Join(t.TempDir(), "reading.md")
	if err := os.WriteFile(path, []byte("# Reading concepts\n\nA **readable** document.\n\n- Read\n- Listen\n\n```go\nfmt.Println(42)\n```\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	a.st.Sessions[0].Panes[1].URL = testDocumentURL(path)
	tt := ui.NewTester(a.view, 1400, 900)
	deadline := time.Now().Add(2 * time.Second)
	for !tt.HasText("Reading concepts") && time.Now().Before(deadline) {
		tt.Frame()
		time.Sleep(time.Millisecond)
	}
	if !tt.HasText("Reading concepts") || tt.HasText("# Reading concepts") || !tt.HasText("readable") || !tt.HasText("fmt.Println(42)") {
		t.Fatalf("no rendered Markdown document; texts %q", tt.Texts())
	}
	shot(t, tt, "markdown-document-preview")
}
