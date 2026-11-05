package main

import (
	"bytes"
	"testing"

	"github.com/egoist/mygo/ui"
)

// On a Mac, ⌘ and ⌥ with the arrows and ⌫ send what shells edit the line
// with, as Ghostty's keys do; other keys and modifiers send their own.
func TestMacKeySend(t *testing.T) {
	for _, c := range []struct {
		mods ui.Modifiers
		key  ui.Key
		want []byte
	}{
		{ui.Super, ui.KeyBackspace, []byte{0x15}},
		{ui.Super, ui.KeyLeft, []byte{0x01}},
		{ui.Super, ui.KeyRight, []byte{0x05}},
		{ui.Alt, ui.KeyLeft, []byte("\x1bb")},
		{ui.Alt, ui.KeyRight, []byte("\x1bf")},
		{ui.Alt | ui.Shift, ui.KeyLeft, nil},
		{ui.Alt, ui.KeyUp, nil},
		{ui.Alt, ui.KeyBackspace, nil},
		{0, ui.KeyLeft, nil},
		{ui.Super | ui.Alt, ui.KeyLeft, nil},
	} {
		if got := macKeySend(c.mods, c.key); !bytes.Equal(got, c.want) {
			t.Errorf("macKeySend(%v, %v) = %q, want %q", c.mods, c.key, got, c.want)
		}
	}
}
