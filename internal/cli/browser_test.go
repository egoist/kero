package cli

import (
	"errors"
	"path/filepath"
	"testing"

	"kero/internal/proto"
)

// kero browser drives a browser pane: the one named, or a session's,
// which with no target is the session the command runs in, though its
// pane is the terminal it runs in.
func TestBrowserTarget(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	st := proto.State{Sessions: []proto.Session{
		{ID: "s1", Focus: "t1", Panes: []proto.Pane{{ID: "t1"}, {ID: "b1", URL: "http://localhost:3000"}}},
		{ID: "s2", Focus: "b3", Panes: []proto.Pane{{ID: "b2", URL: "https://kero.sh"}, {ID: "b3", URL: "https://go.dev"}}},
		{ID: "s3", Focus: "t3", Panes: []proto.Pane{{ID: "t3"}, {ID: "b4", URL: "https://a.dev"}, {ID: "b5", URL: "https://b.dev"}}},
		{ID: "s4", Focus: "t4", Panes: []proto.Pane{{ID: "t4"}}},
	}}
	for _, tc := range []struct {
		ref, want string
		err       error
	}{
		{"s1", "b1", nil},       // its one browser, though a terminal has the focus
		{"b1", "b1", nil},       // a pane named
		{"s2", "b3", nil},       // the focused browser of several
		{"b2", "b2", nil},       // the other, named
		{"s3", "", errNotFound}, // several, none focused: name one
		{"s4", "", errNotFound}, // none
		{"t1", "", errNotFound}, // a terminal named
	} {
		tg, err := find(st, tc.ref)
		if err != nil {
			t.Fatal(err)
		}
		got, err := browserOf(tg)
		if got != tc.want || !errors.Is(err, tc.err) {
			t.Errorf("%s: %q, %v; want %q, %v", tc.ref, got, err, tc.want, tc.err)
		}
	}

	// Run in a terminal pane, a command names no target: its session's
	// browser is meant. Bad usage is found before kerod is asked.
	t.Setenv("KERO_SESSION", "s1")
	t.Setenv("KERO_PANE", "t1")
	for _, args := range [][]string{
		{},
		{"s1"},
		{"bogus"},
		{"click"},
		{"type"},
		{"open"},
		{"text", "h1", "h2"},
		{"reload", "now"},
		{"text", "-o", "x.png"},
		{"click", "a", "--enter"},
		{"s1", "eval"},
	} {
		err := browserCmd(nil, st, args)
		if !errors.Is(err, errUsage) && !(len(args) == 1 && args[0] == "bogus" && errors.Is(err, errNotFound)) {
			t.Errorf("kero browser %q: %v", args, err)
		}
	}
	t.Setenv("KERO_SESSION", "s4")
	t.Setenv("KERO_PANE", "t4")
	if err := browserCmd(nil, st, []string{"text"}); !errors.Is(err, errNotFound) {
		t.Errorf("a session with no browser: %v", err)
	}
}
