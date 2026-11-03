//go:build darwin || linux

package daemon

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

// ptyProc is a program running in a pseudo-terminal of its own.
type ptyProc struct {
	master *os.File
	cmd    *exec.Cmd
	exited chan struct{}
	code   int
}

type ptyOptions struct {
	Path       string
	Args       []string
	Dir        string
	Env        []string
	Cols, Rows int
	// InheritCursor is for ConPTY, whose console has a cursor of its own;
	// a Unix program draws from the terminal's.
	InheritCursor bool
}

func startPTY(o ptyOptions) (*ptyProc, error) {
	master, slaveName, err := openMaster()
	if err != nil {
		return nil, err
	}
	slave, err := openPTYFile(slaveName, os.O_RDWR|syscall.O_NOCTTY)
	if err != nil {
		master.Close()
		return nil, fmt.Errorf("pty: opening %s: %w", slaveName, err)
	}
	defer slave.Close() // the child has its own copies
	if err := setSize(master, o.Cols, o.Rows, 0, 0); err != nil {
		master.Close()
		return nil, err
	}
	cmd := &exec.Cmd{Path: o.Path, Args: o.Args, Dir: o.Dir, Env: o.Env, Stdin: slave, Stdout: slave, Stderr: slave}
	// A session of its own, whose controlling terminal is the slave, so
	// that the terminal's signals reach the process group in the
	// foreground, and nothing ties it to the daemon's.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		master.Close()
		return nil, err
	}
	p := &ptyProc{master: master, cmd: cmd, exited: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		p.code = 0
		if e, ok := errors.AsType[*exec.ExitError](err); ok {
			if ws, ok := e.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				p.code = 128 + int(ws.Signal())
			} else {
				p.code = e.ExitCode()
			}
		}
		close(p.exited)
	}()
	return p, nil
}

// Read reads the program's output; io.EOF once nothing has the terminal
// open any more.
func (p *ptyProc) Read(b []byte) (int, error) {
	n, err := p.master.Read(b)
	if err != nil && n == 0 {
		if errors.Is(err, syscall.EIO) || errors.Is(err, os.ErrClosed) {
			err = io.EOF
		}
	}
	return n, err
}

func (p *ptyProc) Write(b []byte) (int, error) { return p.master.Write(b) }

// Resize resizes the terminal, a cell being cellW by cellH pixels (0 when
// unknown).
func (p *ptyProc) Resize(cols, rows, cellW, cellH int) error {
	return setSize(p.master, cols, rows, cellW, cellH)
}

func (p *ptyProc) PID() int { return p.cmd.Process.Pid }

// ClearScreen does nothing: a Unix terminal keeps no screen of its own,
// and shells move the cursor relative to where it is.
func (p *ptyProc) ClearScreen() {}

// Close hangs up the terminal: its processes get SIGHUP.
func (p *ptyProc) Close() error { return p.master.Close() }

// Kill kills the program's process group.
func (p *ptyProc) Kill() {
	if syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL) != nil {
		p.cmd.Process.Kill()
	}
}

// Foreground returns the process group in the terminal's foreground.
func (p *ptyProc) Foreground() int {
	var pgid int32
	if ioctl(p.master, syscall.TIOCGPGRP, unsafe.Pointer(&pgid)) != nil {
		return 0
	}
	return int(pgid)
}

func setSize(f *os.File, cols, rows, cellW, cellH int) error {
	ws := struct{ row, col, xpixel, ypixel uint16 }{clamp(rows), clamp(cols), pixels(cols, cellW), pixels(rows, cellH)}
	return ioctl(f, syscall.TIOCSWINSZ, unsafe.Pointer(&ws))
}

func clamp(v int) uint16 { return uint16(max(1, min(v, 0xFFFF))) }

// pixels is the extent of n cells of size cell, 0 when unknown.
func pixels(n, cell int) uint16 { return uint16(max(0, min(n*cell, 0xFFFF))) }

func ioctl(f *os.File, req uintptr, arg unsafe.Pointer) error {
	c, err := f.SyscallConn()
	if err != nil {
		return err
	}
	var errno syscall.Errno
	err = c.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(arg))
	})
	if err != nil {
		return err
	}
	if errno != 0 {
		return errno
	}
	return nil
}
