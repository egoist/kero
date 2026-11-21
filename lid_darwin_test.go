package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/locales"
)

// lidHelperTest is the lid helper in a folder of its own, where pmset is
// a fake that keeps the Mac's state in files, the mark is a file too, and
// the helper looks again every 50ms, not 5s.
type lidHelperTest struct {
	t   *testing.T
	dir string
}

func newLidHelperTest(t *testing.T) *lidHelperTest {
	dir := t.TempDir()
	script := lidHelperScript
	for _, r := range [][2]string{
		{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "PATH=" + dir + ":/usr/bin:/bin:/usr/sbin:/sbin"},
		{"mark=/var/db/sh.kero.lid-awake", "mark=" + dir + "/mark"},
		{"sleep 5 &", "sleep 0.05 &"},
	} {
		if !strings.Contains(script, r[0]) {
			t.Fatalf("the helper has no %q", r[0])
		}
		script = strings.ReplaceAll(script, r[0], r[1])
	}
	pmset := `#!/bin/sh
d=$(dirname "$0")
case "$*" in
"-g") printf ' SleepDisabled\t\t%s\n' "$(cat "$d/disabled")" ;;
"-g batt") cat "$d/batt" ;;
"-a disablesleep "*) echo "$3" > "$d/disabled"; echo "$3" >> "$d/log" ;;
*) exit 1 ;;
esac
`
	h := &lidHelperTest{t, dir}
	h.write("helper", script, 0o755)
	h.write("pmset", pmset, 0o755)
	h.write("log", "", 0o644)
	h.set("0", lidAC)
	return h
}

const lidAC = "Now drawing from 'AC Power'\n"

func lidBattery(pct int) string {
	return fmt.Sprintf("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t%d%%; discharging; 1:00 remaining present: true\n", pct)
}

func (h *lidHelperTest) write(name, s string, mode os.FileMode) {
	if err := os.WriteFile(filepath.Join(h.dir, name), []byte(s), mode); err != nil {
		h.t.Fatal(err)
	}
}

func (h *lidHelperTest) read(name string) string {
	b, _ := os.ReadFile(filepath.Join(h.dir, name))
	return strings.TrimSpace(string(b))
}

// set gives the Mac's SleepDisabled, and its power as pmset -g batt says.
func (h *lidHelperTest) set(disabled, batt string) {
	h.write("disabled", disabled+"\n", 0o644)
	h.write("batt", batt, 0o644)
}

func (h *lidHelperTest) marked() bool {
	_, err := os.Stat(filepath.Join(h.dir, "mark"))
	return err == nil
}

func (h *lidHelperTest) start(arg string) *exec.Cmd {
	cmd := exec.Command(filepath.Join(h.dir, "helper"), arg)
	if err := cmd.Start(); err != nil {
		h.t.Fatal(err)
	}
	return cmd
}

// until waits for ok, for a second at most.
func (h *lidHelperTest) until(what string, ok func() bool) {
	h.t.Helper()
	for range 100 {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	h.t.Fatalf("%s: SleepDisabled %q, mark %v, pmset set %q", what, h.read("disabled"), h.marked(), h.read("log"))
}

// ends waits for cmd to exit, for a second at most.
func (h *lidHelperTest) ends(cmd *exec.Cmd) {
	h.t.Helper()
	done := make(chan struct{})
	go func() { cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		cmd.Process.Kill()
		h.t.Fatal("the helper didn't stop")
	}
}

// sleeper is a process for the helper to wait on.
func sleeper(t *testing.T) *exec.Cmd {
	p := exec.Command("/bin/sleep", "30")
	if err := p.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Process.Kill(); p.Wait() })
	return p
}

func TestLidHelperHoldsWhileKeroRuns(t *testing.T) {
	h := newLidHelperTest(t)
	kero := sleeper(t)
	helper := h.start(fmt.Sprint(kero.Process.Pid))
	h.until("sleep turned off", func() bool { return h.read("disabled") == "1" && h.marked() })
	kero.Process.Kill()
	kero.Wait()
	h.ends(helper)
	if h.read("disabled") != "0" || h.marked() || h.read("log") != "1\n0" {
		t.Errorf("Kero gone: SleepDisabled %q, mark %v, pmset set %q", h.read("disabled"), h.marked(), h.read("log"))
	}
}

