package daemon

import (
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"
)

// A command a session starts with runs in a process group of its own, in
// the terminal's foreground, so that tick sees it; on Windows, as the
// shell's child.
func TestCommandInForeground(t *testing.T) {
	shells, command, want := []string{"fish", "zsh", "bash"}, []string{"sleep", "5"}, "sleep"
	if runtime.GOOS == "windows" {
		shells, command, want = []string{"pwsh", "powershell", "cmd"}, []string{"ping", "-n", "6", "127.0.0.1"}, "ping"
	}
	for _, name := range shells {
		t.Run(name, func(t *testing.T) {
			shell, err := exec.LookPath(name)
			if err != nil {
				t.Skip(name, "not installed")
			}
			proc, err := startPTY(ptyOptions{
				Path: shell, Args: shellArgs(shell, "", command),
				Dir: t.TempDir(), Env: testEnv(t),
				Cols: 80, Rows: 24,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer proc.Kill()
			go func() {
				buf := make([]byte, 4096)
				for {
					if _, err := proc.Read(buf); err != nil {
						return
					}
				}
			}()
			for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
				if pg := proc.Foreground(); pg != 0 && pg != proc.PID() && strings.EqualFold(procName(pg), want) {
					return
				}
			}
			t.Fatalf("foreground %d is not %s's (shell %d)", proc.Foreground(), want, proc.PID())
		})
	}
}

// A shell tells when the command a session starts with ends, with its
// exit status, and goes on.
func TestCommandTellsExit(t *testing.T) {
	shells, command := []string{"fish", "zsh", "bash", "dash"}, []string{"sh", "-c", "exit 3"}
	if runtime.GOOS == "windows" {
		shells, command = []string{"pwsh", "powershell"}, []string{"cmd", "/c", "exit 3"}
	}
	for _, name := range shells {
		t.Run(name, func(t *testing.T) {
			shell, err := exec.LookPath(name)
			if err != nil {
				t.Skip(name, "not installed")
			}
			if !marksExit(shell) {
				t.Fatal("marksExit is false")
			}
			proc, err := startPTY(ptyOptions{
				Path: shell, Args: shellArgs(shell, "", command),
				Dir: t.TempDir(), Env: testEnv(t),
				Cols: 80, Rows: 24,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer proc.Kill()
			got := make(chan string, 16)
			go func() {
				var o oscScanner
				buf := make([]byte, 4096)
				for {
					n, err := proc.Read(buf)
					o.scan(buf[:n], func(b []byte) { got <- string(b) }, func() {})
					if err != nil {
						return
					}
				}
			}()
			for timeout := time.After(10 * time.Second); ; {
				select {
				case b := <-got:
					if strings.HasPrefix(b, "133;D") {
						if b != "133;D;3" {
							t.Fatalf("got %q, want 133;D;3", b)
						}
						return
					}
				case <-timeout:
					t.Fatal("no OSC 133;D")
				}
			}
		})
	}
}

func testEnv(t *testing.T) []string {
	if runtime.GOOS != "windows" {
		return []string{"HOME=" + t.TempDir(), "TERM=xterm-256color"}
	}
	// Windows' programs need its own variables to start.
	return append(exec.Command("cmd").Environ(), "TERM=xterm-256color")
}
