//go:build windows

package heapdump

// notifySignals does nothing: Windows has no SIGUSR1 to ask a profile
// with, so there a dump happens at the process's exit alone.
func notifySignals() {}
