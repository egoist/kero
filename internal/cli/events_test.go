package cli

import (
	"path/filepath"
	"slices"
	"testing"
	"time"

	"kero/internal/proto"
)

func TestDiffState(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	one := 1
	pane := func(id string, st proto.Status) proto.Pane { return proto.Pane{ID: id, Status: st} }
	prev := proto.State{Sessions: []proto.Session{
		{ID: "s1", Name: "api", Project: "pr", Panes: []proto.Pane{pane("p1", proto.Working), pane("p2", proto.Idle)}},
		{ID: "s2", Name: "old", Project: "pr", Panes: []proto.Pane{pane("p3", proto.Idle)}},
	}}
	waiting := pane("p1", proto.Waiting)
	waiting.Message, waiting.Kind, waiting.Agent, waiting.Since = "Allow Bash?", "permission", "claude", 1234
	ran := pane("p2", proto.Idle)
	ran.CommandExit = &one
	next := proto.State{Sessions: []proto.Session{
		{ID: "s1", Name: "backend", Project: "pr", Panes: []proto.Pane{waiting, ran, pane("p4", proto.Idle)}},
		{ID: "s3", Name: "new", Project: "pr2", Panes: []proto.Pane{pane("p5", proto.Working)}},
	}}
	evs := diffState(prev, next, time.UnixMilli(99))
	var got []string
	for _, e := range evs {
		got = append(got, e.Event+" "+e.Session+" "+e.Pane)
	}
	want := []string{
		"session.renamed s1 ",
		"pane.status s1 p1",
		"command.exited s1 p2",
		"pane.created s1 p4",
		"session.created s3 ",
		"pane.created s3 p5",
		"session.closed s2 ",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("events\n%q\nwant\n%q", got, want)
	}
	if e := evs[0]; e.From != "api" || e.To != "backend" {
		t.Errorf("renamed %+v", e)
	}
	if e := evs[1]; e.From != "working" || e.To != "waiting" || e.Message != "Allow Bash?" || e.Kind != "permission" || e.Agent != "claude" || e.Time != 1234 || e.ExitCode != nil {
		t.Errorf("status %+v", e)
	}
	if e := evs[2]; e.ExitCode == nil || *e.ExitCode != 1 {
		t.Errorf("command exited %+v", e)
	}
	if e := evs[6]; e.Name != "old" || e.Project != "pr" || e.Time != 99 {
		t.Errorf("closed %+v", e)
	}

	// A shell's exit tells its status; no change, no event.
	exited := pane("p3", proto.Exited)
	exited.ExitCode = 2
	after := proto.State{Sessions: []proto.Session{{ID: "s2", Name: "old", Panes: []proto.Pane{exited}}}}
	evs = diffState(prev, after, time.Now())
	if len(evs) != 2 || evs[0].Event != "pane.status" || evs[0].ExitCode == nil || *evs[0].ExitCode != 2 || evs[1].Event != "session.closed" {
		t.Errorf("exit %+v", evs)
	}
	if evs := diffState(next, next, time.Now()); len(evs) != 0 {
		t.Errorf("no change, %+v", evs)
	}
	// The pane of a closed session closes with it, as one event.
	gone := proto.State{Sessions: next.Sessions[1:]}
	if evs := diffState(next, gone, time.Now()); len(evs) != 1 || evs[0].Event != "session.closed" {
		t.Errorf("closed %+v", evs)
	}
}

