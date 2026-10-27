package daemon

import (
	"net"

	"golang.org/x/sys/unix"
)

// peerUID returns the user of the process at the other end of a Unix
// socket (LOCAL_PEERCRED), or -1.
func peerUID(c net.Conn) int {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return -1
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return -1
	}
	uid := -1
	raw.Control(func(fd uintptr) {
		if cred, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED); err == nil {
			uid = int(cred.Uid)
		}
	})
	return uid
}
