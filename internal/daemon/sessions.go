package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"kero/internal/proto"
)

// session is a row of the sidebar: a task's panes, in a layout. d.mu
// guards its fields.
type session struct {
	id, project, name string
	agentNamed        bool // name is an agent's (proto.Session.AgentNamed)
	created           int64
	restored          bool
	panes             []*pane
	layout            *proto.Layout
	focus, zoomed     string
}

// state returns what the subscribers see.
func (d *Daemon) state() proto.State {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.stateLocked()
}

// stateLocked is state, with d.mu held.
func (d *Daemon) stateLocked() proto.State {
	st := proto.State{
		Projects: slices.Clone(d.projects),
		Sessions: make([]proto.Session, 0, len(d.sessions)),
		Viewed:   d.viewedID(),
		Started:  d.started.UnixMilli(),
	}
	for _, s := range d.sessions {
		st.Sessions = append(st.Sessions, d.sessionInfo(s))
	}
	return st
}

// sessionInfo describes a session; d.mu is held.
func (d *Daemon) sessionInfo(s *session) proto.Session {
	info := proto.Session{
		ID: s.id, Project: s.project, Name: s.name, AgentNamed: s.agentNamed,
		Layout: s.layout.Clone(), Focus: s.focus, Zoomed: s.zoomed,
		Panes: make([]proto.Pane, 0, len(s.panes)),
	}
	// Panes in the layout's order: left to right, top to bottom.
	order := s.layout.Panes()
	panes := slices.Clone(s.panes)
	slices.SortStableFunc(panes, func(a, b *pane) int {
		return slices.Index(order, a.info.ID) - slices.Index(order, b.info.ID)
	})
	for _, p := range panes {
		p.mu.Lock()
		pi := p.info
		pi.Command = slices.Clone(pi.Command)
		pi.Records = slices.Clone(pi.Records)
		p.mu.Unlock()
		info.Panes = append(info.Panes, pi)
	}
	if i := proto.Lead(info.Panes, s.focus); i >= 0 {
		info.Pane = info.Panes[i]
		info.Lead = info.Panes[i].ID
	}
	info.Created, info.Restored = s.created, s.restored
	return info
}

func (d *Daemon) findPaneLocked(id string) *pane {
	if p := d.panes[id]; p != nil {
		return p
	}
	return nil
}

// findSessionLocked finds a session by id, a unique prefix of it, its
// name, or one of its panes; d.mu is held.
func (d *Daemon) findSessionLocked(ref string) *session {
	if ref == "" {
		return nil
	}
	for _, s := range d.sessions {
		if s.id == ref {
			return s
		}
	}
	if p := d.panes[ref]; p != nil {
		return d.sessionOfLocked(p)
	}
	var found *session
	for _, s := range d.sessions {
		if strings.HasPrefix(s.id, ref) || s.name != "" && strings.EqualFold(s.name, ref) {
			if found != nil && found != s {
				return nil
			}
			found = s
		}
	}
	return found
}

func (d *Daemon) sessionOfLocked(p *pane) *session {
	for _, s := range d.sessions {
		if s.id == p.sid {
			return s
		}
	}
	return nil
}

// findPane finds a pane by its id, or a session's focused pane.
func (d *Daemon) findPane(ref string) *pane {
	d.mu.Lock()
	defer d.mu.Unlock()
	if p := d.panes[ref]; p != nil {
		return p
	}
	// A unique prefix of a pane's id.
	var found *pane
	for id, p := range d.panes {
		if ref != "" && strings.HasPrefix(id, ref) {
			if found != nil {
				found = nil
				break
			}
			found = p
		}
	}
	if found != nil {
		return found
	}
	if s := d.findSessionLocked(ref); s != nil {
		return focusedLocked(s)
	}
	return nil
}

// agentPane finds the pane an agent's hook tells of, from the hook's
// process pid: the pane whose shell runs it. An agent's service that
// panes share, as Codex's app server, runs its hooks with the
// environment of the pane that started it, and under that pane's shell
// when it started it, which names no pane to trust: then the pane is
// the one that can only be the agent's, its only pane yet to tell a
// session (or, of several, the only one in the agent's dir), else its
// only pane; away tells it.
func (d *Daemon) agentPane(pid int, agent, dir string) (found *pane, away bool) {
	d.mu.Lock()
	panes := make([]*pane, 0, len(d.panes))
	for _, p := range d.panes {
		panes = append(panes, p)
	}
	d.mu.Unlock()
	byShell := make(map[int]*pane, len(panes))
	var running, pending, inDir []*pane
	for _, p := range panes {
		p.mu.Lock()
		if p.info.Status != proto.Exited {
			if p.shellPID > 0 {
				byShell[p.shellPID] = p
			}
			if p.info.Agent == agent {
				running = append(running, p)
				if p.info.AgentSession == nil {
					pending = append(pending, p)
					if dir != "" && p.info.WorkDir() == dir {
						inDir = append(inDir, p)
					}
				}
			}
		}
		p.mu.Unlock()
	}
	for i := 0; i < 64 && pid > 1 && !sharedService(pid); i++ {
		if p := byShell[pid]; p != nil {
			return p, false
		}
		pid = procParent(pid)
	}
	switch {
	case len(pending) == 1:
		return pending[0], true
	case len(pending) > 1:
		if len(inDir) == 1 {
			return inDir[0], true
		}
	case len(running) == 1:
		return running[0], true
	}
	return nil, true
}

