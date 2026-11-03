package cli

import (
	"fmt"
	"os"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

// endSignals end an attachment, which gives the console back first: Ctrl+C
// from outside, and the console's window closing.
var endSignals = []os.Signal{os.Interrupt, syscall.SIGTERM}

func signalNumber(s os.Signal) int {
	if n, ok := s.(syscall.Signal); ok {
		return int(n)
	}
	return 0
}

// terminalSize returns the console's size; it doesn't tell its cells'.
func terminalSize(f *os.File) (cols, rows, cellW, cellH int) {
	cols, rows, err := term.GetSize(int(f.Fd()))
	if err != nil {
		return 0, 0, 0, 0
	}
	return cols, rows, 0, 0
}

// watchResize tells when the console may have taken another size, which a
// console tells only among the input events it reads the keys from: it looks.
func watchResize(stop <-chan struct{}) <-chan struct{} {
	out := make(chan struct{}, 1)
	go func() {
		t := time.NewTicker(250 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-t.C:
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

// prepareConsole has the console read VT sequences, returning what sets it
// back. term.MakeRaw has its input send them.
func prepareConsole(f *os.File) (func(), error) {
	h := windows.Handle(f.Fd())
	var mode uint32
	if err := windows.GetConsoleMode(h, &mode); err != nil {
		return nil, fmt.Errorf("kero attach: %w", err)
	}
	if err := windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING|windows.DISABLE_NEWLINE_AUTO_RETURN); err != nil {
		return nil, fmt.Errorf("kero attach: this console doesn't take terminal sequences: %w", err)
	}
	return func() { windows.SetConsoleMode(h, mode) }, nil
}
