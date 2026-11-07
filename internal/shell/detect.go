package shell

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Entry is a shell offered by the launcher and Settings.
type Entry struct {
	Name, Path string
}

// Detect probes executables, never starts them.
func Detect() []Entry {
	var out []Entry
	seen := map[string]bool{}
	add := func(name, path string) {
		p, err := exec.LookPath(path)
		if err != nil || seen[name] {
			return
		}
		seen[name] = true
		out = append(out, Entry{name, p})
	}
	if runtime.GOOS == "windows" {
		add("PowerShell 7", "pwsh.exe")
		for _, root := range []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles(Arm)")} {
			if root != "" {
				add("PowerShell 7", filepath.Join(root, "PowerShell", "7", "pwsh.exe"))
			}
		}
		root := os.Getenv("SystemRoot")
		if root == "" {
			root = `C:\Windows`
		}
		add("Windows PowerShell", filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"))
		add("Windows PowerShell", "powershell.exe")
		add("Command Prompt", os.Getenv("ComSpec"))
		add("Command Prompt", filepath.Join(root, "System32", "cmd.exe"))
		for _, root := range []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)")} {
			if root != "" {
				add("Git Bash", filepath.Join(root, "Git", "bin", "bash.exe"))
			}
		}
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			add("Git Bash", filepath.Join(local, "Programs", "Git", "bin", "bash.exe"))
		}
		if git, err := exec.LookPath("git.exe"); err == nil {
			add("Git Bash", filepath.Join(filepath.Dir(git), "..", "bin", "bash.exe"))
		}
		add("Nushell", "nu.exe")
	} else {
		add(filepath.Base(Login()), Login())
		for _, name := range []string{"bash", "zsh", "fish", "nu", "pwsh", "sh", "ksh", "dash", "tcsh", "csh", "elvish", "xonsh"} {
			add(name, name)
		}
		data, _ := os.ReadFile("/etc/shells")
		for _, line := range strings.Split(string(data), "\n") {
			path := strings.TrimSpace(strings.SplitN(line, "#", 2)[0])
			if filepath.IsAbs(path) {
				add(filepath.Base(path), path)
			}
		}
	}
	return out
}

// Inventory puts the configured shell first, retaining its exact command.
func Inventory(detected []Entry, configured string) []Entry {
	program := configured
	if program == "" {
		program = Login()
	}
	current := Entry{filepath.Base(program), program}
	var rest []Entry
	for _, e := range detected {
		if SameProgram(e.Path, program) {
			current.Name = e.Name
		} else {
			rest = append(rest, e)
		}
	}
	return append([]Entry{current}, rest...)
}

// SameProgram resolves bare commands through PATH, without conflating installs.
func SameProgram(a, b string) bool {
	resolve := func(p string) string {
		if found, err := exec.LookPath(p); err == nil {
			p = found
		}
		if abs, err := filepath.Abs(p); err == nil {
			p = abs
		}
		return filepath.Clean(p)
	}
	a, b = resolve(a), resolve(b)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}
