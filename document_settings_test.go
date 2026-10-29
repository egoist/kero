package main

import (
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/settings"
)

func TestDocumentLinksSettingsToggle(t *testing.T) {
	a := testApp(t)
	a.ss.query = "open-document-links"
	tt := ui.NewTester(a.settingsView, 820, 640)
	tt.Frame()
	label := "Open document links in split panes"
	if !tt.HasText(label) {
		t.Fatalf("no searchable document-links toggle; texts %q", tt.Texts())
	}
	flip := func() {
		t.Helper()
		r, _ := tt.Find(label)
		d, ok := tt.Find("Local HTML and Markdown links open beside the terminal instead of in an external app. Off by default.")
		if !ok {
			t.Fatal("no setting description")
		}
		tt.ClickAt(752, (r.Y+d.Y+d.H)/2)
		for range 3 {
			tt.Frame()
		}
	}
	flip()
	if !a.set.OpenDocumentLinks || !settings.Load().OpenDocumentLinks {
		t.Fatal("turning on document previews did not persist")
	}
	tt.Advance(350 * time.Millisecond)
	tt.Frame()
	shot(t, tt, "document-link-settings")
	flip()
	if a.set.OpenDocumentLinks || settings.Load().OpenDocumentLinks {
		t.Fatal("turning off document previews did not persist")
	}
}
