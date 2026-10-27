package daemon

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"

	"kero/internal/clilink"
)

// ptyProc is a program running in a pseudo console of its own (ConPTY),
// in a job object that holds it and what it starts.
type ptyProc struct {
	mu      sync.Mutex
	console uintptr // the HPCON, 0 once closed
	conpty  conPTY  // the ConPTY of the console
	// cols and rows are the console's size.
	cols, rows int
	in         *os.File
	out        *os.File
	process    windows.Handle
	job        windows.Handle
	pid        int
	exited     chan struct{}
	code       int
}

type ptyOptions struct {
	Path       string
	Args       []string
	Dir        string
	Env        []string
	Cols, Rows int
	// InheritCursor starts the console's cursor where the terminal's is,
	// which it asks for (DSR) and the terminal must answer: else it starts
	// at the top, and draws there, over a restored pane's history.
	InheritCursor bool
	// conpty is the ConPTY to start the program in, conpty() when unset.
	conpty conPTY
}

var (
	kernel32                              = windows.NewLazySystemDLL("kernel32.dll")
	procInitializeProcThreadAttributeList = kernel32.NewProc("InitializeProcThreadAttributeList")
	procUpdateProcThreadAttribute         = kernel32.NewProc("UpdateProcThreadAttribute")
	procDeleteProcThreadAttributeList     = kernel32.NewProc("DeleteProcThreadAttributeList")
	procSetConsoleCtrlHandler             = kernel32.NewProc("SetConsoleCtrlHandler")
)

// allowCtrlC takes Ctrl+C back for the programs the daemon starts: it is
// started in a process group of its own (detach.Start), which ignores
// Ctrl+C, and they would too, as what is ignored passes on to children,
// a console's Ctrl+C then ending nothing (vite, ping -t).
func allowCtrlC() { procSetConsoleCtrlHandler.Call(0, 0) }

// conPTY is a ConPTY's functions: Windows' own, in kernel32, or those of
// the conpty.dll Kero ships, which runs the OpenConsole.exe beside it.
type conPTY struct {
	create, resize, close *windows.LazyProc
	clear                 *windows.LazyProc // nil in kernel32, which has none
}

var systemConPTY = conPTY{
	create: kernel32.NewProc("CreatePseudoConsole"),
	resize: kernel32.NewProc("ResizePseudoConsole"),
	close:  kernel32.NewProc("ClosePseudoConsole"),
}

// bundledConPTY returns the ConPTY of the conpty.dll in dir, when it and
// its OpenConsole.exe are there and it loads.
func bundledConPTY(dir string) (conPTY, bool) {
	if _, err := os.Stat(filepath.Join(dir, "OpenConsole.exe")); err != nil {
		return conPTY{}, false
	}
	dll := windows.NewLazyDLL(filepath.Join(dir, "conpty.dll"))
	c := conPTY{
		create: dll.NewProc("CreatePseudoConsole"),
		resize: dll.NewProc("ResizePseudoConsole"),
		close:  dll.NewProc("ClosePseudoConsole"),
		clear:  dll.NewProc("ClearPseudoConsole"),
	}
	for _, p := range []*windows.LazyProc{c.create, c.resize, c.close, c.clear} {
		if p.Find() != nil {
			return conPTY{}, false
		}
	}
	return c, true
}

