package daemon

import (
	"slices"
	"testing"

	"kero/internal/proto"
)

func sessionOrder(d *Daemon) []string {
	ids := make([]string, 0, len(d.sessions))
	for _, s := range d.sessions {
		ids = append(ids, s.id)
	}
	return ids
}

// A session moves among the sessions of its project, the index counting
// them, and the sessions of the other projects staying where they are.
func TestMoveSessionWithinProject(t *testing.T) {
	d := projectDaemon(t)
	d.sessions = []*session{
		{id: "s1", project: "p1"},
		{id: "s2", project: "p2"},
		{id: "s3", project: "p1"},
		{id: "s4", project: "p1"},
		{id: "s5", project: "p2"},
	}
	for _, tc := range []struct {
		id    string
		index int
		want  []string
	}{
		// The last session of the project goes to the front of it.
		{"s4", 0, []string{"s4", "s1", "s2", "s3", "s5"}},
		// The second session of the project goes after the first.
		{"s3", 1, []string{"s4", "s3", "s1", "s2", "s5"}},
		// A session of the other project goes among its own.
		{"s5", 0, []string{"s4", "s3", "s1", "s5", "s2"}},
	} {
		if err := d.move(proto.MoveParams{ID: tc.id, Index: tc.index}); err != nil {
			t.Fatal(err)
		}
		if got := sessionOrder(d); !slices.Equal(got, tc.want) {
			t.Errorf("move %s to %d: %v, want %v", tc.id, tc.index, got, tc.want)
		}
	}
}
