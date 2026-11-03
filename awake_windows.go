package main

import (
	"runtime"

	"golang.org/x/sys/windows"
)

var setThreadExecutionState = windows.NewLazySystemDLL("kernel32.dll").NewProc("SetThreadExecutionState")

const (
	esContinuous     = 0x80000000
	esSystemRequired = 0x00000001
)

// awakeHold keeps Windows from sleeping while it holds, as
// SetThreadExecutionState asks for a thread: one of its own, locked to
// its goroutine, which the state lasts as long as.
type awakeHold struct {
	on   bool
	asks chan bool
}

func (w *awakeHold) hold(on bool) {
	if on == w.on {
		return
	}
	w.on = on
	if w.asks == nil {
		w.asks = make(chan bool, 1)
		go func() {
			runtime.LockOSThread()
			for on := range w.asks {
				state := uintptr(esContinuous)
				if on {
					state |= esSystemRequired
				}
				setThreadExecutionState.Call(state)
			}
		}()
	}
	w.asks <- on
}
