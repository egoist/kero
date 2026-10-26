package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"kero/internal/proto"
	"kero/internal/settings"
)

// The daemon keeps its projects and sessions in state.json, and each
// session's screen and scrollback in sessions/<id>.vt, so that after the
// daemon itself ends, as when the Mac restarts, the next one starts every
// session again where it was, with what it showed.

type savedState struct {
	Version  int             `json:"version"`
	Projects []proto.Project `json:"projects"`
	Sessions []savedSession  `json:"sessions"`
	Saved    int64           `json:"saved"`
}

type savedSession struct {
	ID         string          `json:"id"`
	Project    string          `json:"project"`
	Name       string          `json:"name,omitempty"`
	AgentNamed bool            `json:"agentNamed,omitempty"`
	Created    int64           `json:"created"`
	Layout     *proto.Layout   `json:"layout,omitempty"`
	Focus      string          `json:"focus,omitempty"`
	Panes      []savedPane     `json:"panes"`
	Worktree   *proto.Worktree `json:"worktree,omitempty"`
}

type savedPane struct {
	ID      string   `json:"id"`
	Dir     string   `json:"dir,omitempty"`
	Command []string `json:"command,omitempty"`
	// URL and Title are a browser pane's page.
	URL   string `json:"url,omitempty"`
	Title string `json:"title,omitempty"`
	// Agent is the agent's session that ran in it, to resume, and Turn
	// where its last turn started.
	Agent   *proto.AgentSession `json:"agent,omitempty"`
	Turn    *proto.Turn         `json:"turn,omitempty"`
	Created int64               `json:"created"`
	Cols    int                 `json:"cols"`
	Rows    int                 `json:"rows"`
}

func (d *Daemon) statePath() string { return filepath.Join(d.dir, "state.json") }

// historyPath is where a pane's history is kept, for a restore.
func (d *Daemon) historyPath(id string) string { return filepath.Join(d.dir, "sessions", id+".vt") }

func (d *Daemon) saveLoop() {
	snaps := time.NewTicker(10 * time.Second)
	defer snaps.Stop()
	for {
		select {
		case <-d.saveCh:
			time.Sleep(300 * time.Millisecond)
			d.saveState()
			d.noteConversations()
			d.saveConversations()
		case <-snaps.C:
			d.saveHistories(false)
			d.noteConversations()
			d.saveConversations()
		case <-d.quit:
			return
		}
	}
}

func (d *Daemon) saveState() {
	d.mu.Lock()
	st := savedState{Version: 2, Projects: d.projects, Saved: time.Now().UnixMilli()}
	for _, s := range d.sessions {
		ss := savedSession{ID: s.id, Project: s.project, Name: s.name, AgentNamed: s.agentNamed, Created: s.created, Layout: s.layout, Focus: s.focus, Worktree: s.worktree}
		for _, p := range s.panes {
			p.mu.Lock()
			sp := savedPane{ID: p.info.ID, Dir: p.info.Dir, Command: p.info.Command, URL: p.info.URL,
				Agent: p.info.AgentSession, Turn: p.info.Turn, Created: p.info.Created, Cols: p.info.Cols, Rows: p.info.Rows}
			if p.info.Browser() {
				sp.Title = p.info.Title
			}
			ss.Panes = append(ss.Panes, sp)
			p.mu.Unlock()
		}
		st.Sessions = append(st.Sessions, ss)
	}
	data, err := json.MarshalIndent(st, "", "  ")
	d.mu.Unlock()
	if err != nil {
		return
	}
	writeAtomic(d.statePath(), data)
}