// conpty returns the ConPTY panes run in: the one Kero ships next to its
// executable (resources/windows-*), or next to the app the kero command is
// a copy of, else Windows' own, as under go test. The one Kero ships is
// newer, and passes what programs write on as it is: Windows' own drops
// the mouse modes a program sets before it reads the console in VT input
// mode, as pi does, which then gets the wheel as the arrow keys.
var conpty = sync.OnceValue(func() conPTY {
	exe, err := os.Executable()
	if err != nil {
		return systemConPTY
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	dirs := []string{filepath.Dir(exe)}
	if app := clilink.Target(filepath.Dir(exe)); app != "" {
		dirs = append(dirs, filepath.Dir(app))
	}
	for _, dir := range dirs {
		if c, ok := bundledConPTY(dir); ok {
			return c
		}
	}
	return systemConPTY
})

const (
	procThreadAttributePseudoConsole = 0x00020016
	pseudoconsoleInheritCursor       = 0x1
)

type startupInfoEx struct {
	windows.StartupInfo
	attributes uintptr
}

func startPTY(o ptyOptions) (*ptyProc, error) {
	cp := o.conpty
	if cp.create == nil {
		cp = conpty()
	}
	if err := cp.create.Find(); err != nil {
		return nil, errors.New("pty: ConPTY needs Windows 10 1809 or later")
	}
	// The console reads what is typed from inR and writes the output to
	// outW; the daemon writes to inW and reads outR.
	var inR, inW, outR, outW windows.Handle
	if err := windows.CreatePipe(&inR, &inW, nil, 0); err != nil {
		return nil, fmt.Errorf("pty: %w", err)
	}
	if err := windows.CreatePipe(&outR, &outW, nil, 0); err != nil {
		windows.CloseHandle(inR)
		windows.CloseHandle(inW)
		return nil, fmt.Errorf("pty: %w", err)
	}
	var console, flags uintptr
	if o.InheritCursor {
		flags |= pseudoconsoleInheritCursor
	}
	r, _, _ := cp.create.Call(coord(o.Cols, o.Rows), uintptr(inR), uintptr(outW), flags, uintptr(unsafe.Pointer(&console)))
	// The console has its own copies of its ends.
	windows.CloseHandle(inR)
	windows.CloseHandle(outW)
	if r != 0 {
		windows.CloseHandle(inW)
		windows.CloseHandle(outR)
		return nil, fmt.Errorf("pty: CreatePseudoConsole: %w", syscall.Errno(r&0xFFFF))
	}
	p := &ptyProc{
		console: console,
		conpty:  cp,
		cols:    o.Cols,
		rows:    o.Rows,
		in:      os.NewFile(uintptr(inW), "conpty-in"),
		out:     os.NewFile(uintptr(outR), "conpty-out"),
		exited:  make(chan struct{}),
	}
	if err := p.spawn(o); err != nil {
		p.Close()
		p.out.Close()
		return nil, err
	}
	go p.wait()
	return p, nil
}

func (p *ptyProc) spawn(o ptyOptions) error {
	allowCtrlC()
	var size uintptr
	procInitializeProcThreadAttributeList.Call(0, 1, 0, uintptr(unsafe.Pointer(&size)))
	list := make([]byte, size)
	if r, _, err := procInitializeProcThreadAttributeList.Call(uintptr(unsafe.Pointer(&list[0])), 1, 0, uintptr(unsafe.Pointer(&size))); r == 0 {
		return fmt.Errorf("pty: InitializeProcThreadAttributeList: %w", err)
	}
	defer procDeleteProcThreadAttributeList.Call(uintptr(unsafe.Pointer(&list[0])))
	if r, _, err := procUpdateProcThreadAttribute.Call(uintptr(unsafe.Pointer(&list[0])), 0, procThreadAttributePseudoConsole, p.console, unsafe.Sizeof(p.console), 0, 0); r == 0 {
		return fmt.Errorf("pty: UpdateProcThreadAttribute: %w", err)
	}
	si := startupInfoEx{attributes: uintptr(unsafe.Pointer(&list[0]))}
	si.Cb = uint32(unsafe.Sizeof(si))
	// The console's own standard handles: with the daemon's, which go to
	// its log, the program would write there instead.
	si.Flags = windows.STARTF_USESTDHANDLES
	si.StdInput, si.StdOutput, si.StdErr = windows.InvalidHandle, windows.InvalidHandle, windows.InvalidHandle

	cmdline, err := windows.UTF16PtrFromString(commandLine(o.Path, o.Args))
	if err != nil {
		return err
	}
	var dir *uint16
	if o.Dir != "" {
		if dir, err = windows.UTF16PtrFromString(o.Dir); err != nil {
			return err
		}
	}
	var env *uint16
	if o.Env != nil {
		block := environmentBlock(o.Env)
		env = &block[0]
	}
	// Suspended until it is in its job, so that whatever it starts is too.
	flags := uint32(windows.EXTENDED_STARTUPINFO_PRESENT | windows.CREATE_UNICODE_ENVIRONMENT | windows.CREATE_SUSPENDED)
	var pi windows.ProcessInformation
	if err := windows.CreateProcess(nil, cmdline, nil, nil, false, flags, env, dir, &si.StartupInfo, &pi); err != nil {
		return fmt.Errorf("pty: starting %s: %w", o.Path, err)
	}
	if job, err := windows.CreateJobObject(nil, nil); err == nil {
		if windows.AssignProcessToJobObject(job, pi.Process) == nil {
			p.job = job
		} else {
			windows.CloseHandle(job)
		}
	}
	windows.ResumeThread(pi.Thread)
	windows.CloseHandle(pi.Thread)
	p.process, p.pid = pi.Process, int(pi.ProcessId)
	return nil
}

// wait waits for the program to exit, then closes the console: its output
// ends there, unlike a Unix terminal's, which ends as the last process
// holding it goes.
func (p *ptyProc) wait() {
	windows.WaitForSingleObject(p.process, windows.INFINITE)
	var code uint32
	windows.GetExitCodeProcess(p.process, &code)
	p.code = int(code)
	close(p.exited)
	p.Close()
}

// Read reads the program's output; io.EOF once the console is closed and
// wrote what it had.
func (p *ptyProc) Read(b []byte) (int, error) {
	n, err := p.out.Read(b)
	if err != nil && n == 0 && (errors.Is(err, os.ErrClosed) || errors.Is(err, windows.ERROR_BROKEN_PIPE)) {
		err = io.EOF
	}
	return n, err
}

func (p *ptyProc) Write(b []byte) (int, error) { return p.in.Write(b) }

// Resize resizes the console; ConPTY has no size in pixels. A new width
// and height go one after the other, the width first: the console, given
// both at once, keeps its rows at the top as it grows, its cursor rows
// above the bottom, where the terminal's, which brings rows back from the
// scrollback, is at the bottom; the program then draws above the
// terminal's last rows, which stay blank.
func (p *ptyProc) Resize(cols, rows, _, _ int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.console == 0 {
		return os.ErrClosed
	}
	if cols != p.cols && rows != p.rows {
		if err := p.resize(cols, p.rows); err != nil {
			return err
		}
	}
	return p.resize(cols, rows)
}

// resize resizes the console; p.mu is held.
func (p *ptyProc) resize(cols, rows int) error {
	if r, _, _ := p.conpty.resize.Call(p.console, coord(cols, rows)); r != 0 {
		return fmt.Errorf("pty: ResizePseudoConsole: %w", syscall.Errno(r&0xFFFF))
	}
	p.cols, p.rows = cols, rows
	return nil
}

func (p *ptyProc) PID() int { return p.pid }

// ptySignalClearWindow is the signal that clears a console's screen and
// scrollback above the cursor's line, which moves to the top, as
// ClearPseudoConsole sends it; kernel32 has no ClearPseudoConsole.
const ptySignalClearWindow = 2

// ClearScreen clears the console's screen as the terminal's was
// (Terminal.ClearScreen): the console draws with the cursor at absolute
// rows, so with its prompt still on a lower row it would send the cursor
// back there. The bundled ConPTY has ClearPseudoConsole; Windows' own
// takes its signal from Windows 11 24H2, and an older one ends at a signal
// it does not know, so it is left as it is.
func (p *ptyProc) ClearScreen() {
	if p.conpty.clear == nil && windows.RtlGetVersion().BuildNumber < 26100 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.console == 0 {
		return
	}
	if p.conpty.clear != nil {
		p.conpty.clear.Call(p.console)
		return
	}
	// kernel32's HPCON points at the console's handles, its signal pipe first.
	signal := **(**windows.Handle)(unsafe.Pointer(&p.console))
	packet := [2]byte{ptySignalClearWindow, 0} // a little-endian uint16
	var n uint32
	windows.WriteFile(signal, packet[:], &n, nil)
}

// Close closes the console, which ends the processes attached to it, as a
// hangup does. Read returns io.EOF once it wrote what it had.
func (p *ptyProc) Close() error {
	p.mu.Lock()
	console := p.console
	p.console = 0
	p.mu.Unlock()
	if console == 0 {
		return nil
	}
	p.in.Close()
	// ClosePseudoConsole waits for its output to be read before Windows 11
	// 24H2: pump goes on reading meanwhile, to the end, then the pipe goes.
	go func() {
		p.conpty.close.Call(console)
		p.out.Close()
	}()
	return nil
}

// Kill kills the program and whatever it started.
func (p *ptyProc) Kill() {
	if p.job == 0 || windows.TerminateJobObject(p.job, 1) != nil {
		windows.TerminateProcess(p.process, 1)
	}
}

// Foreground returns the program the shell runs: Windows has no process
// groups, so it is the one of the shell's children that started last,
// or, down its line of children, the coding agent one of them runs (as
// cmd.exe does for an npm shim); 0 when there is none.
func (p *ptyProc) Foreground() int {
	return foreground(p.pid)
}

// coord packs a COORD, which ConPTY takes by value.
func coord(cols, rows int) uintptr {
	return uintptr(uint16(max(1, min(cols, 0x7FFF)))) | uintptr(uint16(max(1, min(rows, 0x7FFF))))<<16
}

// commandLine joins a program and its arguments as the C runtime splits
// them; args[0] is the program's name, which Windows takes from the path.
func commandLine(path string, args []string) string {
	parts := []string{windows.EscapeArg(path)}
	if len(args) > 1 {
		for _, a := range args[1:] {
			parts = append(parts, windows.EscapeArg(a))
		}
	}
	return strings.Join(parts, " ")
}

// environmentBlock encodes env as CreateProcess takes it: NUL-terminated
// UTF-16 strings, then another NUL.
func environmentBlock(env []string) []uint16 {
	var b []uint16
	for _, kv := range env {
		b = append(b, utf16.Encode([]rune(kv))...)
		b = append(b, 0)
	}
	if len(b) == 0 {
		b = append(b, 0)
	}
	return append(b, 0)
}
