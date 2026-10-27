package tailscale

import "testing"

func TestAllowed(t *testing.T) {
	alice := Who{Login: "alice@example.com", Node: "laptop"}
	bob := Who{Login: "bob@example.com", Node: "desk"}
	ci := Who{Node: "runner", Tags: []string{"tag:ci"}}
	for _, c := range []struct {
		who   Who
		owner string
		allow []string
		ok    bool
	}{
		{alice, "alice@example.com", nil, true},
		{alice, "ALICE@example.com", nil, true},
		{bob, "alice@example.com", nil, false},
		{bob, "alice@example.com", []string{"bob@example.com"}, true},
		{bob, "alice@example.com", []string{"*"}, true},
		{ci, "alice@example.com", []string{"*"}, false},
		{ci, "alice@example.com", []string{"tag:ci"}, true},
		{ci, "alice@example.com", []string{"tag:*"}, true},
		{ci, "alice@example.com", []string{"tag:prod"}, false},
		// A tagged machine has no owner: only listen-allow lets anyone in.
		{alice, "", nil, false},
		{alice, "", []string{"alice@example.com"}, true},
		// No one is "".
		{Who{}, "", []string{""}, false},
	} {
		if got := Allowed(c.who, c.owner, c.allow); got != c.ok {
			t.Errorf("Allowed(%v, %q, %q) = %v", c.who, c.owner, c.allow, got)
		}
	}
}