func TestEventFilter(t *testing.T) {
	status := event{Event: "pane.status", Session: "s1", Pane: "p1", Project: "pr", To: "waiting"}
	other := event{Event: "pane.status", Session: "s1", Pane: "p2", Project: "pr", To: "idle"}
	renamed := event{Event: "session.renamed", Session: "s1", Project: "pr"}
	elsewhere := event{Event: "session.created", Session: "s2", Project: "pr2"}
	notice := event{Event: "notice", Session: "s1", Pane: "p2", Project: "pr"}
	for _, c := range []struct {
		name string
		f    eventFilter
		want []bool // status, other, renamed, elsewhere, notice
	}{
		{"all", eventFilter{}, []bool{true, true, true, true, true}},
		{"session", eventFilter{session: "s1"}, []bool{true, true, true, false, true}},
		{"pane", eventFilter{session: "s1", pane: "p1"}, []bool{true, false, true, false, false}},
		{"project", eventFilter{project: "pr2"}, []bool{false, false, false, true, false}},
		{"for", eventFilter{statuses: []string{"waiting", "error"}}, []bool{true, false, false, false, false}},
	} {
		var got []bool
		for _, e := range []event{status, other, renamed, elsewhere, notice} {
			got = append(got, c.f.match(e))
		}
		if !slices.Equal(got, c.want) {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
	f := eventFilter{session: "s1", pane: "p1"}
	if !f.gone(event{Event: "pane.closed", Session: "s1", Pane: "p1"}) || f.gone(event{Event: "pane.closed", Session: "s1", Pane: "p2"}) ||
		!f.gone(event{Event: "session.closed", Session: "s1"}) || (eventFilter{}).gone(event{Event: "session.closed", Session: "s1"}) {
		t.Error("gone")
	}
}

func TestEventLine(t *testing.T) {
	at := time.Date(2026, 10, 24, 12, 4, 31, 0, time.Local).UnixMilli()
	one := 1
	for _, c := range []struct {
		e    event
		want string
	}{
		{event{Event: "pane.status", Time: at, Session: "s1", Name: "api", Pane: "p1", From: "working", To: "waiting", Message: "Allow Bash?"},
			"12:04:31  api p1  working → waiting  Allow Bash?"},
		{event{Event: "pane.status", Time: at, Session: "s1", Name: "api", Pane: "p1", From: "idle", To: "exited", ExitCode: &one},
			"12:04:31  api p1  idle → exited (1)"},
		{event{Event: "command.exited", Time: at, Session: "s1", Name: "api", Pane: "p1", ExitCode: &one}, "12:04:31  api p1  command exited 1"},
		{event{Event: "session.created", Time: at, Session: "s1", Name: "api"}, "12:04:31  api  session created"},
		{event{Event: "notice", Time: at, Session: "s1", Name: "api", Title: "Claude", Body: "Done"}, "12:04:31  api  notice: Claude: Done"},
	} {
		if got := eventLine(c.e); got != c.want {
			t.Errorf("%q, want %q", got, c.want)
		}
	}
}

// A notice that comes before the state of its new session waits for it,
// to tell its project and name; the first state only starts the watch.
func TestFollower(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	empty := proto.State{}
	with := proto.State{Sessions: []proto.Session{{ID: "s1", Name: "api", Project: "pr", Panes: []proto.Pane{{ID: "p1"}}}}}
	notice := proto.Message{Event: "notice", Notice: &proto.Notice{Session: "s1", Pane: "p1", Body: "done"}}
	var w follower
	if evs := w.take(proto.Message{Event: "state", State: &empty}, time.Now()); len(evs) != 0 {
		t.Fatalf("first state %+v", evs)
	}
	if evs := w.take(notice, time.Now()); len(evs) != 0 {
		t.Fatalf("notice before its session %+v", evs)
	}
	evs := w.take(proto.Message{Event: "state", State: &with}, time.Now())
	var got []string
	for _, e := range evs {
		got = append(got, e.Event)
	}
	if !slices.Equal(got, []string{"session.created", "pane.created", "notice"}) {
		t.Fatalf("events %q", got)
	}
	if e := evs[2]; e.Project != "pr" || e.Name != "api" || e.Pane != "p1" || e.Body != "done" {
		t.Errorf("notice %+v", e)
	}
	if evs := w.take(notice, time.Now()); len(evs) != 1 || evs[0].Project != "pr" {
		t.Errorf("notice of a known session %+v", evs)
	}
}

func TestEventFilterPresent(t *testing.T) {
	st := proto.State{Sessions: []proto.Session{{ID: "s1", Panes: []proto.Pane{{ID: "p1"}}}}}
	for _, c := range []struct {
		f    eventFilter
		want bool
	}{
		{eventFilter{}, true},
		{eventFilter{session: "s1"}, true},
		{eventFilter{session: "s1", pane: "p1"}, true},
		{eventFilter{session: "s1", pane: "p2"}, false},
		{eventFilter{session: "s2"}, false},
	} {
		if got := c.f.present(st); got != c.want {
			t.Errorf("%+v: %v, want %v", c.f, got, c.want)
		}
	}
}
