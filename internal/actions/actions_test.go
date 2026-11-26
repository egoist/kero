package actions

import "testing"

// The keys an action had by default are gone while another action holds
// them, and come back when it lets them go.
func TestKeysTakenComeBack(t *testing.T) {
	down, ok := Find("pane.split.down")
	if !ok {
		t.Fatal("no such action")
	}
	right, ok := Find("pane.split.right")
	if !ok {
		t.Fatal("no such action")
	}
	// Split Right takes Split Down's keys.
	overrides := map[string]string{right.ID: down.Keys}
	if got := Keys(down, overrides); got != "" {
		t.Errorf("Split Down kept its keys: %q", got)
	}
	// Split Right lets them go: Split Down has its own again.
	delete(overrides, right.ID)
	if got := Keys(down, overrides); got != down.Keys {
		t.Errorf("Split Down did not get its keys back: %q", got)
	}
}

// The keys the user gave an action are its own, and the keys another
// action holds are not its own, whatever it had by default.
func TestKeysAreTheUsersOwn(t *testing.T) {
	down, ok := Find("pane.split.down")
	if !ok {
		t.Fatal("no such action")
	}
	right, ok := Find("pane.split.right")
	if !ok {
		t.Fatal("no such action")
	}
	overrides := map[string]string{down.ID: "Ctrl+Alt+K"}
	if got := Keys(down, overrides); got != "Ctrl+Alt+K" {
		t.Errorf("Split Down's own keys: %q", got)
	}
	if got := Keys(right, overrides); got != right.Keys {
		t.Errorf("Split Right's keys: %q", got)
	}
}
