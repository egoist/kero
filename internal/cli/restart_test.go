package cli

import (
	"errors"
	"testing"
)

// A restart starts the pane's shell again and keeps everything else, so
// it takes none of a close's flags: --remove-worktree was answered with
// while the worktree stayed, and --force did nothing at all, and neither
// said a word about it. A browser command refuses a flag that is another
// one's ("-o is screenshot's"), as these do now.
func TestRestartTakesNoneOfClosesFlags(t *testing.T) {
	sock, got := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)
	for _, a := range [][]string{
		{"restart", "s1", "--remove-worktree"},
		{"restart", "s1", "--force"},
	} {
		err := run(a, "")
		if !errors.Is(err, errUsage) {
			t.Errorf("kero %v: %v, want a usage error", a[1:], err)
		}
		// It did not go on to restart the pane either.
		for _, m := range got() {
			if m == "restart" {
				t.Errorf("kero %v: it called restart anyway", a[1:])
			}
		}
	}
	// A restart with neither is as it was.
	if err := run([]string{"restart", "s1"}, ""); err != nil {
		t.Errorf("kero restart s1: %v, want it taken", err)
	}
	if calls := got(); len(calls) == 0 || calls[len(calls)-1] != "restart" {
		t.Errorf("kero restart s1: called %v, want restart last", calls)
	}
	// A close keeps its flags, which a restart refuses: the refusal is
	// restart's alone, and it is a usage error (exit 2) either way.
	if err := run([]string{"close", "s1", "--remove-worktree"}, ""); err == nil {
		t.Errorf("kero close --remove-worktree: no error, want the worktree one")
	} else if errors.Is(err, errUsage) {
		t.Errorf("kero close --remove-worktree: %v, a usage error, want the session's own answer", err)
	}
	if calls := got(); len(calls) == 0 || calls[len(calls)-1] != "state" {
		t.Errorf("kero close --remove-worktree: called %v, want it to go on to the daemon", calls)
	}
}
