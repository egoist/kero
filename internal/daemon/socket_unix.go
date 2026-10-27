//go:build !windows

package daemon

import (
	"net"
	"os"
	"syscall"
)

// listenSocket listens on a Unix socket only its user can connect to: the
// umask makes it so as it is made, rather than a chmod after, which would
// leave a moment where it is anyone's.
func listenSocket(path string) (net.Listener, error) {
	old := syscall.Umask(0o177)
	defer syscall.Umask(old)
	return net.Listen("unix", path)
}

// ownedByUser reports whether a file is this process's user's.
func ownedByUser(st os.FileInfo) bool {
	s, ok := st.Sys().(*syscall.Stat_t)
	return ok && int(s.Uid) == os.Getuid()
}
