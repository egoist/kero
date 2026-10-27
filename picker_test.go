package main

import (
	"fmt"
	"testing"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

// The wheel scrolls the picker's folders away from the one chosen.
func TestPickerScrolls(t *testing.T) {
	a := testApp(t)
	tt := ui.NewTester(a.view, 1100, 900)
	l := &proto.FSList{Dir: "/home/me", Parent: "/home"}
	for i := range 60 {
		l.Entries = append(l.Entries, proto.FSEntry{Name: fmt.Sprintf("folder%02d", i), Dir: true})
	}
	a.picker = folderPicker{open: true, host: a.local(), list: l}
	tt.Frame()
	r, ok := tt.Find("folder03")
	if !ok {
		t.Fatalf("no folders shown; texts %q", tt.Texts())
	}
	tt.Scroll(r.X+20, r.Y, 0, 300)
	tt.Frame()
	tt.Frame()
	if y := a.picker.scroll.Y; y < 100 {
		t.Errorf("the wheel scrolled the folders to %g, want 300", y)
	}
	// The keys still bring the one they choose into view.
	for range 40 {
		tt.Key(0, ui.KeyDown)
		tt.Frame()
	}
	if y := a.picker.scroll.Y; y <= 300 {
		t.Errorf("choosing folder39 left the folders at %g", y)
	}
}
