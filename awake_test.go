package main

import (
	"testing"

	"kero/internal/proto"
)

func TestAnyWorking(t *testing.T) {
	local := func(id string) bool { return id != "remote" }
	for _, c := range []struct {
		name     string
		sessions []proto.Session
		want     bool
	}{
		{"none", nil, false},
		{"idle", []proto.Session{{ID: "a", Status: proto.Idle, Panes: []proto.Pane{{Status: proto.Idle}}}}, false},
		{"working", []proto.Session{{ID: "a", Status: proto.Working, Panes: []proto.Pane{{Status: proto.Working}}}}, true},
		// The session shows the waiting pane's status; the agent beside it
		// still works.
		{"behind a waiting pane", []proto.Session{{ID: "a", Status: proto.Waiting, Panes: []proto.Pane{
			{ID: "p1", Status: proto.Waiting}, {ID: "p2", Status: proto.Working},
		}}}, true},
		{"behind unread output", []proto.Session{{ID: "a", Status: proto.Idle, Panes: []proto.Pane{
			{ID: "p1", Status: proto.Idle, Unread: true}, {ID: "p2", Status: proto.Working},
		}}}, true},
		{"another host's", []proto.Session{{ID: "remote", Status: proto.Working, Panes: []proto.Pane{{Status: proto.Working}}}}, false},
	} {
		if got := anyWorking(c.sessions, local); got != c.want {
			t.Errorf("%s: anyWorking = %v, want %v", c.name, got, c.want)
		}
	}
}