// sharedService tells a process of an agent's service that panes share:
// Codex's app server as the daemon its TUIs connect to (daemon_auto_start),
// which the first pane to run Codex starts, and runs every pane's hooks.
func sharedService(pid int) bool {
	args := procArgs(pid)
	return slices.Contains(args, "app-server") && slices.Contains(args, "--managed-daemon")
}

// focusedLocked returns a session's focused pane, else its first; d.mu is
// held.
func focusedLocked(s *session) *pane {
	for _, p := range s.panes {
		if p.info.ID == s.focus {
			return p
		}
	}
	if order := s.layout.Panes(); len(order) > 0 {
		for _, p := range s.panes {
			if p.info.ID == order[0] {
				return p
			}
		}
	}
	if len(s.panes) > 0 {
		return s.panes[0]
	}
	return nil
}

func (d *Daemon) cleanDir(dir string) (string, error) {
	if dir == "" {
		return "", nil
	}
	dir = expandHome(dir)
	if abs, err := filepath.Abs(dir); err == nil {
		dir = abs
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", fmt.Errorf("no directory %s", dir)
	}
	return dir, nil
}

// startPane makes a pane and starts its shell; a browser's has none, nor
// a file's.
func (d *Daemon) startPane(sid string, p proto.CreateParams, dir string) (*pane, error) {
	now := time.Now().UnixMilli()
	info := proto.Pane{
		ID: newID(), Dir: dir, Command: p.Command, Status: proto.Idle, Since: now, Created: now,
		Cols: p.Cols, Rows: p.Rows,
	}
	if p.URL != "" && p.File == "" {
		info.URL, info.Command = proto.BrowserURL(p.URL), nil
	}
	if p.File != "" {
		info.URL, info.File, info.Command = "", p.File, nil
		if info.Dir == "" {
			info.Dir = filepath.Dir(p.File)
		}
	}
	pn, err := newPane(d, sid, info)
	if err != nil || pn.info.Shown() {
		return pn, err
	}
	if err := pn.start(p.Command, p.Env); err != nil {
		pn.term.Close()
		return nil, err
	}
	return pn, nil
}

// create starts a session, or a pane of one with p.Split.
func (d *Daemon) create(p proto.CreateParams) (proto.Session, error) {
	if p.Split != "" {
		return d.split(p)
	}
	dir, err := d.cleanDir(p.Dir)
	if err != nil {
		return proto.Session{}, err
	}
	d.mu.Lock()
	project := d.projectFor(p.Project, dir)
	if dir == "" {
		for _, pr := range d.projects {
			if pr.ID == project {
				dir = pr.Dir
			}
		}
	}
	d.mu.Unlock()
	s := &session{id: newID(), project: project, name: strings.TrimSpace(p.Name), created: time.Now().UnixMilli()}
	pn, err := d.startPane(s.id, p, dir)
	if err != nil {
		return proto.Session{}, err
	}
	s.panes, s.focus = []*pane{pn}, pn.info.ID
	d.mu.Lock()
	i := len(d.sessions)
	if p.After != "" {
		if after := d.findSessionLocked(p.After); after != nil {
			i = slices.Index(d.sessions, after) + 1
		}
	}
	d.sessions = slices.Insert(d.sessions, i, s)
	d.panes[pn.info.ID] = pn
	info := d.sessionInfo(s)
	d.mu.Unlock()
	d.changed()
	d.log.Printf("session %s created in %s", s.id, dir)
	return info, nil
}

