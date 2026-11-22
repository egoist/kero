//go:build linux

package daemon

import (
	"bytes"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// groupMember returns a live process of the group pg: the leader's pid
// when it is alive, else any member's. A pipeline's leader going first
// does not end the group. The group's existence is asked cheaply first
// (kill -pg, 0), and /proc is scanned only when the leader is gone, to
// find a member.
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
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0, false
	}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/stat")
		if err != nil {
			continue
		}
		i := bytes.LastIndexByte(b, ')')
		if i < 0 {
			continue
		}
		f := strings.Fields(string(b[i+1:]))
		if len(f) < 3 {
			continue
		}
		if g, err := strconv.Atoi(f[2]); err == nil && g == pg {
			return pid, true
		}
	}
	return 0, false
}
