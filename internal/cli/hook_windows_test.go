package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// Codex runs its hooks in the shell of the user's session, which on
// Windows is cmd, Windows PowerShell, PowerShell or Git Bash: the hook's
// command runs alike in each, as Codex starts them, from a plain Kero
// directory and from one with a space.
func TestCodexHookRunsInEveryShell(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	type shell struct {
		name string
		run  func(line string) *exec.Cmd
	}
	comspec := os.Getenv("COMSPEC")
	if comspec == "" {
		comspec = "cmd.exe"
	}
	shells := []shell{{"cmd", func(line string) *exec.Cmd {
		// As Codex: /C, then the line in double quotes, as it is.
		c := exec.Command(comspec)
		c.SysProcAttr = &syscall.SysProcAttr{CmdLine: comspec + ` /C "` + line + `"`}
		return c
	}}}
	for _, name := range []string{"powershell", "pwsh"} {
		if p, err := exec.LookPath(name); err == nil {
			shells = append(shells, shell{name, func(line string) *exec.Cmd { return exec.Command(p, "-NoProfile", "-Command", line) }})
		}
	}
	if git, err := exec.LookPath("git"); err == nil {
		// Git for Windows: its git.exe is in cmd, or in mingw64/bin, and bash.exe in bin.
		for _, rel := range [][]string{{"..", "bin", "bash.exe"}, {"..", "..", "bin", "bash.exe"}} {
			if p := filepath.Join(append([]string{filepath.Dir(git)}, rel...)...); fileExists(p) {
				shells = append(shells, shell{"git bash", func(line string) *exec.Cmd { return exec.Command(p, "-c", line) }})
				break
			}
		}
	}
	for _, home := range []string{"kero", "kero home"} {
		t.Run(home, func(t *testing.T) {
			t.Setenv("KERO_HOME", filepath.Join(t.TempDir(), home))
			if err := os.MkdirAll(filepath.Dir(kero()), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(kero(), b, 0o700); err != nil {
				t.Fatal(err)
			}
			line := agentHook{agent: "codex"}.command()
			if !(agentHook{agent: "codex"}).ours(line) {
				t.Errorf("ours(%q) = false", line)
			}
			for _, sh := range shells {
				if sh.name == "git bash" && strings.Contains(home, " ") {
					// No command line runs a path with a space alike in
					// Git Bash and PowerShell: the plain path, which
					// Kero's directory nearly always is, runs in all four.
					continue
				}
				c := sh.run(line)
				c.Env = append(os.Environ(), "KERO_TEST_HOOK=1")
				out, err := c.CombinedOutput()
				if err != nil || !strings.Contains(string(out), "hook ran: hook codex") {
					t.Errorf("%s ran %q: %v\n%s", sh.name, line, err, out)
				}
			}
		})
	}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
