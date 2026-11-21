package main

import "testing"

func TestExecutionState(t *testing.T) {
	for _, c := range []struct {
		on, display bool
		want        uintptr
	}{
		{false, false, esContinuous},
		{true, false, esContinuous | esSystemRequired},
		{true, true, esContinuous | esSystemRequired | esDisplayRequired},
	} {
		if got := executionState(c.on, c.display); got != c.want {
			t.Errorf("executionState(%v, %v) = %#x, want %#x", c.on, c.display, got, c.want)
		}
	}
}
