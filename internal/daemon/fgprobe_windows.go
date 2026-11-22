//go:build windows

package daemon

// groupAlive reports whether any process of the group pg is still
// running. Windows has no process groups as such; the foreground job's
// leader is what procName reads, as before.
func groupAlive(pg int) bool { return true }
