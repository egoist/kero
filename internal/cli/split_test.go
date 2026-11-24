package cli

import (
	"errors"
	"testing"
)

// A split goes one way: --right, --down, --left and --up each say where
// the new pane goes, and several of them were silently taken as the last
// one (--right --down split down, --down --up split up). A command that
// takes contradictory flags refuses them — kero wait and kero diff do —
// and a split does now too.
func TestSplitTakesOneDirection(t *testing.T) {
	sock, got := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)
	for _, a := range [][]string{
		{"split", "s1", "--right", "--down", "--", "true"},
		{"split", "s1", "--down", "--up", "--", "true"},
		{"split", "s1", "--left", "--right", "--", "true"},
		{"split", "s1", "--up", "--left", "--down", "--", "true"},
	} {
		err := run(a, "")
		if !errors.Is(err, errUsage) {
			t.Errorf("kero %v: %v, want a usage error", a[1:], err)
		}
		// It did not go on to split the pane either.
		for _, m := range got() {
			if m == "split" {
				t.Errorf("kero %v: it called split anyway", a[1:])
			}
		}
	}
	// One direction alone is taken, as none is: --right is the split's
	// own answer then.
	for _, a := range [][]string{
		{"split", "s1", "--down", "--", "true"},
		{"split", "s1", "--left", "--", "true"},
		{"split", "s1", "--", "true"},
	} {
		if err := run(a, ""); err != nil {
			t.Errorf("kero %v: %v, want it taken", a[1:], err)
		}
		if calls := got(); len(calls) == 0 || calls[len(calls)-1] != "split" {
			t.Errorf("kero %v: called %v, want split last", a[1:], calls)
		}
	}
}
