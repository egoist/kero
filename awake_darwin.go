package main

import (
	"os"
	"os/exec"
	"strconv"
)

// awakeHold keeps the Mac from sleeping while it holds: caffeinate
// asserts against idle sleep, and system sleep on AC power, until it is
// killed or Kero, whose pid it waits on, exits. Closing the lid still
// sleeps the Mac.
type awakeHold struct{ cmd *exec.Cmd }

func (w *awakeHold) hold(on bool) {
	if on == (w.cmd != nil) {
		return
	}
	if !on {
		w.cmd.Process.Kill()
		w.cmd.Wait()
		w.cmd = nil
		return
	}
	cmd := exec.Command("/usr/bin/caffeinate", "-i", "-s", "-w", strconv.Itoa(os.Getpid()))
	if cmd.Start() == nil {
		w.cmd = cmd
	}
}
