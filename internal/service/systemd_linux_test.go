package service

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeSystemctl puts a systemctl on the PATH that answers as asked, and
// fails what it is told to fail.
func fakeSystemctl(t *testing.T, fail string) {
	t.Helper()
	bin := t.TempDir()
	script := "#!/bin/sh\n" +
		"for a in \"$@\"; do\n" +
		"  if [ \"$a\" = \"" + fail + "\" ]; then exit 1; fi\n" +
		"done\n" +
		"exit 0\n"
	if err := os.WriteFile(filepath.Join(bin, "systemctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// oldUnit puts a unit that was there, and worked, in place.
func oldUnit(t *testing.T) string {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	old := "# the unit that was there\n"
	if err := os.MkdirAll(filepath.Dir(file()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file(), []byte(old), 0o644); err != nil {
		t.Fatal(err)
	}
	return old
}

// A failed install does not take away a service that worked: the unit
// that was there is kept.
func TestInstallKeepsTheUnitThatWasThere(t *testing.T) {
	old := oldUnit(t)
	fakeSystemctl(t, "restart")
	if err := Install("/usr/bin/kerod", nil); err == nil {
		t.Fatal("the install succeeded")
	}
	got, err := os.ReadFile(file())
	if err != nil {
		t.Fatalf("the unit is gone: %v", err)
	}
	if string(got) != old {
		t.Errorf("the unit = %q, want the one that was there", got)
	}
}

// A daemon that does not stop is not an install that worked: the unit
// that was there is kept, and the error says what happened.
func TestInstallKeepsTheUnitWhenTheDaemonDoesNotStop(t *testing.T) {
	old := oldUnit(t)
	fakeSystemctl(t, "")
	err := Install("/usr/bin/kerod", func() error { return errors.New("kerod did not stop") })
	if err == nil || !strings.Contains(err.Error(), "did not stop") {
		t.Fatalf("the install: %v", err)
	}
	got, err := os.ReadFile(file())
	if err != nil {
		t.Fatalf("the unit is gone: %v", err)
	}
	if string(got) != old {
		t.Errorf("the unit = %q, want the one that was there", got)
	}
}

// An install that fails takes away no unit of its own: there was none.
func TestInstallTakesNoUnitWhenThereWasNone(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	fakeSystemctl(t, "restart")
	if err := Install("/usr/bin/kerod", nil); err == nil {
		t.Fatal("the install succeeded")
	}
	if _, err := os.Stat(file()); err == nil {
		t.Error("the unit is there")
	}
}

// A service that systemd did not stop is not one that was uninstalled:
// the unit stays, and the error says what happened.
func TestUninstallKeepsTheUnitWhenSystemdDoesNotStopIt(t *testing.T) {
	oldUnit(t)
	fakeSystemctl(t, "disable")
	if err := Uninstall(); err == nil {
		t.Fatal("the uninstall succeeded")
	}
	if _, err := os.Stat(file()); err != nil {
		t.Fatalf("the unit is gone: %v", err)
	}
}
