package daemon

import (
	"bytes"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// The ioctls of grantpt, unlockpt and ptsname on macOS (sys/ttycom.h).
const (
	tiocptygrant = 0x20007454
	tiocptyunlk  = 0x20007452
	tiocptygname = 0x40807453
)

// openPTYFile leaves the PTY in blocking mode. os.OpenFile registers character
// devices with Go's poller, which changes them to nonblocking mode; a PTY read
// must instead wait for terminal input.
func openPTYFile(name string, flags int) (*os.File, error) {
	fd, err := syscall.Open(name, flags|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), name)
	if f == nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("pty: invalid file descriptor for %s", name)
	}
	return f, nil
}

func openMaster() (*os.File, string, error) {
	master, err := openPTYFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY)
	if err != nil {
		return nil, "", fmt.Errorf("pty: %w", err)
	}
	var name [128]byte
	for _, step := range []struct {
		req uintptr
		arg unsafe.Pointer
	}{{tiocptygrant, nil}, {tiocptyunlk, nil}, {tiocptygname, unsafe.Pointer(&name[0])}} {
		if err := ioctl(master, step.req, step.arg); err != nil {
			master.Close()
			return nil, "", fmt.Errorf("pty: %w", err)
		}
	}
	n := bytes.IndexByte(name[:], 0)
	if n < 0 {
		n = len(name)
	}
	return master, string(name[:n]), nil
}
