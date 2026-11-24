package cli

import (
	"errors"
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
