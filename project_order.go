package main

import (
	"slices"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/locales"
)

// projectDrag is a project dragged by its header in the sidebar to another
// place among its host's projects.
type projectDrag struct {
	host *host
	id   string
}

// projectMove is the project being dragged in the sidebar: which, of what
// host, and the place among the host's projects that it would go to if let
// go (before the project at that index; the count of them for the end), or
// -1 for nowhere new.
type projectMove struct {
	host *host
	id   string
	at   int
}

// hostProjects returns the ids of a host's projects, in the sidebar's order,
// which is kerod's.
func (a *App) hostProjects(h *host) []string {
	var ids []string
	for _, p := range a.st.Projects {
		if a.hostOf(p.ID) == h {
			ids = append(ids, p.ID)
		}
	}
	return ids
}

// moveProject moves a project to index among its host's projects, at once
// in the sidebar, then in kerod, which keeps the order.
func (a *App) moveProject(id string, index int) {
	h := a.hostOf(id)
	ids := a.hostProjects(h)
	from := slices.Index(ids, id)
	if from < 0 {
		return
	}
	index = max(0, min(index, len(ids)-1))
	if index == from {
		return
	}
	a.st.Projects = reorderProjects(a.st.Projects, id, index, func(p proto.Project) bool { return a.hostOf(p.ID) == h })
	a.call(id, "project.move", proto.MoveProjectParams{ID: id, Index: index}, nil)
}

// reorderProjects moves the project id to index among the projects mine
// tells are of its host, leaving the others where they are: the host's
// projects take the places they had, in their new order.
func reorderProjects(all []proto.Project, id string, index int, mine func(proto.Project) bool) []proto.Project {
	var slots []int
	var own []proto.Project
	for i, p := range all {
		if mine(p) {
			slots = append(slots, i)
			own = append(own, p)
		}
	}
	from := slices.IndexFunc(own, func(p proto.Project) bool { return p.ID == id })
	if from < 0 {
		return all
	}
	p := own[from]
	own = slices.Delete(own, from, from+1)
	own = slices.Insert(own, max(0, min(index, len(own))), p)
	out := slices.Clone(all)
	for i, at := range slots {
		out[at] = own[i]
	}
	return out
}

// insertionIndex is the index a project at from goes to once put before
// the project at place (len for the end), among the same projects.
func insertionIndex(from, place int) int {
	if place > from {
		return place - 1
	}
	return place
}

// projectTarget makes a group of the sidebar take a project dragged from
// its host: over it, the place the project would go to is before the group
// or after it, by which half of the group the pointer is in; let go, it
// moves there.
func (a *App) projectTarget(grp ui.Element, g group, at int) {
	if g.project.ID == "" {
		return
	}
	ids := a.hostProjects(g.host)
	here := slices.Index(ids, g.project.ID)
	if here < 0 {
		return
	}
	if d, over := ui.DragOver[projectDrag](grp); over && d.host == g.host {
		if _, y, in := grp.PointerPosition(); in {
			place := here
			if y > grp.Bounds().H/2 {
				place++
			}
			from := slices.Index(ids, d.id)
			// Where it is already shows nothing.
			if from >= 0 && place != from && place != from+1 {
				a.projMove.at = place
			}
		}
	}
	if d, ok := ui.Drop[projectDrag](grp); ok && d.host == g.host && at >= 0 {
		from := slices.Index(ids, d.id)
		if from >= 0 {
			id, to := d.id, insertionIndex(from, at)
			a.defer_(func() { a.moveProject(id, to) })
		}
	}
}

// projectMenu adds the project's menu its moves among its host's projects.
func (a *App) projectMenu(m *ui.Menu, g group) {
	id := g.project.ID
	ids := a.hostProjects(g.host)
	i := slices.Index(ids, id)
	if id == "" || i < 0 || len(ids) < 2 {
		return
	}
	last := len(ids) - 1
	m.Submenu(locales.SidebarMove(), func(m *ui.Menu) {
		if m.Item(locales.SidebarMoveUp()).Disabled(i == 0).Chosen() {
			a.moveProject(id, i-1)
		}
		if m.Item(locales.SidebarMoveDown()).Disabled(i == last).Chosen() {
			a.moveProject(id, i+1)
		}
		m.Separator()
		if m.Item(locales.SidebarMoveToTop()).Disabled(i == 0).Chosen() {
			a.moveProject(id, 0)
		}
		if m.Item(locales.SidebarMoveToBottom()).Disabled(i == last).Chosen() {
			a.moveProject(id, last)
		}
	})
}

// insertionLine shows, in a group of the host whose project is dragged,
// the place the project would go to: a line in the gap above the group, or
// below the host's last.
func (a *App) insertionLine(c *ui.Context, pal *palette, g group, gi, at int) {
	ids := a.hostProjects(g.host)
	here := slices.Index(ids, g.project.ID)
	if here < 0 {
		return
	}
	line := func() ui.Element {
		return ui.Box(c.Key("insertion")).Absolute().Left(4).Right(4).Height(2).Radius(1).PassThrough().Background(pal.accent)
	}
	switch {
	case at == here:
		// In the middle of the margin above the header.
		top := float32(18)
		if gi == 0 {
			top = 2
		}
		line().Top(top/2 - 1)
	case at == len(ids) && here == len(ids)-1:
		line().Bottom(-10)
	}
}
