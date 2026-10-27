package daemon

import (
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// conPTYs returns the ConPTYs a test runs in, by name: Windows' own and
// the one Kero ships, from the repository's resources.
func conPTYs(t *testing.T) map[string]conPTY {
	t.Helper()
	out := map[string]conPTY{"system": systemConPTY}
	if c, ok := bundledConPTY(filepath.Join("..", "..", "resources", "windows-"+runtime.GOARCH)); ok {
		out["bundled"] = c
	} else {
		t.Log("no bundled ConPTY in resources")
	}
	return out
}

// console is a program in a console, whose output it keeps.
type console struct {
	t    *testing.T
	proc *ptyProc
	mu   sync.Mutex
	out  strings.Builder
}

func startConsole(t *testing.T, cp conPTY, path string, args ...string) *console {
	t.Helper()
	return startConsoleWith(t, ptyOptions{Path: path, Args: args, conpty: cp})
}

func startConsoleWith(t *testing.T, o ptyOptions) *console {
	t.Helper()
	o.Dir, o.Env = t.TempDir(), testEnv(t)
	o.Cols, o.Rows = 160, 10 // wide enough for a prompt in a test's directory
	proc, err := startPTY(o)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(proc.Kill)
	c := &console{t: t, proc: proc}
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := proc.Read(buf)
			c.mu.Lock()
			c.out.Write(buf[:n])
			c.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	return c
}

// waitFor waits for the output from `from` on to match re, and returns
// the length of the output then.
func (c *console) waitFor(from int, re *regexp.Regexp, what string) int {
	c.t.Helper()
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		c.mu.Lock()
		s := c.out.String()
		c.mu.Unlock()
		if re.MatchString(s[from:]) {
			return len(s)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t.Fatalf("no %s in %q", what, c.out.String()[from:])
	return 0
}

// ClearScreen clears the console's screen too, which then draws its
// prompt's line on the first row: with it still on a lower row, PowerShell
// redraws (an inline prediction) would send the cursor back there.
func TestConsoleClearScreen(t *testing.T) {
	shell, err := exec.LookPath("pwsh")
	if err != nil {
		if shell, err = exec.LookPath("powershell"); err != nil {
			t.Skip("PowerShell not installed")
		}
	}
	for name, cp := range conPTYs(t) {
		t.Run(name, func(t *testing.T) {
			if cp.clear == nil && windows.RtlGetVersion().BuildNumber < 26100 {
				t.Skip("the console takes no clear signal before Windows 11 24H2")
			}
			c := startConsole(t, cp, shell, "pwsh", "-NoLogo", "-NoProfile")
			at := c.waitFor(0, regexp.MustCompile(`PS [^\r\n]*>`), "prompt")
			c.proc.Write([]byte("1..20\r"))
			at = c.waitFor(at, regexp.MustCompile(`\n20\r(.|\n)*PS [^\r\n]*>`), "prompt after the list")

			// Windows' own console draws its screen again, the bundled one
			// draws what is typed next: on the first row, both.
			c.proc.ClearScreen()
			time.Sleep(200 * time.Millisecond)
			c.proc.Write([]byte("a"))
			c.waitFor(at, regexp.MustCompile(`\x1b\[1;\d+H`), "cursor on the first row")
		})
	}
}

// Ctrl+C ends what runs in a console though the daemon ignores it, as it
// does in the process group of its own it is started in.
func TestConsoleCtrlC(t *testing.T) {
	procSetConsoleCtrlHandler.Call(0, 1)
	t.Cleanup(func() { procSetConsoleCtrlHandler.Call(0, 0) })
	ping, err := exec.LookPath("ping")
	if err != nil {
		t.Skip("no ping")
	}
	for name, cp := range conPTYs(t) {
		t.Run(name, func(t *testing.T) {
			c := startConsole(t, cp, ping, "ping", "-n", "60", "127.0.0.1")
			c.waitFor(0, regexp.MustCompile(`127\.0\.0\.1`), "ping")
			c.proc.Write([]byte("\x03"))
			select {
			case <-c.proc.exited:
			case <-time.After(10 * time.Second):
				t.Fatal("ping still runs after Ctrl+C")
			}
		})
	}
}

// A console that inherits the cursor asks the terminal where it is and
// draws from there: a restored pane's shell, under its history, has
// PowerShell's redraws (an inline prediction) on its prompt's row, not on
// the first.
func TestConsoleInheritCursor(t *testing.T) {
	shell, err := exec.LookPath("pwsh")
	if err != nil {
		if shell, err = exec.LookPath("powershell"); err != nil {
			t.Skip("PowerShell not installed")
		}
	}
	for name, cp := range conPTYs(t) {
		t.Run(name, func(t *testing.T) {
			c := startConsoleWith(t, ptyOptions{Path: shell, Args: []string{"pwsh", "-NoLogo", "-NoProfile"}, conpty: cp, InheritCursor: true})
			at := c.waitFor(0, regexp.MustCompile(`\x1b\[6n`), "cursor position request")
			c.proc.Write([]byte("\x1b[8;1R"))
			at = c.waitFor(at, regexp.MustCompile(`PS [^\r\n]*>`), "prompt")
			time.Sleep(200 * time.Millisecond)
			c.proc.Write([]byte("a"))
			c.waitFor(at, regexp.MustCompile(`\x1b\[8;\d+H`), "cursor on the prompt's row")
		})
	}
}

// A full-screen program that takes the mouse before it reads the console
// in VT input mode, as pi does, gets it: Windows' own ConPTY drops the
// mouse modes then, and the wheel comes as the arrow keys.
func TestConsoleMouseModesBeforeVTInput(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node.js not installed")
	}
	cp, ok := conPTYs(t)["bundled"]
	if !ok {
		t.Skip("no bundled ConPTY")
	}
	c := startConsole(t, cp, node, "node", "-e", `process.stdout.write("\x1b[?1049h\x1b[?1000h\x1b[?1006h");`+
		`process.stdin.setRawMode(true);`+
		`process.stdin.on("data",d=>process.stdout.write("got:"+JSON.stringify(d.toString())+"\r\n"))`)
	at := c.waitFor(0, regexp.MustCompile(`\x1b\[\?1000h(.|\n)*\x1b\[\?1006h`), "mouse modes")
	time.Sleep(200 * time.Millisecond)
	c.proc.Write([]byte("\x1b[<64;10;5M")) // the wheel rolled up
	c.waitFor(at, regexp.MustCompile(regexp.QuoteMeta(`got:"\u001b[<64;10;5M"`)), "the wheel's report")
}
