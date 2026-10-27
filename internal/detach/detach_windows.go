// Package detach starts programs that outlive whoever started them, as
// kerod, which the app, the CLI and a bridge start, and which starts the
// kerod that follows it as it restarts.
package detach

import (
	"encoding/base64"
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var isProcessInJob = windows.NewLazySystemDLL("kernel32.dll").NewProc("IsProcessInJob")

// Start starts cmd, returning what runs it, without a console and out of
// whatever job holds this process, so that it outlives whoever started
// it. A job that lets nothing leave it, as Windows' SSH server's, which
// ends what runs in it as the connection ends, is left through WMI: the
// command that started it then returns, ended.
func Start(cmd *exec.Cmd) (*exec.Cmd, error) {
	const flags = windows.CREATE_NEW_PROCESS_GROUP | windows.DETACHED_PROCESS
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: flags | windows.CREATE_BREAKAWAY_FROM_JOB}
	if err := cmd.Start(); err == nil {
		return cmd, nil
	}
	if inJob() {
		if w, err := wmiStart(cmd); err == nil {
			return w, nil
		}
	}
	c := exec.Command(cmd.Path, cmd.Args[1:]...)
	c.Dir, c.Env, c.Stdin, c.Stdout, c.Stderr = cmd.Dir, cmd.Env, cmd.Stdin, cmd.Stdout, cmd.Stderr
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: flags}
	return c, c.Start()
}

func inJob() bool {
	var in int32
	r, _, _ := isProcessInJob.Call(uintptr(windows.CurrentProcess()), 0, uintptr(unsafe.Pointer(&in)))
	return r != 0 && in != 0
}

// wmiStart starts cmd through WMI, whose provider starts it as this user,
// in no job, with cmd's environment and directory, but none of its
// files: kerod writes its log itself. The script goes to PowerShell on
// its standard input, as the environment may be longer than a command
// line takes, which reads it in the console's code page: the script is
// ASCII, what it passes on in base64 of UTF-8.
func wmiStart(cmd *exec.Cmd) (*exec.Cmd, error) {
	env := cmd.Env
	if env == nil {
		env = os.Environ()
	}
	b64 := func(s string) string { return "'" + base64.StdEncoding.EncodeToString([]byte(s)) + "'" }
	var vars []string
	for _, kv := range env {
		// The variables of drives cmd keeps, as =C:=C:\, are no one's.
		if !strings.HasPrefix(kv, "=") {
			vars = append(vars, b64(kv))
		}
	}
	dir := cmd.Dir
	if dir == "" {
		dir, _ = os.Getwd()
	}
	line := windows.ComposeCommandLine(append([]string{cmd.Path}, cmd.Args[1:]...))
	script := `$ErrorActionPreference = 'Stop'; ` +
		`function d($s) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) }; ` +
		`$vars = [string[]]@(@(` + strings.Join(vars, ", ") + `) | ForEach-Object { d $_ }); ` +
		`$si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow = [uint16]0; EnvironmentVariables = $vars}; ` +
		`$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = (d ` + b64(line) + `); CurrentDirectory = (d ` + b64(dir) + `); ProcessStartupInformation = $si}; ` +
		`if ($r.ReturnValue -eq 0) { 'started' }` + "\r\n"
	w := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "-")
	w.Stdin = strings.NewReader(script)
	w.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	out, err := w.Output()
	if err == nil && !strings.Contains(string(out), "started") {
		err = errors.New("WMI did not start " + cmd.Path)
	}
	return w, err
}
