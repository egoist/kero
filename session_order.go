package main

import (
	"slices"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/locales"
)

// sessionDrag is a session dragged by its row in the sidebar to another
// place among the sessions of its project.
type sessionDrag struct {
	host *host
	id   string
}

// sessionMove is the session being dragged in the sidebar: which, of what
// host, and the place among the sessions of its project that it would go
// to if let go (before the session at that index; the count of them for
// the end), or -1 for nowhere new.
type sessionMove struct {
	host *host
	id   string
	at   int
}

// groupSessions returns the ids of the sessions of a host and a project, in
// the sidebar's order, which is kerod's.
func (a *App) groupSessions(h *host, project string) []string {
	var ids []string
	for _, s := range a.st.Sessions {
		if s.Project == project && a.hostOf(s.ID) == h {
			ids = append(ids, s.ID)
		}
	}
	return ids
}

// reorderSession moves a session to index among the sessions of its
// project, at once in the sidebar, then in kerod, which keeps the order.
func (a *App) reorderSession(id string, index int) {
	s := a.session(id)
	if s == nil {
		return
	}
	host, project := a.hostOf(id), s.Project
	ids := a.groupSessions(host, project)
	from := slices.Index(ids, id)
	if from < 0 {
		return
	}
	index = max(0, min(index, len(ids)-1))
	if index == from {
		return
	}
	a.st.Sessions = reorderSessions(a.st.Sessions, id, index, func(x proto.Session) bool {
		return x.Project == project && a.hostOf(x.ID) == host
	})
	// kerod counts the index among the sessions of the project too.
	a.call(id, "move", proto.MoveParams{ID: id, Index: index}, nil)
}

// reorderSessions moves the session id to index among the sessions mine
// tells are of its group, leaving the others where they are: the group's
// sessions take the places they had, in their new order.
func reorderSessions(all []proto.Session, id string, index int, mine func(proto.Session) bool) []proto.Session {
	var slots []int
	var own []proto.Session
	for i, s := range all {
		if mine(s) {
			slots = append(slots, i)
			own = append(own, s)
		}
	}
	from := slices.IndexFunc(own, func(s proto.Session) bool { return s.ID == id })
	if from < 0 {
		return all
	}
	s := own[from]
	own = slices.Delete(own, from, from+1)
	own = slices.Insert(own, max(0, min(index, len(own))), s)
	out := slices.Clone(all)
	for i, at := range slots {
		out[at] = own[i]
	}
	return out
}

// sessionTarget makes a session's row take a session dragged to another
// place among the sessions of its project: over it, the place the dragged
// session would go to is shown, before the row or after it by which half
// of it the pointer is in; let go, it moves there.
func (a *App) sessionTarget(row ui.Element, s *proto.Session) (over, before bool) {
	host := a.hostOf(s.ID)
	ids := a.groupSessions(host, s.Project)
	here := slices.Index(ids, s.ID)
	if here < 0 {
		return false, false
	}
	// The place a session dragged to this row would go to: before the
	// row, or after it.
	place := func() int {
		if _, y, in := row.PointerPosition(); in && y > row.Bounds().H/2 {
			return here + 1
		}
		return here
	}
	// The session dragged, when it is one of this row's own.
	dragged := func(d sessionDrag) bool {
		if d.host != host {
			return false
		}
		ds := a.session(d.id)
		return ds != nil && ds.Project == s.Project
	}
	if d, o := ui.DragOver[sessionDrag](row); o && dragged(d) {
		from := slices.Index(ids, d.id)
		// Where it is already shows nothing.
		if from >= 0 && place() != from && place() != from+1 {
			a.sessMove.host, a.sessMove.id, a.sessMove.at = host, d.id, place()
			return true, place() == here
		}
	}
	if d, ok := ui.Drop[sessionDrag](row); ok && dragged(d) {
		from := slices.Index(ids, d.id)
		if from >= 0 {
			id, to := d.id, insertionIndex(from, place())
			a.defer_(func() { a.reorderSession(id, to) })
		}
	}
	return false, false
}

// sessionInsertionLine shows, in the row a session is dragged over, the
// place it would go to: a line above the row, or below it.
func (a *App) sessionInsertionLine(c *ui.Context, pal *palette, before bool) {
	line := ui.Box(c.Key("insertion")).Absolute().Left(4).Right(4).Height(2).Radius(1).PassThrough().Background(pal.accent)
	if before {
		line.Top(-1)
	} else {
		line.Bottom(-1)
	}
}

// sessionMenuMove adds the session's moves among the sessions of its
// project.
func (a *App) sessionMenuMove(m *ui.Menu, s *proto.Session) {
	host := a.hostOf(s.ID)
	ids := a.groupSessions(host, s.Project)
	i := slices.Index(ids, s.ID)
	if i < 0 || len(ids) < 2 {
		return
	}
	last := len(ids) - 1
	m.Submenu(locales.SidebarMove(), func(m *ui.Menu) {
		if m.Item(locales.SidebarMoveUp()).Disabled(i == 0).Chosen() {
			a.defer_(func() { a.reorderSession(s.ID, i-1) })
		}
		if m.Item(locales.SidebarMoveDown()).Disabled(i == last).Chosen() {
			a.defer_(func() { a.reorderSession(s.ID, i+1) })
		}
		m.Separator()
		if m.Item(locales.SidebarMoveToTop()).Disabled(i == 0).Chosen() {
			a.defer_(func() { a.reorderSession(s.ID, 0) })
		}
		if m.Item(locales.SidebarMoveToBottom()).Disabled(i == last).Chosen() {
			a.defer_(func() { a.reorderSession(s.ID, last) })
		}
	})
}
