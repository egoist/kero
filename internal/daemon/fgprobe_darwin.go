//go:build darwin

package daemon

import (
	"syscall"

	"golang.org/x/sys/unix"
)

// groupMember returns a live process of the group pg: the leader's pid
// when it is alive, else any member's. A pipeline's leader going first
// does not end the group. The group's existence is asked cheaply first
// (kill -pg, 0), and the process table is read only when the leader is
// gone, to find a member.
func groupMember(pg int) (int, bool) {
	if pg <= 0 {
		return 0, false
	}
	if err := syscall.Kill(-pg, 0); err != nil {
		return 0, false
	}
	if procName(pg) != "" {
		return pg, true
	}
	// The leader is gone: a member of the group is what runs now. The
	// table is read for the group's id, e_pgid.
	kps, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return pg, true
	}
	for _, kp := range kps {
		if kp.Eproc.Pgid == int32(pg) {
			return int(kp.Proc.P_pid), true
		}
	}
	return pg, true
}
