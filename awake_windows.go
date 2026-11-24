package main

import (
	"runtime"

	"golang.org/x/sys/windows"
)

var setThreadExecutionState = windows.NewLazySystemDLL("kernel32.dll").NewProc("SetThreadExecutionState")

const (
	esContinuous      = 0x80000000
	esSystemRequired  = 0x00000001
	esDisplayRequired = 0x00000002
)

// awakeDisplay tells that a hold can keep the display on too.
const awakeDisplay = true

// awakeHold keeps Windows from sleeping while it holds, and its display
// from turning off if asked, as SetThreadExecutionState asks for a
// thread: one of its own, locked to its goroutine, which the state lasts
// as long as.
type awakeHold struct {
	on, display bool
	asks        chan uintptr
}

func (w *awakeHold) hold(on, display bool) {
	display = on && display
	if on == w.on && display == w.display {
		return
	}
	w.on, w.display = on, display
	if w.asks == nil {
		w.asks = make(chan uintptr, 1)
		go func() {
			runtime.LockOSThread()
			for state := range w.asks {
				setThreadExecutionState.Call(state)
			}
		}()
	}
	w.asks <- executionState(on, display)
}

// executionState is the state SetThreadExecutionState is given for a
// hold: continuous, and the system's and the display's as asked.
func executionState(on, display bool) uintptr {
	state := uintptr(esContinuous)
	if on {
		state |= esSystemRequired
	}
	if display {
		state |= esDisplayRequired
	}
	return state
}