func TestLidHelperLetsGoOnTERM(t *testing.T) {
	h := newLidHelperTest(t)
	helper := h.start(fmt.Sprint(os.Getpid()))
	h.until("sleep turned off", func() bool { return h.read("disabled") == "1" })
	helper.Process.Signal(syscall.SIGTERM)
	h.ends(helper)
	if h.read("disabled") != "0" || h.marked() {
		t.Errorf("sent TERM: SleepDisabled %q, mark %v", h.read("disabled"), h.marked())
	}
}

// Another app turned sleep off: the helper leaves it to that app, and
// turns sleep off itself once the app turns it on again.
func TestLidHelperLeavesAnotherApps(t *testing.T) {
	h := newLidHelperTest(t)
	h.set("1", lidAC)
	kero := sleeper(t)
	helper := h.start(fmt.Sprint(kero.Process.Pid))
	time.Sleep(200 * time.Millisecond)
	if h.read("log") != "" || h.marked() {
		t.Fatalf("the helper took another app's: pmset set %q, mark %v", h.read("log"), h.marked())
	}
	h.set("0", lidAC)
	h.until("sleep turned off once the other app let go", func() bool { return h.read("disabled") == "1" && h.marked() })
	helper.Process.Signal(syscall.SIGTERM)
	h.ends(helper)

	h.write("log", "", 0o644)
	h.set("1", lidAC)
	helper = h.start(fmt.Sprint(kero.Process.Pid))
	time.Sleep(200 * time.Millisecond)
	helper.Process.Signal(syscall.SIGTERM)
	h.ends(helper)
	if h.read("disabled") != "1" || h.read("log") != "" {
		t.Errorf("the helper undid another app's: SleepDisabled %q, pmset set %q", h.read("disabled"), h.read("log"))
	}
}

func TestLidHelperLowBattery(t *testing.T) {
	h := newLidHelperTest(t)
	h.set("0", lidBattery(8))
	kero := sleeper(t)
	helper := h.start(fmt.Sprint(kero.Process.Pid))
	time.Sleep(200 * time.Millisecond)
	if h.read("disabled") != "0" {
		t.Fatal("sleep turned off at 8%")
	}
	h.write("batt", lidBattery(50), 0o644)
	h.until("sleep turned off at 50%", func() bool { return h.read("disabled") == "1" })
	h.write("batt", lidBattery(10), 0o644)
	h.until("sleep back on at 10%", func() bool { return h.read("disabled") == "0" && !h.marked() })
	helper.Process.Signal(syscall.SIGTERM)
	h.ends(helper)
}

// release undoes what a helper left, as when Kero crashed or the Mac lost
// power, and nothing else.
func TestLidHelperRelease(t *testing.T) {
	h := newLidHelperTest(t)
	h.set("1", lidBattery(50))
	h.write("mark", "", 0o644)
	h.ends(h.start("release"))
	if h.read("disabled") != "0" || h.marked() {
		t.Errorf("released: SleepDisabled %q, mark %v", h.read("disabled"), h.marked())
	}
	h.set("1", lidBattery(50))
	h.ends(h.start("release"))
	if h.read("disabled") != "1" {
		t.Error("release turned sleep on for another app")
	}
}

func TestLidHelperArgs(t *testing.T) {
	h := newLidHelperTest(t)
	for _, arg := range []string{"", "12x", "-1", "$(id)"} {
		cmd := h.start(arg)
		h.ends(cmd)
		if code := cmd.ProcessState.ExitCode(); code != 2 {
			t.Errorf("%q: exit %d, want 2", arg, code)
		}
	}
	if h.read("log") != "" {
		t.Errorf("pmset set %q", h.read("log"))
	}
}

