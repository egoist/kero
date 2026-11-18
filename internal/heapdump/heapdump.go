// Package heapdump writes a heap profile of a running Kero or kerod,
// which a release build has no other way to give: with KERO_HEAP_PROFILE
// set, the profile and the process's heap numbers land in the temporary
// directory as heap-<pid>.pprof and heap-<pid>.stats, once at the
// process's exit and once per SIGUSR1 while it runs (#288). The profile
// is the one `go tool pprof` reads, with inuse_space and alloc_space
// that a report of a process's footprint can carry.
package heapdump

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"sync"
)

// tempDir is where a dump goes: the system's temporary directory, as a
// test says otherwise.
var tempDir = os.TempDir

// mu keeps a dump from a signal and one at the exit from writing their
// files at once.
var mu sync.Mutex

// Enable arms a dump per SIGUSR1 while the process runs, unless
// KERO_HEAP_PROFILE is unset, which costs nothing to call either way.
// The dump at the exit is the caller's, with Dump.
func Enable() {
	if os.Getenv("KERO_HEAP_PROFILE") == "" {
		return
	}
	notifySignals()
}

// Dump writes the heap profile and the process's heap numbers, unless
// KERO_HEAP_PROFILE is unset. It is safe to call more than once: a dump
// replaces the files of the one before it.
func Dump() {
	if os.Getenv("KERO_HEAP_PROFILE") == "" {
		return
	}
	dumpTo(tempDir())
}

// dumpTo writes heap-<pid>.pprof and heap-<pid>.stats into dir. The heap
// is collected first, so inuse_space counts what the process keeps, and
// not what a collection is about to take.
func dumpTo(dir string) {
	mu.Lock()
	defer mu.Unlock()
	runtime.GC()
	base := filepath.Join(dir, fmt.Sprintf("heap-%d", os.Getpid()))
	if err := writeProfile(base + ".pprof"); err != nil {
		fmt.Fprintf(os.Stderr, "kero: heap profile: %v\n", err)
	}
	if err := writeStats(base + ".stats"); err != nil {
		fmt.Fprintf(os.Stderr, "kero: heap stats: %v\n", err)
	}
}

// writeProfile writes the profile `go tool pprof` reads.
func writeProfile(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := pprof.WriteHeapProfile(f); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "kero: heap profile written to %s\n", path)
	return nil
}

// writeStats writes the heap numbers of runtime.MemStats, plain enough
// to read without the profiler.
func writeStats(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	_, err = fmt.Fprintf(f, "HeapAlloc    %d\nHeapSys      %d\nHeapInuse    %d\nHeapIdle     %d\nHeapReleased %d\nHeapObjects  %d\nSys          %d\nNumGC        %d\n",
		ms.HeapAlloc, ms.HeapSys, ms.HeapInuse, ms.HeapIdle, ms.HeapReleased, ms.HeapObjects, ms.Sys, ms.NumGC)
	return err
}
