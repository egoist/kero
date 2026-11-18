//go:build !windows

package heapdump

import (
	"os"
	"os/signal"
	"syscall"
)

// notifySignals dumps once per SIGUSR1, as `kill -USR1 <pid>` asks, so a
// profile can be taken while the process streams rather than only at its
// exit.
func notifySignals() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGUSR1)
	go func() {
		for range ch {
			Dump()
		}
	}()
}
