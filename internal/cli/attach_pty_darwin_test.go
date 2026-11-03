package cli

import (
	"bytes"
	"os"
	"syscall"
	"testing"
	"unsafe"

	"golang.org/x/sys/unix"
)

func openPTY(t *testing.T) (master, slave *os.File) {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	var name [128]byte
	fd := master.Fd()
	for _, step := range []struct {
		req uintptr
		arg unsafe.Pointer
	}{{unix.TIOCPTYGRANT, nil}, {unix.TIOCPTYUNLK, nil}, {unix.TIOCPTYGNAME, unsafe.Pointer(&name[0])}} {
		if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, step.req, uintptr(step.arg)); e != 0 {
			t.Fatal(e)
		}
	}
	n := bytes.IndexByte(name[:], 0)
	slave, err = os.OpenFile(string(name[:n]), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { master.Close(); slave.Close() })
	return master, slave
}
