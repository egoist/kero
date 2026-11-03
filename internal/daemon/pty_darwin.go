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

func openMaster() (*os.File, string, error) {
	master, err := openBlocking("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY)
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

// openBlocking opens a path without letting os.OpenFile move the
// descriptor into the runtime poller's non-blocking mode.
//
// macOS 26.2's fcntl(F_SETFL) on a pty master reports ENOTTY while still
// applying the change: os.OpenFile sees the error, leaves the descriptor
// non-blocking but unregistered with kqueue, and every Read then fails
// with EAGAIN instead of waiting for output. Opening the descriptors
// directly and wrapping them with os.NewFile keeps them blocking, as a
// pane's terminal reads are meant to be.
func openBlocking(path string, flag int) (*os.File, error) {
	fd, err := syscall.Open(path, flag|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	return os.NewFile(uintptr(fd), path), nil
}

// openSlave opens the slave side the child's terminal runs on.
func openSlave(name string) (*os.File, error) {
	return openBlocking(name, os.O_RDWR|syscall.O_NOCTTY)
}

// hangup sends the terminal's processes the SIGHUP that closing the
// master sends them on Linux. Here the master is blocking, and it is only
// really closed once pump's Read on it returns, which waits for them to
// end: without the signal, closing a pane would SIGKILL them two seconds
// later instead of hanging them up.
func (p *ptyProc) hangup() {
	if pg := p.Foreground(); pg > 0 {
		syscall.Kill(-pg, syscall.SIGHUP)
	}
	syscall.Kill(-p.cmd.Process.Pid, syscall.SIGHUP)
}
