package cli

import (
	"errors"
	"path/filepath"
	"testing"

	"kero/internal/proto"
)

// notifyState is a state with two sessions, of a pane each.
func notifyState() proto.State {
	return proto.State{
		Sessions: []proto.Session{
			{ID: "s1", Name: "api", Panes: []proto.Pane{{ID: "p1"}}, Focus: "p1"},
			{ID: "s2", Name: "web", Panes: []proto.Pane{{ID: "p2"}}, Focus: "p2"},
		},
	}
}

// notifyFlags parses the arguments of a notify, as the command does.
func notifyFlags(t *testing.T, args ...string) *flags {
	t.Helper()
	f, err := parse(args, map[string]string{"session": "target", "s": "target", "title": "title"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

// A notification goes to the pane it names, and carries the rest of the
// words: the target the help promises is read.
func TestNotifyTarget(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	st := notifyState()
	for _, tc := range []struct {
		name string
		args []string
		// pane: the pane the command runs in, "" outside kero.
		pane  string
		want  string // the pane or session the notification is for
		body  string // the message it carries
		usage bool   // it is a usage error
	}{
		{"the pane it runs in", []string{"Need your input"}, "p1", "p1", "Need your input", false},
		{"a session it names", []string{"api", "Need your input"}, "p1", "s1", "Need your input", false},
		{"a pane it names", []string{"p2", "Need your input"}, "p1", "p2", "Need your input", false},
		{"a word naming no session", []string{"hello", "world"}, "p1", "p1", "hello world", false},
		{"a target given", []string{"--session", "web", "Need your input"}, "p1", "s2", "Need your input", false},
		{"a target given, a word too", []string{"--session", "web", "hello", "world"}, "p1", "s2", "hello world", false},
		{"no target outside kero", []string{"Need your input"}, "", "", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("KERO_PANE", tc.pane)
			t.Setenv("KERO_SESSION", "")
			tg, body, err := notifyTarget(st, notifyFlags(t, tc.args...))
			if tc.usage {
				if !errors.Is(err, errUsage) {
					t.Fatalf("%v, want a usage error", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if tg.ref() != tc.want {
				t.Errorf("the notification is for %q, want %q", tg.ref(), tc.want)
			}
			if body != tc.body {
				t.Errorf("the message is %q, want %q", body, tc.body)
			}
		})
	}
}
