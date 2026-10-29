package main

import (
	"strings"
	"testing"
)

func hasCJKFallbacks(family string) bool {
	for _, name := range []string{"NSimSun", "MS Gothic", "MingLiU", "GulimChe", "Sarasa Mono SC", "Noto Sans Mono CJK"} {
		if !strings.Contains(family, name) {
			return false
		}
	}
	return true
}

// An empty font-family, and a single Latin face such as JetBrains Mono,
// draw with monospaced CJK fallbacks Windows already ships, so Chinese
// in a TUI does not go to Microsoft YaHei.
func TestTermFamilyDefault(t *testing.T) {
	a := testApp(t)
	if got := a.termFamily(); got != defaultTermFamily {
		t.Errorf("empty font-family %q, want %q", got, defaultTermFamily)
	}
	if !strings.HasPrefix(defaultTermFamily, bundledFont+",") {
		t.Errorf("default stack %q should start with %q", defaultTermFamily, bundledFont)
	}
	if !hasCJKFallbacks(defaultTermFamily) {
		t.Errorf("default stack %q lacks Windows monospaced CJK fallbacks", defaultTermFamily)
	}

	a.set.FontFamily = "JetBrains Mono"
	if got := a.termFamily(); !strings.HasPrefix(got, "JetBrains Mono,") || !hasCJKFallbacks(got) {
		t.Errorf("JetBrains Mono %q, want that family then CJK monospaced fallbacks", got)
	}

	a.set.FontFamily = "Iosevka Term, Symbols Nerd Font"
	if got := a.termFamily(); got != "Iosevka Term, Symbols Nerd Font" {
		t.Errorf("a list the user wrote %q", got)
	}

	a.set.FontFamily = "monospace"
	if got := a.termFamily(); got != "monospace" {
		t.Errorf("System picked, terminal font %q", got)
	}
}
