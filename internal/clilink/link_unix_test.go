//go:build !windows

package clilink

import (
	"os"
	"path/filepath"
	"testing"
)

// Run through its link, as a bridge over SSH runs, the CLI never links
// the link to itself: the link to the app stays.
func TestLinkToItself(t *testing.T) {
	dir := t.TempDir()
	app := filepath.Join(dir, "Kero")
	if err := os.WriteFile(app, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "bin")
	if err := Link(app, bin); err != nil {
		t.Fatal(err)
	}
	if err := Link(filepath.Join(bin, "kero"), bin); err != nil {
		t.Fatal(err)
	}
	if got := Target(bin); got != app {
		t.Fatalf("bin/kero -> %q, want %q", got, app)
	}
}