// saveHistories writes the panes' histories that changed, or all.
func (d *Daemon) saveHistories(force bool) {
	d.mu.Lock()
	panes := make([]*pane, 0, len(d.panes))
	for _, p := range d.panes {
		panes = append(panes, p)
	}
	d.mu.Unlock()
	for _, p := range panes {
		if h := p.history(force); h != nil {
			writeAtomic(d.historyPath(p.info.ID), h)
		}
	}
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// restore starts again the sessions of the last daemon, which ended
// without closing them.
func (d *Daemon) restore() {
	data, err := os.ReadFile(d.statePath())
	if err != nil {
		return
	}
	var st savedState
	if json.Unmarshal(data, &st) != nil {
		return
	}
	set := settings.Load()
	if !set.RestoreSessions {
		// The projects stay; the sessions of the last daemon do not.
		d.projects = st.Projects
		return
	}
	d.projects = st.Projects
	when := time.UnixMilli(st.Saved).Format("Mon Jan 2 15:04")
	for _, ss := range st.Sessions {
		s := &session{id: ss.ID, project: ss.Project, name: ss.Name, agentNamed: ss.AgentNamed, created: ss.Created, restored: true, focus: ss.Focus, worktree: ss.Worktree}
		for _, sp := range ss.Panes {
			if !set.ResumeAgents {
				sp.Agent = nil
			}
			if p := d.restorePane(s.id, sp, when); p != nil {
				s.panes = append(s.panes, p)
				d.panes[p.info.ID] = p
			}
		}
		if len(s.panes) == 0 {
			continue
		}
		if sameLeaves(ss.Layout, s.panes) {
			s.layout = ss.Layout
		} else {
			for _, p := range s.panes[1:] {
				if s.layout == nil {
					s.layout = &proto.Layout{Pane: s.panes[0].info.ID}
				}
				s.layout = s.layout.Split(s.panes[0].info.ID, p.info.ID, "right", 0.5)
			}
		}
		d.sessions = append(d.sessions, s)
		d.log.Printf("session %s restored, %d panes", s.id, len(s.panes))
	}
}

// restorePane starts a pane of the last daemon again, under its
// scrollback, in its directory, with the agent it ran resumed; a browser
// pane comes back on its page, which the app loads.
func (d *Daemon) restorePane(sid string, sp savedPane, when string) *pane {
	now := time.Now().UnixMilli()
	if sp.URL != "" {
		p, _ := newPane(d, sid, proto.Pane{
			ID: sp.ID, Dir: sp.Dir, URL: sp.URL, Title: sp.Title, Status: proto.Idle, Since: now,
			Created: sp.Created, Restored: true,
		})
		return p
	}
	p, err := newPane(d, sid, proto.Pane{
		ID: sp.ID, Dir: sp.Dir, Command: sp.Command, Status: proto.Idle, Since: now,
		Created: sp.Created, Cols: sp.Cols, Rows: sp.Rows, Restored: true, AgentSession: sp.Agent, Turn: sp.Turn,
	})
	if err != nil {
		d.log.Printf("restoring %s: %v", sp.ID, err)
		return nil
	}
	// What the session showed, down to where its cursor was, with the
	// new shell under it: what a program drew below the cursor, as an
	// agent's status bar, goes, rather than show under the new shell's
	// prompt. History carries no modes and no cursor to undo.
	if h, err := os.ReadFile(d.historyPath(sp.ID)); err == nil && len(h) > 0 {
		p.term.Feed(h)
		p.term.Feed([]byte("\x1b[2m── restored · session ended " + when + " ──\x1b[0m\r\n"))
	}
	// The shell alone: what ran in it may not want to run again unasked.
	// But an agent's conversation, which only waits for the user.
	if err := p.start(resumeCommand(sp.Agent), nil); err != nil {
		d.log.Printf("restoring %s: %v", sp.ID, err)
		p.term.Close()
		return nil
	}
	p.dirty = true
	return p
}

// resumeCommand is the command that resumes an agent's session, nil for
// none.
func resumeCommand(a *proto.AgentSession) []string {
	if a == nil || !agentSessionRe.MatchString(a.ID) {
		return nil
	}
	switch a.Agent {
	case "claude":
		return []string{"claude", "--resume", a.ID}
	case "codex":
		return []string{"codex", "resume", a.ID}
	case "pi", "opencode":
		return []string{a.Agent, "--session", a.ID}
	}
	return nil
}

var agentSessionRe = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
