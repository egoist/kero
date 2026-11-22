package cli

import (
	"errors"
	"testing"
)

// A boolean flag with a value is the value: --json=false was --json.
func TestBooleanFlagWithAValue(t *testing.T) {
	boolean := map[string]string{"json": "json", "j": "json"}
	valued := map[string]string{"n": "count"}
	for _, args := range [][]string{
		{"--json=false"}, {"--json=0"}, {"--json=f"},
	} {
		f, err := parse(args, valued, boolean)
		if err != nil {
			t.Fatal(args, err)
		}
		if f.set["json"] {
			t.Errorf("%v: json set", args)
		}
	}
	for _, args := range [][]string{
		{"--json"}, {"-j"}, {"--json=true"}, {"--json=1"}, {"--json=t"},
	} {
		f, err := parse(args, valued, boolean)
		if err != nil {
			t.Fatal(args, err)
		}
		if !f.set["json"] {
			t.Errorf("%v: json not set", args)
		}
	}
	if _, err := parse([]string{"--json=maybe"}, valued, boolean); !errors.Is(err, errUsage) {
		t.Errorf("--json=maybe: %v, want a usage error", err)
	}
}
