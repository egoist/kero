package daemon

import (
	"sync"
	"testing"

	"kero/internal/proto"
)

// A pane that splits another reads the other's directory and size, which
// change under the other's own lock: as its shell changes directory and
// the clients resize it. The split takes that lock too, so that the two
// do not read one field as the other writes it.
func TestSplitWhilePaneResizes(t *testing.T) {
	d := testDaemon(t)
	s := &session{id: "s1"}
	p, err := newPane(d, "s1", proto.Pane{ID: "a", Status: proto.Idle, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.term.Close() })
	s.panes, s.focus = []*pane{p}, "a"
	d.panes["a"] = p
	d.sessions = []*session{s}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := range 200 {
			p.resize(80+i%2, 24, 8, 16)
		}
	}()
	go func() {
		defer wg.Done()
		for range 3 {
			if _, err := d.split(proto.CreateParams{Split: "a"}); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	wg.Wait()
}
