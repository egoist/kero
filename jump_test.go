package main

import (
	"testing"

	"kero/internal/proto"
)

// Jumping to a session that needs the user shows it: the group it is in
// opens, or the session is nowhere to be seen.
func TestJumpToOpensTheGroup(t *testing.T) {
	a := testApp(t)
	// A remote host with a session of no project: its group is the
	// host's, not the empty project id.
	h := &host{name: "box"}
	a.hosts = append(a.hosts, h)
	a.st.Sessions = append(a.st.Sessions, proto.Session{
		ID: "s2", Name: "far", Unread: true,
		Panes: []proto.Pane{{ID: "c", Shell: "zsh", Dir: "/tmp", Status: proto.Idle, Progress: -1}},
		Focus: "c",
	})
	a.owner = map[string]*host{"s2": h, "c": h}
	a.prefs.Collapsed["other:box"] = true
	a.jumpToAttention()
	if a.selected != "s2" {
		t.Fatalf("the session jumped to is %q, want s2", a.selected)
	}
	if a.prefs.Collapsed["other:box"] {
		t.Error("the group of the session stayed collapsed")
	}
}
