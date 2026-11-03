package daemon

import (
	"fmt"
	"os"
	"strconv"
	"syscall"
	"unsafe"
)

func openMaster() (*os.File, string, error) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, "", fmt.Errorf("pty: %w", err)
	}
	var unlock int32
	if err := ioctl(master, syscall.TIOCSPTLCK, unsafe.Pointer(&unlock)); err != nil {
		master.Close()
		return nil, "", fmt.Errorf("pty: %w", err)
	}
	var n uint32
	if err := ioctl(master, syscall.TIOCGPTN, unsafe.Pointer(&n)); err != nil {
		master.Close()
		return nil, "", fmt.Errorf("pty: %w", err)
	}
	return master, "/dev/pts/" + strconv.Itoa(int(n)), nil
}

// openSlave opens the slave side the child's terminal runs on.
func openSlave(name string) (*os.File, error) {
	return os.OpenFile(name, os.O_RDWR|syscall.O_NOCTTY, 0)
}

// hangup does nothing: closing the master hangs the terminal up, which
// sends its processes SIGHUP.
func (p *ptyProc) hangup() {}
