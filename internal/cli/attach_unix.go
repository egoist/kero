//go:build !windows

package cli

import (
	"os"
	"os/signal"
	"syscall"

	"golang.org/x/sys/unix"
)

// endSignals end an attachment, which gives the terminal back first: as the
// terminal's window closes, and as someone asks.
var endSignals = []os.Signal{syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT, syscall.SIGQUIT}

func signalNumber(s os.Signal) int {
	if n, ok := s.(syscall.Signal); ok {
		return int(n)
	}
	return 0
}

// terminalSize returns a terminal's size, 0 when it tells none, and its
// cells' in pixels, 0 when it doesn't tell them, as over many SSH clients.
func terminalSize(f *os.File) (cols, rows, cellW, cellH int) {
	ws, err := unix.IoctlGetWinsize(int(f.Fd()), unix.TIOCGWINSZ)
	if err != nil {
		return 0, 0, 0, 0
	}
	cols, rows = int(ws.Col), int(ws.Row)
	if cols > 0 && rows > 0 {
		cellW, cellH = int(ws.Xpixel)/cols, int(ws.Ypixel)/rows
	}
	return cols, rows, cellW, cellH
}

// watchResize tells when the terminal may have taken another size.
func watchResize(stop <-chan struct{}) <-chan struct{} {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGWINCH)
	out := make(chan struct{}, 1)
	go func() {
		defer signal.Stop(sig)
		for {
			select {
			case <-sig:
				select {
				case out <- struct{}{}:
				default:
				}
			case <-stop:
				return
			}
		}
	}()
	return out
}

// prepareConsole has nothing to do but on Windows.
func prepareConsole(*os.File) (func(), error) { return func() {}, nil }
