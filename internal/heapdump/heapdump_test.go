package heapdump

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withTempDir sends the dumps of a test to a directory of its own, and
// leaves the package as it was.
func withTempDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	old := tempDir
	tempDir = func() string { return dir }
	t.Cleanup(func() { tempDir = old })
	return dir
}

// A dump writes the profile the profiler reads and the heap numbers
// beside it, named for the process they are of.
func TestDumpWritesProfileAndStats(t *testing.T) {
	dir := withTempDir(t)
	t.Setenv("KERO_HEAP_PROFILE", "1")
	Enable()
	Dump()
	base := filepath.Join(dir, fmt.Sprintf("heap-%d", os.Getpid()))
	p, err := os.ReadFile(base + ".pprof")
	if err != nil {
		t.Fatal(err)
	}
	if len(p) == 0 {
		t.Error("an empty profile")
	}
	s, err := os.ReadFile(base + ".stats")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"HeapAlloc", "HeapInuse", "HeapObjects", "NumGC"} {
		if !strings.Contains(string(s), want) {
			t.Errorf("no %s in:\n%s", want, s)
		}
	}
}

// Without KERO_HEAP_PROFILE nothing is written, however often Dump runs.
func TestWithoutTheVariableWritesNothing(t *testing.T) {
	dir := withTempDir(t)
	t.Setenv("KERO_HEAP_PROFILE", "")
	Enable()
	Dump()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("%d files written with the variable unset", len(entries))
	}
}
