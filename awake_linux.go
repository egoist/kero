package main

import (
	"os/exec"
	"syscall"
)

// awakeDisplay tells that a hold can keep the display on too: not here,
// where the desktop, not systemd, turns the display off.
const awakeDisplay = false

// awakeHold keeps the machine from sleeping while it holds, by systemd's
// inhibitor lock on idle and sleep, which a sleep under systemd-inhibit
// holds until it is killed or Kero exits, as the kernel then kills it.
// It leaves the display to the desktop.
type awakeHold struct{ cmd *exec.Cmd }

func (w *awakeHold) hold(on, _ bool) {
	if on == (w.cmd != nil) {
		return
	}
	if !on {
		w.cmd.Process.Kill()
		w.cmd.Wait()
		w.cmd = nil
		return
	}
	cmd := exec.Command("systemd-inhibit", "--what=idle:sleep", "--who=Kero", "--why=Keep computer awake", "--mode=block", "sleep", "infinity")
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	if cmd.Start() == nil {
		w.cmd = cmd
	}
}
