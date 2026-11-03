package daemon

import (
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var getExtendedTCPTable = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetExtendedTcpTable")

// tcpTable asks Windows for the sockets listening of a family, with their
// processes, which it tells any user.
func tcpTable(family uint32) ([]byte, error) {
	const tcpTableOwnerPIDListener = 3
	size := uint32(32 << 10)
	for range 4 {
		buf := make([]byte, size)
		r, _, _ := getExtendedTCPTable.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)), 0,
			uintptr(family), tcpTableOwnerPIDListener, 0)
		switch syscall.Errno(r) {
		case 0:
			return buf[:size], nil
		case windows.ERROR_INSUFFICIENT_BUFFER:
			continue
		default:
			return nil, syscall.Errno(r)
		}
	}
	return nil, windows.ERROR_INSUFFICIENT_BUFFER
}

// tcpListeners lists the sockets listening, and names their processes from
// a snapshot, which has those the user may not open too.
func tcpListeners() ([]tcpListener, error) {
	v4, err := tcpTable(windows.AF_INET)
	if err != nil {
		return nil, err
	}
	out := parseTCPTable(v4)
	if v6, err := tcpTable(windows.AF_INET6); err == nil {
		out = append(out, parseTCP6Table(v6)...)
	}
	names := map[int]string{}
	for _, e := range processes() {
		names[int(e.pid)] = strings.TrimSuffix(e.name, ".exe")
	}
	for i := range out {
		out[i].name = names[out[i].pid]
	}
	return out, nil
}

// procBundled is of macOS's applications.
func procBundled(int) bool { return false }
