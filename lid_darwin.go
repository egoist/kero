package main

import (
	_ "embed"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

// lidAwake tells that Kero can keep the computer awake with its lid
// closed on battery: a Mac, by the lid helper.
const lidAwake = true

// lidHelper is the lid helper, scripts/kero-lid-awake.sh, as Kero
// installs it: a script root owns, which a rule in sudoers.d lets the
// user who installed it run as root without a password.
const lidHelper = "/Library/PrivilegedHelperTools/sh.kero.lid-awake"

//go:embed scripts/kero-lid-awake.sh
var lidHelperScript string

// lidSudoers is the rule's file, one for each user: sudo skips a file of
// sudoers.d whose name has a dot.
func lidSudoers() string {
	return "/etc/sudoers.d/kero-lid-awake-" + strconv.Itoa(os.Getuid())
}

// errCanceled is the password's dialog closed without a password.
var errCanceled = errors.New("canceled")

// lidHold keeps the Mac awake with its lid closed while it holds, on
// battery too, by the lid helper, which waits on Kero's pid: it lets the
// Mac sleep again when it is sent TERM, or as Kero exits.
type lidHold struct {
	cmd     *exec.Cmd
	done    chan struct{} // closed as cmd exits
	started bool          // the helper undid what a Kero before left
}

func (w *lidHold) hold(on bool) {
	if !w.started {
		w.started = true
		if lidHelperInstalled() {
			exec.Command("/usr/bin/sudo", "-n", lidHelper, "release").Run()
		}
	}
	if on == w.holding() {
		return
	}
	if !on {
		w.cmd.Process.Signal(syscall.SIGTERM) // sudo passes it on to the helper
		<-w.done
		w.cmd = nil
		return
	}
	if !lidHelperInstalled() {
		return
	}
	cmd := exec.Command("/usr/bin/sudo", "-n", lidHelper, strconv.Itoa(os.Getpid()))
	if cmd.Start() != nil {
		return
	}
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		close(done)
	}()
	w.cmd, w.done = cmd, done
}

// holding tells whether the helper runs: it stops by itself if sudo
// finds no rule for it, as when another user installed it.
func (w *lidHold) holding() bool {
	if w.cmd == nil {
		return false
	}
	select {
	case <-w.done:
		w.cmd = nil
		return false
	default:
		return true
	}
}

// removeLidHelper removes the lid helper, as Stay awake with the lid
// closed turned off asks: the helper itself, by sudo without a password,
// lets the Mac sleep if it kept it awake, and deletes this user's rule,
// and itself once no other user's is left. Without this user's rule,
// there is nothing of theirs to remove.
var removeLidHelper = func() {
	if _, err := os.Stat(lidSudoers()); err != nil {
		return
	}
	exec.Command("/usr/bin/sudo", "-n", lidHelper, "remove").Run()
}

// lidHelperInstalled tells whether the lid helper this Kero carries is
// installed, with this user's rule.
func lidHelperInstalled() bool {
	b, err := os.ReadFile(lidHelper)
	if err != nil || string(b) != lidHelperScript {
		return false
	}
	_, err = os.Stat(lidSudoers())
	return err == nil
}

// installLidHelper installs the lid helper and this user's rule, asking
// for an administrator's password, with prompt, as macOS does: what root
// writes comes in the command itself, not in a file the user could
// change before root reads it. It is errCanceled if the user closes the
// dialog.
func installLidHelper(prompt string) error {
	rule := fmt.Sprintf("#%d ALL=(root) NOPASSWD: %s\n", os.Getuid(), lidHelper)
	script := `do shell script ` + appleScriptString(lidInstallScript(lidHelperScript, rule, lidHelper, lidSudoers())) +
		` with prompt ` + appleScriptString(prompt) + ` with administrator privileges`
	out, err := exec.Command("/usr/bin/osascript", "-e", script).CombinedOutput()
	switch {
	case err == nil:
		return nil
	case strings.Contains(string(out), "(-128)"):
		return errCanceled
	}
	return errors.New(strings.TrimSpace(string(out)))
}

// lidInstallScript is the shell script that installs the helper, script,
// at helper, and the rule at sudoers, as root: each written beside its
// place first and moved there, the rule once visudo finds it sound.
func lidInstallScript(script, rule, helper, sudoers string) string {
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	return fmt.Sprintf(`set -e
trap '/bin/rm -f %[2]s.new %[4]s.new' EXIT
/bin/mkdir -p /Library/PrivilegedHelperTools
/bin/echo %[1]s | /usr/bin/base64 -D > %[2]s.new
/usr/sbin/chown root:wheel %[2]s.new
/bin/chmod 755 %[2]s.new
/bin/mv -f %[2]s.new %[2]s
/bin/echo %[3]s | /usr/bin/base64 -D > %[4]s.new
/usr/sbin/visudo -cqf %[4]s.new
/usr/sbin/chown root:wheel %[4]s.new
/bin/chmod 440 %[4]s.new
/bin/mv -f %[4]s.new %[4]s
`, b64(script), helper, b64(rule), sudoers)
}

// appleScriptString quotes s as an AppleScript string.
func appleScriptString(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)
	return `"` + r.Replace(s) + `"`
}
