package service

import (
	"encoding/binary"
	"errors"
	"fmt"
	"html"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"

	"golang.org/x/sys/windows"

	"kero/internal/proto"
)

// On Windows kerod runs as a task of the user's in Task Scheduler,
// \Kero\kerod, which needs no administrator: it starts as the user logs
// on, in their session, with their credentials, and runs while they are
// logged on, as launchd's agent does on macOS. conhost --headless runs it
// without a window, which kero.exe, a console program, would have.

func task() string { return `\Kero\` + Name() }

// file is the task as Install registered it, which tells it is installed
// without asking Task Scheduler.
func file() string { return filepath.Join(proto.Dir(), Name()+".task.xml") }

// definition is the task that runs exe's kerod. Task Scheduler starts it
// again should it fail, never more than one.
func definition(exe, account string) string {
	conhost := filepath.Join(os.Getenv("SystemRoot"), "System32", "conhost.exe")
	if os.Getenv("SystemRoot") == "" {
		conhost = `C:\Windows\System32\conhost.exe`
	}
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Kero's daemon, which runs the sessions: written by kero daemon install-service.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>%[1]s</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>%[1]s</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>%[2]s</Command>
      <Arguments>--headless "%[3]s" daemon serve</Arguments>
      <WorkingDirectory>%[4]s</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
`, html.EscapeString(account), html.EscapeString(conhost), html.EscapeString(exe), html.EscapeString(proto.Home()))
}

// utf16File is s as schtasks reads a task: UTF-16, with its mark.
func utf16File(s string) []byte {
	u := utf16.Encode([]rune("\ufeff" + strings.ReplaceAll(s, "\n", "\r\n")))
	b := make([]byte, 2*len(u))
	for i, c := range u {
		binary.LittleEndian.PutUint16(b[2*i:], c)
	}
	return b
}

func schtasks(args ...string) error {
	cmd := exec.Command("schtasks.exe", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("schtasks %s: %s", args[0], strings.TrimSpace(string(out)))
	}
	return nil
}

// Install registers the task for exe and starts it. A kerod already
// running, which the app or a bridge started, is stopped first (stop):
// the task's starts its sessions again.
func Install(exe string, stop func() error) error {
	u, err := user.Current()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(file()), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(file(), utf16File(definition(exe, u.Username)), 0o600); err != nil {
		return err
	}
	if err := schtasks("/Create", "/TN", task(), "/XML", file(), "/F"); err != nil {
		os.Remove(file())
		return err
	}
	if stop != nil {
		stop()
	}
	// Not waited for, nor needed: the task runs only while the user is
	// logged on, and kerod else starts as Kero connects.
	schtasks("/Run", "/TN", task())
	return nil
}

// EnableLinger does nothing on Windows: the task runs while its user is
// logged on.
func EnableLinger() error { return nil }

// Uninstall removes the task. Its kerod runs on, as any.
func Uninstall() error {
	if !Installed() {
		return nil
	}
	schtasks("/Delete", "/TN", task(), "/F")
	return os.Remove(file())
}

// Start runs the task, and waits for its kerod: none starts while no one
// is logged on to the machine, as over SSH only. The task runs again each
// second, as Task Scheduler ignores a run while the task's last kerod,
// which just stopped as it restarts, has not ended.
func Start() error {
	if err := schtasks("/Run", "/TN", task()); err != nil {
		return err
	}
	for i := 1; i <= 100; i++ {
		if running() {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
		if i%20 == 0 {
			schtasks("/Run", "/TN", task())
		}
	}
	return errors.New("the task did not start kerod: it runs only while you are logged on to the machine")
}

func running() bool {
	c, err := net.DialTimeout("unix", proto.SocketPath(), time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// Restart and Stop are kero's: it stops kerod as it stops any, which then
// saves its sessions, and starts the task again.
func Restart() error { return ErrUnsupported }
func Stop() error    { return ErrUnsupported }

// Get tells how the task stands.
func Get() Status {
	st := Status{File: file(), Installed: Installed(), Linger: true}
	if st.Installed {
		st.Running = running()
		st.Detail = "the task " + task()
		if st.Running {
			st.Detail += ", running"
		}
	}
	return st
}
