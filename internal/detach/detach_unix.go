//go:build !windows

// Package detach starts programs that outlive whoever started them, as
// kerod, which the app, the CLI and a bridge start, and which starts the
// kerod that follows it as it restarts.
package detach

import (
	"os/exec"
	"syscall"
)

// Start starts cmd, returning what runs it, in a session of its own, so
// that it outlives whoever started it.
func Start(cmd *exec.Cmd) (*exec.Cmd, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd, cmd.Start()
}