// split starts a pane beside another, in its session.
func (d *Daemon) split(p proto.CreateParams) (proto.Session, error) {
	d.mu.Lock()
	at := d.findPaneLocked(p.Split)
	var s *session
	if at != nil {
		s = d.sessionOfLocked(at)
	} else if s = d.findSessionLocked(p.Split); s != nil {
		at = focusedLocked(s)
	}
	if s == nil || at == nil {
		d.mu.Unlock()
		return proto.Session{}, fmt.Errorf("no session or pane %q", p.Split)
	}
	dir := at.info.Dir
	if p.Cols == 0 {
		// Half of the pane split, as a start: the view sets the size.
		p.Cols, p.Rows = at.info.Cols, at.info.Rows
		if p.Direction == "down" || p.Direction == "up" {
			p.Rows = max(p.Rows/2, 4)
		} else {
			p.Cols = max(p.Cols/2, 10)
		}
	}
	sid, atID := s.id, at.info.ID
	d.mu.Unlock()
	if p.Dir != "" {
		var err error
		if dir, err = d.cleanDir(p.Dir); err != nil {
			return proto.Session{}, err
		}
	}
	pn, err := d.startPane(sid, p, dir)
	if err != nil {
		return proto.Session{}, err
	}
	d.mu.Lock()
	if !slices.Contains(d.sessions, s) {
		d.mu.Unlock()
		pn.close()
		return proto.Session{}, errors.New("the session closed")
	}
	if s.layout == nil {
		s.layout = &proto.Layout{Pane: s.panes[0].info.ID}
	}
	s.layout = s.layout.Split(atID, pn.info.ID, p.Direction, p.Ratio)
	s.panes = append(s.panes, pn)
	s.focus, s.zoomed = pn.info.ID, ""
	d.panes[pn.info.ID] = pn
	info := d.sessionInfo(s)
	d.mu.Unlock()
	d.changed()
	d.log.Printf("pane %s split from %s", pn.info.ID, atID)
	return info, nil
}

// removePane closes a pane; its session goes with its last pane.
func (d *Daemon) removePane(id string) error {
	d.mu.Lock()
	p := d.panes[id]
	if p == nil {
		d.mu.Unlock()
		return fmt.Errorf("no pane %s", id)
	}
	delete(d.panes, id)
	s := d.sessionOfLocked(p)
	if s != nil {
		s.panes = slices.DeleteFunc(s.panes, func(o *pane) bool { return o == p })
		if s.layout != nil {
			// The focus goes to the neighbor taking the room.
			if s.focus == id {
				for _, dir := range []string{"left", "up", "right", "down"} {
					if n := s.layout.Neighbor(id, dir); n != "" {
						s.focus = n
						break
					}
				}
			}
			s.layout = s.layout.Remove(id)
			if s.layout.Leaf() {
				s.layout = nil
			}
		}
		if s.zoomed == id {
			s.zoomed = ""
		}
		if len(s.panes) == 0 {
			d.sessions = slices.DeleteFunc(d.sessions, func(o *session) bool { return o == s })
		} else if s.focus == id {
			s.focus = s.panes[0].info.ID
		}
	}
	d.mu.Unlock()
	p.close()
	os.Remove(d.historyPath(id))
	d.changed()
	d.log.Printf("pane %s closed", id)
	return nil
}

// removeSession closes a session and its panes.
func (d *Daemon) removeSession(ref string) error {
	d.mu.Lock()
	s := d.findSessionLocked(ref)
	if s == nil {
		d.mu.Unlock()
		return fmt.Errorf("no session %s", ref)
	}
	d.sessions = slices.DeleteFunc(d.sessions, func(o *session) bool { return o == s })
	panes := s.panes
	for _, p := range panes {
		delete(d.panes, p.info.ID)
	}
	d.mu.Unlock()
	for _, p := range panes {
		p.close()
		os.Remove(d.historyPath(p.info.ID))
	}
	d.changed()
	d.log.Printf("session %s closed", s.id)
	return nil
}

func (d *Daemon) move(p proto.MoveParams) error {
	d.mu.Lock()
	defer func() {
		d.mu.Unlock()
		d.changed()
	}()
	s := d.findSessionLocked(p.ID)
	if s == nil {
		return fmt.Errorf("no session %s", p.ID)
	}
	if p.Project != "" {
		s.project = d.projectFor(p.Project, "")
	}
	i := slices.Index(d.sessions, s)
	d.sessions = slices.Delete(d.sessions, i, i+1)
	// Index counts the project's sessions: insert before the one there.
	at, n := len(d.sessions), 0
	for j, o := range d.sessions {
		if o.project != s.project {
			continue
		}
		if p.Index >= 0 && n == p.Index {
			at = j
			break
		}
		n++
		at = j + 1
	}
	d.sessions = slices.Insert(d.sessions, at, s)
	return nil
}

// sameLeaves reports whether a layout shows exactly a session's panes.
func sameLeaves(l *proto.Layout, panes []*pane) bool {
	got := l.Panes()
	if len(got) != len(panes) {
		return false
	}
	for _, p := range panes {
		if !slices.Contains(got, p.info.ID) {
			return false
		}
	}
	return true
}
