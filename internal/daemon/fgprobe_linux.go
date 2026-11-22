//go:build linux

package daemon

import (
	"bytes"
	"os"
	"strconv"
	"strings"
)

// groupAlive reports whether any process of the group pg is still
// running: a pipeline's leader going first does not end the group. The
// fields of /proc/pid/stat past the state are ppid, pgrp, ... : f[0] is
// the state, f[2] the group.
func groupAlive(pg int) bool {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	for _, e := range entries {
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
			return true
		}
	}
	return false
}
