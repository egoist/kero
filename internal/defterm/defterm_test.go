package defterm

import (
	"errors"
	"runtime"
	"testing"
)

// The types a shell script opens with, which Kero takes or gives back.
func TestTypes(t *testing.T) {
	want := []string{"com.apple.terminal.shell-script", "public.shell-script", "public.unix-executable"}
	if len(Types) != len(want) {
		t.Fatalf("Types = %q, want %q", Types, want)
	}
	for i, w := range want {
		if Types[i] != w {
			t.Errorf("Types[%d] = %q, want %q", i, Types[i], w)
		}
	}
}

// Where there are no LaunchServices, every call says so rather than
// pretend to have set anything.
func TestWithoutMacOS(t *testing.T) {
	if runtime.GOOS == "darwin" {
		t.Skip("LaunchServices are there")
	}
	if err := Set(); !errors.Is(err, ErrNotMacOS) {
		t.Errorf("Set: %v, want ErrNotMacOS", err)
	}
	if err := Restore(); !errors.Is(err, ErrNotMacOS) {
		t.Errorf("Restore: %v, want ErrNotMacOS", err)
	}
	if path, err := Status(); path != "" || !errors.Is(err, ErrNotMacOS) {
		t.Errorf("Status = %q, %v; want no path and ErrNotMacOS", path, err)
	}
}
