package main

import (
	"os"
	"os/exec"
	"strconv"
)

// awakeDisplay tells that a hold can keep the display on too.
const awakeDisplay = true

// awakeHold keeps the Mac from sleeping while it holds: caffeinate
// asserts against idle sleep, against system sleep on AC power, which
// keeps the Mac awake with its lid closed, and, if asked, against the
// display's sleep, until it is killed or Kero, whose pid it waits on,
// exits. On battery, closing the lid still sleeps the Mac.
type awakeHold struct {
	cmd     *exec.Cmd
	display bool // cmd keeps the display on too
}

func (w *awakeHold) hold(on, display bool) {
	display = on && display
	if on == (w.cmd != nil) && display == w.display {
		return
	}
	old := w.cmd
	if on {
		cmd := caffeinateCmd(display)
		if cmd.Start() != nil {
			// The new hold did not start: the old one keeps holding, so
			// that the Mac does not sleep between them.
			return
		}
		w.cmd, w.display = cmd, display
	} else {
		w.cmd, w.display = nil, false
	}
	// The old caffeinate goes once the new one holds, so that the Mac
	// can't sleep between them.
	if old != nil {
		old.Process.Kill()
		old.Wait()
	}
}

// caffeinateCmd makes the caffeinate that holds, so that a test can have
// it fail to start.
var caffeinateCmd = func(display bool) *exec.Cmd {
	return exec.Command("/usr/bin/caffeinate", caffeinateArgs(display, os.Getpid())...)
}

// caffeinateArgs are caffeinate's flags for a hold that waits on pid, and
// keeps the display on if display.
func caffeinateArgs(display bool, pid int) []string {
	args := []string{"-i", "-s"}
	if display {
		args = append(args, "-d")
	}
	return append(args, "-w", strconv.Itoa(pid))
}
