package daemon

import (
	"fmt"
	"os"
	"strconv"
	"syscall"
	"unsafe"
)

func openPTYFile(name string, flags int) (*os.File, error) {
	return os.OpenFile(name, flags, 0)
}

func openMaster() (*os.File, string, error) {
	master, err := openPTYFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC)
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
