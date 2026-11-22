//go:build windows

package daemon

// groupMember returns a live process of the group pg. Windows has no
// process groups as such; the foreground job's leader is what procName
// reads, as before.
func groupMember(pg int) (int, bool) {
	if pg <= 0 {
		return 0, false
	}
	return pg, true
}
