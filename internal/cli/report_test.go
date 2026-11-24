package cli

import (
	"errors"
	"strings"
	"testing"
)

// A report's progress is a percentage of the work it is of: a value
// that is not one is a usage error, not a report that says nothing of
// the work — kerod drops it, silently.
func TestReportRefusesAProgressThatIsNoPercentage(t *testing.T) {
	for _, v := range []string{"abc", "999", "-1", "1.5", "40%"} {
		if err := run([]string{"report", "working", "Migrating", "--progress", v}, ""); !errors.Is(err, errUsage) {
			t.Errorf("--progress %q: %v, want a usage error", v, err)
		}
	}
	// A percentage is one.
	for _, v := range []string{"0", "40", "100"} {
		if p, err := parseProgress(v); err != nil || p < 0 || p > 100 {
			t.Errorf("--progress %q: %d, %v, want a percentage", v, p, err)
		}
	}
	if p, err := parseProgress(""); err != nil || p != 0 {
		t.Errorf("no progress: %d, %v, want none", p, err)
	}
}

// The rest of a report's values are checked by the rule kerod reads them
// with: an id that breaks it loses the whole report — the program's
// status, its message and all — and a kind, an app or a progress of the
// wrong state loses its own value, with nothing said where the report was
// written.
func TestReportRefusesTheValuesKerodDrops(t *testing.T) {
	// An id kerod drops the whole report for.
	for _, v := range []string{
		"a/b/c/d/e/f/g/h/i",      // nine segments
		strings.Repeat("a", 33),  // one segment of 33
		strings.Repeat("a", 128), // one segment of 128
		"a b",                    // a space
		"a:b",                    // the pair separator
		strings.Repeat("a", 16) + "/" + strings.Repeat("b", 112), // 129 in all
	} {
		if err := run([]string{"report", "working", "Migrating", "--id", v}, ""); !errors.Is(err, errUsage) {
			t.Errorf("--id %q: %v, want a usage error", v, err)
		}
	}
	// An id of eight segments, and of 128 characters in all, is one.
	for _, v := range []string{
		"turn", "a/b", strings.Repeat("a", 32),
		strings.Repeat("a", 16) + "/" + strings.Repeat("b", 16) + "/" + strings.Repeat("c", 16) + "/" +
			strings.Repeat("d", 16) + "/" + strings.Repeat("e", 16) + "/" + strings.Repeat("f", 16) + "/" +
			strings.Repeat("g", 16) + "/" + strings.Repeat("h", 9), // 128 in all
	} {
		if err := reportValues("working", map[string]string{"id": v}); err != nil {
			t.Errorf("--id %q: %v, want it taken", v, err)
		}
	}
	// A kind is one of the three, and of a report that is blocked.
	for _, v := range []string{"permission", "question", "auth"} {
		if err := reportValues("blocked", map[string]string{"kind": v}); err != nil {
			t.Errorf("--kind %q: %v, want it taken", v, err)
		}
	}
	for _, v := range []string{"Permission", "bogus", "permission "} {
		if err := run([]string{"report", "blocked", "Waiting", "--kind", v}, ""); !errors.Is(err, errUsage) {
			t.Errorf("--kind %q: %v, want a usage error", v, err)
		}
	}
	for _, s := range []string{"idle", "working", "done", "error", "clear"} {
		if err := run([]string{"report", s, "Working", "--kind", "permission"}, ""); !errors.Is(err, errUsage) {
			t.Errorf("--kind permission of a %s report: %v, want a usage error", s, err)
		}
	}
	// A progress is of a report that is working or blocked.
	for _, s := range []string{"working", "blocked"} {
		if err := reportValues(s, map[string]string{"progress": "40"}); err != nil {
			t.Errorf("--progress 40 of a %s report: %v, want it taken", s, err)
		}
	}
	for _, s := range []string{"idle", "done", "error", "clear"} {
		if err := run([]string{"report", s, "Working", "--progress", "40"}, ""); !errors.Is(err, errUsage) {
			t.Errorf("--progress 40 of a %s report: %v, want a usage error", s, err)
		}
	}
	// An app is at most 32 of the name's characters.
	if err := reportValues("working", map[string]string{"app": "claude-code_1.2+x"}); err != nil {
		t.Errorf("--app claude-code_1.2+x: %v, want it taken", err)
	}
	for _, v := range []string{strings.Repeat("a", 33), "claude code", "claude/code"} {
		if err := run([]string{"report", "working", "Migrating", "--app", v}, ""); !errors.Is(err, errUsage) {
			t.Errorf("--app %q: %v, want a usage error", v, err)
		}
	}
	// A report with none of them is as it was.
	if err := reportValues("working", map[string]string{}); err != nil {
		t.Errorf("a report with no values: %v, want it taken", err)
	}
}
