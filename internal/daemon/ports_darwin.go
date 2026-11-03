package daemon

import (
	"bytes"
	"encoding/binary"
	"os"
	"strings"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
	"golang.org/x/sys/unix"
)

var (
	portsLibOnce sync.Once
	pidinfo      func(pid int32, flavor int32, arg uint64, buffer unsafe.Pointer, size int32) int32
	pidfdinfo    func(pid int32, fd int32, flavor int32, buffer unsafe.Pointer, size int32) int32
)

// tcpListeners walks the sockets of the user's processes, through libproc:
// what others run, as root's services, the system does not tell without
// root, and shows not.
func tcpListeners() ([]tcpListener, error) {
	portsLibOnce.Do(func() {
		lib, err := purego.Dlopen("/usr/lib/libSystem.B.dylib", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			return
		}
		purego.RegisterLibFunc(&pidinfo, lib, "proc_pidinfo")
		purego.RegisterLibFunc(&pidfdinfo, lib, "proc_pidfdinfo")
	})
	procs, err := unix.SysctlKinfoProcSlice("kern.proc.uid", os.Getuid())
	if err != nil {
		return nil, err
	}
	const (
		listFDs      = 1    // PROC_PIDLISTFDS
		fdSocketInfo = 3    // PROC_PIDFDSOCKETINFO
		fdSocket     = 2    // PROX_FDTYPE_SOCKET
		fdInfoBytes  = 8    // struct proc_fdinfo
		socketBytes  = 1024 // room for a socket_fdinfo
	)
	var out []tcpListener
	fds := make([]byte, 64<<10)
	info := make([]byte, socketBytes)
	for i := range procs {
		pid := procs[i].Proc.P_pid
		if pid <= 0 {
			continue
		}
		n := pidinfo(pid, listFDs, 0, unsafe.Pointer(&fds[0]), int32(len(fds)))
		if n <= 0 {
			continue
		}
		name := ""
		for at := 0; at+fdInfoBytes <= int(n); at += fdInfoBytes {
			if binary.LittleEndian.Uint32(fds[at+4:]) != fdSocket {
				continue
			}
			fd := int32(binary.LittleEndian.Uint32(fds[at:]))
			m := pidfdinfo(pid, fd, fdSocketInfo, unsafe.Pointer(&info[0]), int32(len(info)))
			if m <= 0 {
				continue
			}
			addr, port, ok := parseSocketInfo(info[:m])
			if !ok {
				continue
			}
			if name == "" {
				name = procDisplayName(int(pid), procs[i].Proc.P_comm[:])
			}
			out = append(out, tcpListener{addr: addr, port: port, pid: int(pid), name: name})
		}
	}
	return out, nil
}

// procDisplayName names a process, whose name the kernel keeps to 16 bytes,
// by its executable.
func procDisplayName(pid int, comm []byte) string {
	if p := procExe(pid); p != "" {
		return p[strings.LastIndexByte(p, '/')+1:]
	}
	if i := bytes.IndexByte(comm, 0); i >= 0 {
		comm = comm[:i]
	}
	return string(comm)
}

// procExe is the path of a process's executable, which kern.procargs2 has
// after the count of its arguments.
func procExe(pid int) string {
	buf, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil || len(buf) < 4 {
		return ""
	}
	buf = buf[4:]
	if i := bytes.IndexByte(buf, 0); i >= 0 {
		return string(buf[:i])
	}
	return ""
}

// procBundled tells a process of an application bundle, as a menu bar
// app's, whose ports are for itself: but those of what runs servers for
// the user, as a container engine's.
func procBundled(pid int) bool {
	exe := procExe(pid)
	if !strings.Contains(exe, ".app/Contents/") {
		return false
	}
	for _, s := range []string{"/Docker.app/", "/OrbStack.app/", "/Colima.app/", "/Rancher Desktop.app/", "/Podman Desktop.app/"} {
		if strings.Contains(exe, s) {
			return false
		}
	}
	return true
}
