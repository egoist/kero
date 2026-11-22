//go:build darwin

package daemon

import "syscall"

// groupAlive reports whether any process of the group pg is still
// running: a pipeline's leader going first does not end the group.
func groupAlive(pg int) bool { return syscall.Kill(-pg, 0) == nil }