// The install script carries the helper and the rule in itself, which
// decode as they were, and visudo finds the rule sound.
func TestLidInstallScript(t *testing.T) {
	rule := fmt.Sprintf("#%d ALL=(root) NOPASSWD: %s\n", os.Getuid(), lidHelper)
	sh := lidInstallScript(lidHelperScript, rule, lidHelper, lidSudoers())
	if out, err := exec.Command("/bin/sh", "-n", "-c", sh).CombinedOutput(); err != nil {
		t.Fatalf("sh -n: %v %s", err, out)
	}
	for _, want := range []string{lidHelperScript, rule} {
		b64 := base64.StdEncoding.EncodeToString([]byte(want))
		if !strings.Contains(sh, "/bin/echo "+b64+" | /usr/bin/base64 -D > ") {
			t.Fatalf("the script doesn't carry %q", want)
		}
		got, err := exec.Command("/bin/sh", "-c", "/bin/echo "+b64+" | /usr/bin/base64 -D").Output()
		if err != nil || string(got) != want {
			t.Errorf("decoded %q, %v; want %q", got, err, want)
		}
	}
	f := filepath.Join(t.TempDir(), "rule")
	os.WriteFile(f, []byte(rule), 0o440)
	if out, err := exec.Command("/usr/sbin/visudo", "-cqf", f).CombinedOutput(); err != nil {
		t.Errorf("visudo: %v %s", err, out)
	}
	if strings.Contains(filepath.Base(lidSudoers()), ".") {
		t.Errorf("sudo skips %s, as its name has a dot", lidSudoers())
	}
}

// AppleScript reads a quoted string back as it was.
func TestAppleScriptString(t *testing.T) {
	s := "a \"quoted\" back\\slash\nand a line\n"
	out, err := exec.Command("/usr/bin/osascript", "-e", "return "+appleScriptString(s)).Output()
	if err != nil {
		t.Fatal(err)
	}
	// osascript ends what it prints with a newline of its own.
	if got := strings.TrimSuffix(string(out), "\n"); got != s {
		t.Errorf("osascript read %q, want %q", got, s)
	}
}

// Without the helper, a hold asks nothing of sudo, which would ask for a
// password.
func TestLidHoldWithoutHelper(t *testing.T) {
	if lidHelperInstalled() {
		t.Skip("the lid helper is installed")
	}
	var w lidHold
	w.hold(true)
	if w.holding() {
		t.Error("a hold runs without the helper")
	}
	w.hold(false)
}

// Stay awake with the lid closed shows in Settings while a mode keeps
// the Mac awake.
func TestKeepAwakeLidRow(t *testing.T) {
	a := testApp(t)
	a.ss.page = "general"
	tt := ui.NewTester(a.settingsView, 820, 2400)
	tt.Frame()
	// Keep computer awake's detail names the row too: its own detail is
	// the row's alone.
	if tt.HasText(locales.AwakeLidDetail()) {
		t.Error("Stay awake with the lid closed shows while Keep computer awake is off")
	}
	a.set.KeepAwake = awakeOn
	tt.Frame()
	tt.Frame()
	if !tt.HasText(locales.AwakeLidDetail()) {
		t.Errorf("no %q; texts %q", locales.AwakeLidDetail(), tt.Texts())
	}
}

// A password not given turns the setting back off, and says nothing; an
// install that failed says why.
func TestLidInstalled(t *testing.T) {
	a := testApp(t)
	a.setKeepAwakeLidClosed(true)
	a.lidInstalled(errCanceled)
	if a.set.KeepAwakeLidClosed || a.ss.toast != "" {
		t.Errorf("canceled: setting %v, toast %q", a.set.KeepAwakeLidClosed, a.ss.toast)
	}
	a.setKeepAwakeLidClosed(true)
	a.lidInstalled(errors.New("visudo: bad rule"))
	if a.set.KeepAwakeLidClosed || !strings.Contains(a.ss.toast, "visudo: bad rule") {
		t.Errorf("failed: setting %v, toast %q", a.set.KeepAwakeLidClosed, a.ss.toast)
	}
	a.ss.toast = ""
	a.setKeepAwakeLidClosed(true)
	a.lidInstalled(nil)
	if !a.set.KeepAwakeLidClosed || a.ss.toast != "" {
		t.Errorf("installed: setting %v, toast %q", a.set.KeepAwakeLidClosed, a.ss.toast)
	}
}
