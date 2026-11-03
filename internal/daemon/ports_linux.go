package daemon

import (
	"errors"
	"os"
	"strconv"
	"strings"
)

// tcpListeners reads the sockets listening from /proc/net, then finds what
// holds them among the processes whose descriptors the user may read: what
// others run shows as a port with no owner.
func tcpListeners() ([]tcpListener, error) {
	socks := map[uint64]tcpListener{}
	read := false
	for _, f := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		read = true
		for inode, l := range parseProcNet(b) {
			socks[inode] = l
		}
	}
	if !read {
		return nil, errors.New("this system has no /proc/net/tcp to read its ports from")
	}
	procs, _ := os.ReadDir("/proc")
	left := len(socks)
	for _, e := range procs {
		if left == 0 {
			break
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		dir := "/proc/" + e.Name() + "/fd"
		fds, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		name := ""
		for _, fd := range fds {
			link, err := os.Readlink(dir + "/" + fd.Name())
			if err != nil || !strings.HasPrefix(link, "socket:[") {
				continue
			}
			inode, err := strconv.ParseUint(strings.TrimSuffix(link[len("socket:["):], "]"), 10, 64)
			if err != nil {
				continue
			}
			l, ok := socks[inode]
			if !ok || l.pid != 0 {
				continue
			}
			if name == "" {
				name = procName(pid)
			}
			l.pid, l.name = pid, name
			socks[inode] = l
			left--
		}
	}
	out := make([]tcpListener, 0, len(socks))
	for _, l := range socks {
		out = append(out, l)
	}
	return out, nil
}

// procBundled is of macOS's applications.
func procBundled(int) bool { return false }
