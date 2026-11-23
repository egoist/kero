package main

import (
	"os/exec"
	"slices"
	"testing"
)

// A hold asks caffeinate to keep the display on only as Keep display on
// asks, and swaps its caffeinate for a new one as that changes.
func TestAwakeHoldDisplay(t *testing.T) {
	var w awakeHold
	t.Cleanup(func() { w.hold(false, false) })
	display := func() bool { return slices.Contains(w.cmd.Args, "-d") }

	w.hold(true, false)
	if w.cmd == nil || display() {
		t.Fatalf("holding without the display: caffeinate %v", w.cmd)
	}
	first := w.cmd
	w.hold(true, false)
	if w.cmd != first {
		t.Error("the same hold started another caffeinate")
	}

	w.hold(true, true)
	if w.cmd == nil || !display() {
		t.Fatalf("holding with the display: caffeinate %v", w.cmd)
	}
	if first.ProcessState == nil {
		t.Error("the caffeinate without the display still runs")
	}

	second := w.cmd
	w.hold(false, true)
	if w.cmd != nil || w.display {
		t.Errorf("let go: caffeinate %v, display %v", w.cmd, w.display)
	}
	if second.ProcessState == nil {
		t.Error("the caffeinate still runs once let go")
	}
}

func TestCaffeinateArgs(t *testing.T) {
	if got, want := caffeinateArgs(false, 7), []string{"-i", "-s", "-w", "7"}; !slices.Equal(got, want) {
		t.Errorf("without the display: %q, want %q", got, want)
	}
	if got, want := caffeinateArgs(true, 7), []string{"-i", "-s", "-d", "-w", "7"}; !slices.Equal(got, want) {
		t.Errorf("with the display: %q, want %q", got, want)
	}
}

// A caffeinate that does not start leaves the old one holding: the Mac
// does not sleep between them.
func TestAwakeHoldKeepsTheOldOne(t *testing.T) {
	var w awakeHold
	t.Cleanup(func() { w.hold(false, false) })
	w.hold(true, false)
	first := w.cmd
	if first == nil {
		t.Fatal("no caffeinate")
	}
	// The new one does not start.
	old := caffeinateCmd
	caffeinateCmd = func(bool) *exec.Cmd { return exec.Command("/nonexistent/caffeinate") }
	t.Cleanup(func() { caffeinateCmd = old })
	w.hold(true, true)
	if w.cmd != first {
		t.Errorf("the hold is %v, want the caffeinate that was holding", w.cmd)
	}
	if first.ProcessState != nil {
		t.Error("the caffeinate that was holding was killed")
	}
}
