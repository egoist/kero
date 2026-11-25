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

// A unit that is there but cannot be read is not "there was none": the
// install says the read failed — an install that failed does not remove
// a unit it could not check.
func TestInstallSaysAUnitItCannotRead(t *testing.T) {
	oldUnit(t)
	fakeSystemctl(t, "restart")
	// The unit's path holds a directory: reading it fails — not "no
	// such file" — which is not "there was none". The install says the
	// read failed, and the directory it could not read stays.
	f := file()
	if err := os.Remove(f); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(f, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(f) })
	err := Install("/usr/bin/kerod", nil)
	if err == nil {
		t.Fatal("the install succeeded")
	}
	if _, statErr := os.Stat(f); statErr != nil {
		t.Fatalf("the unit is gone: %v — a failed install removed what it could not read", statErr)
	}
	if !strings.Contains(err.Error(), "is a directory") {
		t.Fatalf("the install: %v, want the read's failure", err)
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

// A systemd that did not take the unit's removal is not an uninstall
// that worked: systemd keeps the removed unit in memory and still lists
// it, so the error says what happened.
func TestUninstallSaysWhenDaemonReloadFails(t *testing.T) {
	oldUnit(t)
	fakeSystemctl(t, "daemon-reload")
	if err := Uninstall(); err == nil {
		t.Fatal("the uninstall succeeded")
	}
}

// A unit that is there but cannot be read is not one that is not there:
// the uninstall says the read failed instead of reporting a service gone
// that systemd still has registered.
func TestUninstallSaysAUnitItCannotRead(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root enters a directory with no search permission")
	}
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	dir := filepath.Dir(file())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file(), []byte("# the unit\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The unit is there, and its directory cannot be entered: the stat
	// fails for a reason that is not "no such file".
	if err := os.Chmod(dir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })
	fakeSystemctl(t, "")
	if err := Uninstall(); err == nil {
		t.Fatal("the uninstall succeeded over a unit it could not read")
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(file()); err != nil || string(b) != "# the unit\n" {
		t.Errorf("the unit = %q (%v): it was taken away, or never looked at", b, err)
	}
}
