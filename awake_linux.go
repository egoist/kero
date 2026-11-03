package main

import (
	"os/exec"
	"syscall"
)

// awakeHold keeps the machine from sleeping while it holds, by systemd's
// inhibitor lock on idle and sleep, which a sleep under systemd-inhibit
// holds until it is killed or Kero exits, as the kernel then kills it.
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
	cmd := exec.Command("systemd-inhibit", "--what=idle:sleep", "--who=Kero", "--why=Keep computer awake", "--mode=block", "sleep", "infinity")
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	if cmd.Start() == nil {
		w.cmd = cmd
	}
}
