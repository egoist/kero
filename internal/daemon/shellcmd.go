package daemon

import (
	"path/filepath"
	"runtime"
	"strings"
)

// shellName is a shell's name, as the sidebar shows it: "zsh", "pwsh".
func shellName(shell string) string {
	name := filepath.Base(shell)
	if runtime.GOOS == "windows" {
		name = strings.ToLower(strings.TrimSuffix(name, filepath.Ext(name)))
	}
	return name
}

// posixShell tells a shell that takes -l, -i and -c, as sh does.
func posixShell(name string) bool {
	switch name {
	case "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "yash":
		return true
	}
	return false
}

// shellArgs is the argv that starts shell, running command first when set,
// with bin first on PATH when set (binFirst).
func shellArgs(shell, bin string, command []string) []string {
	name := shellName(shell)
	switch {
	case name == "pwsh" || name == "powershell":
		return powershellArgs(name, command)
	case name == "cmd":
		if len(command) == 0 {
			return []string{name}
		}
		return []string{name, "/K", cmdJoin(command)}
	case runtime.GOOS == "windows" && !posixShell(name):
		return append([]string{name}, command...)
	}
	if len(command) == 0 {
		if runtime.GOOS == "windows" {
			// Windows takes argv[0] from the path: no "-bash" there.
			return []string{name, "-l", "-i"}
		}
		if bin != "" && name == "fish" {
			return []string{"-" + name, "-C", fishBinFirst(bin)}
		}
		return []string{"-" + name}
	}
	// The command runs in an interactive login shell, so that it finds
	// what the user's profile puts on PATH; the session goes on with the
	// shell once it ends, after telling its exit status (OSC 133;D).
	status := `"$?"`
	if name == "fish" {
		status = "$status"
	}
	again := "exec " + shellQuote(name, shell) + " -l"
	pre := ""
	if bin != "" {
		switch name {
		case "fish":
			again += " -C " + shellQuote(name, fishBinFirst(bin))
		case "zsh":
			again = "exec env ZDOTDIR=" + shellQuote(name, zdotdir(bin)) + " " + shellQuote(name, shell) + " -l"
		}
		if name != "fish" {
			pre = "PATH=" + shellQuote(name, bin) + `:"$PATH"; `
		}
	}
	script := pre + shellJoin(name, command) + `; printf '\033]133;D;%s\007' ` + status + "; " + again
	if name == "fish" {
		// fish leaves job control off for -c, so the command would run in
		// the shell's process group, where tick doesn't see it.
		script = "status job-control full; " + script
		if bin != "" {
			return []string{name, "-l", "-i", "-C", fishBinFirst(bin), "-c", script}
		}
	}
	return []string{name, "-l", "-i", "-c", script}
}

// marksExit tells whether shellArgs has the shell tell when the command
// ends: all but cmd and other shells of Windows' own.
func marksExit(shell string) bool {
	name := shellName(shell)
	switch {
	case name == "pwsh" || name == "powershell":
		return true
	case name == "cmd", runtime.GOOS == "windows" && !posixShell(name):
		return false
	}
	return true
}

// powershellPrompt wraps PowerShell's prompt, after the profile made it:
// it makes the process's directory the shell's location, which cd leaves
// alone, so that the sidebar sees where the shell is (procCwd).
const powershellPrompt = `$global:__keroPrompt=$function:prompt;` +
	`function global:prompt{if($PWD.Provider.Name -eq 'FileSystem'){[Environment]::CurrentDirectory=$PWD.ProviderPath};& $global:__keroPrompt}`

const powershellExit = `$__keroOk=$?; $__keroCode=$LASTEXITCODE; ` +
	`[Console]::Write("$([char]27)]133;D;$(if ($__keroOk) {0} elseif ($__keroCode) {$__keroCode} else {1})$([char]7)")`

func powershellArgs(name string, command []string) []string {
	script := powershellPrompt
	if len(command) > 0 {
		// Then its exit status (OSC 133;D): a program's, else 1 for a
		// cmdlet that failed.
		script += "; " + powershellJoin(command) + "; " + powershellExit
	}
	// -NoExit: the session goes on with the shell once the command ends.
	return []string{name, "-NoLogo", "-NoExit", "-Command", script}
}

// shellQuote quotes an argument for a shell's command line.
func shellQuote(shell, s string) string {
	if s != "" && strings.IndexFunc(s, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-_./=:,+@%", r))
	}) < 0 {
		return s
	}
	switch shell {
	case "fish":
		return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(s) + "'"
	case "pwsh", "powershell":
		return "'" + strings.ReplaceAll(s, "'", "''") + "'"
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// oneLine tells a command given as one line, as `kero new -- "npm run
// dev"` gives it, which the shell runs as it is.
func oneLine(args []string) bool {
	return len(args) == 1 && strings.ContainsAny(args[0], " ;|&")
}

func shellJoin(shell string, args []string) string {
	if oneLine(args) {
		return args[0]
	}
	q := make([]string, len(args))
	for i, a := range args {
		q[i] = shellQuote(shell, a)
	}
	return strings.Join(q, " ")
}

// powershellJoin writes a command for PowerShell, which runs a quoted
// program's name only after its call operator.
func powershellJoin(args []string) string {
	if oneLine(args) {
		return args[0]
	}
	return "& " + shellJoin("pwsh", args)
}

// cmdJoin writes a command for cmd.exe.
func cmdJoin(args []string) string {
	if oneLine(args) {
		return args[0]
	}
	q := make([]string, len(args))
	for i, a := range args {
		q[i] = a
		if a == "" || strings.ContainsAny(a, " \t\"&|<>^%") {
			q[i] = `"` + strings.ReplaceAll(a, `"`, `\"`) + `"`
		}
	}
	return strings.Join(q, " ")
}
