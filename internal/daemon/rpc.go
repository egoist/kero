package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"kero/internal/proto"
	"kero/internal/remote"
)

// call runs a control method. Methods taking a pane take a session too,
// for its focused pane.
func (d *Daemon) call(c *controlConn, method string, raw json.RawMessage) (any, error) {
	decode := func(v any) error {
		if len(raw) == 0 {
			return nil
		}
		return json.Unmarshal(raw, v)
	}
	findPane := func(ref string) (*pane, error) {
		if p := d.findPane(ref); p != nil {
			return p, nil
		}
		return nil, fmt.Errorf("no session or pane %q", ref)
	}
	switch method {
	case "state":
		return d.state(), nil

	case "subscribe":
		d.mu.Lock()
		d.subs[c] = struct{}{}
		d.mu.Unlock()
		st := d.state()
		c.event(proto.Message{Event: "state", State: &st})
		return true, nil

	case "create", "split":
		var p proto.CreateParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		if method == "split" && p.Split == "" {
			return nil, errors.New("split: which pane?")
		}
		return d.create(p)

	case "close":
		var p proto.IDParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		return true, d.removeSession(p.ID)

	case "pane.close":
		var p proto.IDParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		return true, d.removePane(pn.info.ID)

	case "restart":
		var p proto.IDParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		return true, pn.restart()

	case "rename":
		var p proto.RenameParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		s := d.findSessionLocked(p.ID)
		if s != nil {
			s.name = strings.TrimSpace(p.Name)
			s.agentNamed = false
			if by := d.panes[p.By]; by != nil && s.name != "" {
				by.mu.Lock()
				s.agentNamed = by.info.Agent != "" || by.info.AgentSession != nil
				by.mu.Unlock()
			}
		}
		d.mu.Unlock()
		if s == nil {
			return nil, fmt.Errorf("no session %q", p.ID)
		}
		d.changed()
		return true, nil

	case "move":
		var p proto.MoveParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		return true, d.move(p)

	case "focus":
		var p proto.FocusParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		s := d.findSessionLocked(p.Session)
		ok := s != nil && slices.ContainsFunc(s.panes, func(o *pane) bool { return o.info.ID == p.Pane })
		if ok {
			s.focus = p.Pane
			if s.zoomed != "" {
				s.zoomed = p.Pane
			}
		}
		d.mu.Unlock()
		if !ok {
			return nil, fmt.Errorf("no pane %q in session %q", p.Pane, p.Session)
		}
		d.changed()
		return true, nil

	case "zoom":
		var p proto.FocusParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		s := d.findSessionLocked(p.Session)
		if s != nil {
			if p.Pane == "" || s.zoomed == p.Pane {
				s.zoomed = ""
			} else if slices.ContainsFunc(s.panes, func(o *pane) bool { return o.info.ID == p.Pane }) {
				s.zoomed, s.focus = p.Pane, p.Pane
			}
		}
		d.mu.Unlock()
		if s == nil {
			return nil, fmt.Errorf("no session %q", p.Session)
		}
		d.changed()
		return true, nil

	case "layout":
		var p proto.LayoutParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		s := d.findSessionLocked(p.Session)
		ok := s != nil && sameLeaves(p.Layout, s.panes)
		if ok {
			s.layout = p.Layout
			if s.layout.Leaf() {
				s.layout = nil
			}
		}
		d.mu.Unlock()
		if !ok {
			return nil, errors.New("layout: not the session's panes")
		}
		d.changed()
		return true, nil

	case "send":
		var p proto.SendParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		if pn.term == nil {
			return nil, fmt.Errorf("pane %s is a browser, which takes no input", pn.info.ID)
		}
		pn.input([]byte(p.Data))
		return true, nil

	case "pane.page":
		var p proto.PageParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		if p.URL == "" {
			return nil, errors.New("pane.page: which page?")
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		return true, pn.setPage(p.URL, p.Title)

	case "browser":
		var p proto.BrowserParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		return d.browse(c, pn, p)

	case "browser.answer":
		var p proto.BrowserAnswer
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		ch := d.asks[p.Req]
		d.mu.Unlock()
		if ch == nil {
			return false, nil
		}
		select {
		case ch <- p:
		default:
		}
		return true, nil

	case "read":
		var p proto.ReadParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		return proto.ReadResult{Text: pn.readText(p.Scrollback, p.Lines)}, nil

	case "view":
		var p proto.ViewParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		id := ""
		var panes []*pane
		d.mu.Lock()
		if s := d.findSessionLocked(p.ID); s != nil {
			id, panes = s.id, slices.Clone(s.panes)
		}
		d.mu.Unlock()
		d.viewed.Store(&id)
		for _, pn := range panes {
			pn.mu.Lock()
			pn.info.Unread = false
			dir := pn.info.WorkDir()
			pn.mu.Unlock()
			// What the user looks at is up to date.
			d.git.poke(dir)
		}
		d.changed()
		return true, nil

	case "select":
		var p proto.FocusParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		s := d.findSessionLocked(p.Session)
		if s != nil && p.Pane != "" {
			if pn := d.findPaneLocked(p.Pane); pn != nil && pn.sid == s.id {
				s.focus = pn.info.ID
			}
		}
		d.mu.Unlock()
		if s == nil {
			return nil, fmt.Errorf("no session %q", p.Session)
		}
		// The state goes first: the subscribers hear of a session just
		// made, as by kero new --focus, only once a burst of changes
		// settles (broadcastLoop), and the app shows no session it does
		// not know of.
		st := d.state()
		d.mu.Lock()
		for sub := range d.subs {
			sub.event(proto.Message{Event: "state", State: &st})
			sub.event(proto.Message{Event: "select", Select: s.id})
		}
		n := len(d.subs)
		d.mu.Unlock()
		d.changed()
		return n > 0, nil

	case "do":
		var p proto.DoParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		for sub := range d.subs {
			sub.event(proto.Message{Event: "action", Action: p.Action, Args: p.Args})
		}
		n := len(d.subs)
		d.mu.Unlock()
		return n > 0, nil

	case "notify":
		var p proto.NotifyParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		pn.mu.Lock()
		pn.flag(p.Title, p.Body)
		pn.mu.Unlock()
		return true, nil

	case "wait":
		var p proto.WaitParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		pn, err := findPane(p.ID)
		if err != nil {
			return nil, err
		}
		return d.wait(c, pn, p)

	case "pane.agentSession":
		var p proto.AgentSessionParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		as := &proto.AgentSession{Agent: p.Agent, ID: p.Session}
		if resumeCommand(as) == nil {
			return nil, fmt.Errorf("no agent session %q of %q", p.Session, p.Agent)
		}
		pn, away := d.agentPane(p.PID, p.Agent, p.Dir)
		if pn == nil {
			return nil, fmt.Errorf("no pane runs %s session %q", p.Agent, p.Session)
		}
		pn.mu.Lock()
		pn.info.AgentSession = as
		id := pn.info.ID
		pn.mu.Unlock()
		d.changed()
		d.mu.Lock()
		sid := pn.sid
		d.mu.Unlock()
		return proto.AgentSessionResult{Pane: id, Session: sid, Away: away}, nil

	case "project.create":
		var p proto.ProjectParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		dir := expandHome(p.Dir)
		name := strings.TrimSpace(p.Name)
		if name == "" && dir != "" {
			name = filepath.Base(dir)
		}
		if name == "" {
			return nil, errors.New("a project needs a name or a directory")
		}
		d.mu.Lock()
		for _, pr := range d.projects {
			if dir != "" && pr.Dir == dir {
				d.mu.Unlock()
				return pr, nil
			}
		}
		pr := proto.Project{ID: newID(), Name: name, Dir: dir}
		d.projects = append(d.projects, pr)
		d.mu.Unlock()
		d.changed()
		return pr, nil

	case "project.rename":
		var p proto.ProjectParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		name := strings.TrimSpace(p.Name)
		if name == "" {
			return nil, errors.New("a project needs a name")
		}
		d.mu.Lock()
		for i := range d.projects {
			if d.projects[i].ID == p.ID {
				d.projects[i].Name = name
			}
		}
		d.mu.Unlock()
		d.changed()
		return true, nil

	case "project.move":
		var p proto.MoveProjectParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		i := slices.IndexFunc(d.projects, func(pr proto.Project) bool { return pr.ID == p.ID })
		if i >= 0 {
			pr := d.projects[i]
			d.projects = slices.Delete(d.projects, i, i+1)
			j := max(0, min(p.Index, len(d.projects)))
			d.projects = slices.Insert(d.projects, j, pr)
		}
		d.mu.Unlock()
		d.changed()
		return true, nil

	case "project.close":
		var p proto.IDParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		d.mu.Lock()
		var ids []string
		for _, s := range d.sessions {
			if s.project == p.ID {
				ids = append(ids, s.id)
			}
		}
		d.projects = slices.DeleteFunc(d.projects, func(pr proto.Project) bool { return pr.ID == p.ID })
		d.mu.Unlock()
		for _, id := range ids {
			d.removeSession(id)
		}
		d.changed()
		return true, nil

	case "git.changes", "git.file", "git.diff":
		var p proto.GitParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		switch method {
		case "git.changes":
			return d.gitChanges(p)
		case "git.file":
			return d.gitText(p)
		}
		return d.gitPatch(p)

	case "git.revert":
		var p proto.GitWriteParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		return d.gitRevert(p)

	case "fs.list":
		var p proto.FSListParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		return fsList(p)

	case "fs.stat":
		var p proto.FSStatParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		return fsStat(p), nil

	case "fs.read":
		var p proto.FSReadParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		return fsRead(p)

	case "paste.file":
		var p proto.PasteFileParams
		if err := decode(&p); err != nil {
			return nil, err
		}
		return pasteFile(p)

	case "host.info":
		return remote.LocalInfo(""), nil

	case "clients":
		return d.clientList(), nil

	case "shutdown":
		d.mu.Lock()
		d.ending = true
		ids := make([]string, 0, len(d.sessions))
		for _, s := range d.sessions {
			ids = append(ids, s.id)
		}
		d.mu.Unlock()
		for _, id := range ids {
			d.removeSession(id)
		}
		d.saveState()
		go func() {
			time.Sleep(100 * time.Millisecond)
			d.stop()
		}()
		return true, nil
	}
	return nil, fmt.Errorf("unknown method %q", method)
}

// browseGrace is how long kerod waits for the app's answer to a browser
// call past the call's own timeout: what the page does may take a while,
// and the app waits on the page.
const browseGrace = 30 * time.Second

// browse has the app do something on a browser pane's page, which lives
// in the app, not in kerod, and waits for its answer. Every subscriber
// is asked: one that shows the pane answers with the page's result, the
// others why they can't; the first result wins, else the first refusal.
func (d *Daemon) browse(c *controlConn, s *pane, p proto.BrowserParams) (any, error) {
	s.mu.Lock()
	id, browser := s.info.ID, s.info.Browser()
	s.mu.Unlock()
	if !browser {
		return nil, fmt.Errorf("pane %s is a terminal, not a browser", id)
	}
	d.mu.Lock()
	n := len(d.subs)
	if n == 0 {
		d.mu.Unlock()
		return nil, errors.New("the app is not open: a browser pane's page lives in it")
	}
	if d.asks == nil {
		d.asks = map[int64]chan proto.BrowserAnswer{}
	}
	d.lastAsk++
	req := d.lastAsk
	ch := make(chan proto.BrowserAnswer, n)
	d.asks[req] = ch
	for sub := range d.subs {
		sub.event(proto.Message{Event: "browser", Browser: &proto.BrowserRequest{Req: req, Pane: id, BrowserParams: p}})
	}
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.asks, req)
		d.mu.Unlock()
	}()
	t := time.NewTimer(time.Duration(p.Timeout)*time.Millisecond + browseGrace)
	defer t.Stop()
	var refused error
	for range n {
		select {
		case a := <-ch:
			if a.Error == "" {
				if a.Result == nil {
					a.Result = &proto.BrowserResult{}
				}
				return a.Result, nil
			}
			if refused == nil {
				refused = errors.New(a.Error)
			}
		case <-t.C:
			return nil, errors.New("the app did not answer")
		case <-c.done:
			return nil, errors.New("canceled")
		case <-d.quit:
			return nil, errors.New("kerod exited")
		}
	}
	return nil, refused
}

// wait waits for a pane's status to be one of p.Status.
func (d *Daemon) wait(c *controlConn, s *pane, p proto.WaitParams) (any, error) {
	want := func(info proto.Pane) bool {
		switch {
		case p.Exit:
			return info.CommandExit != nil || info.Status == proto.Exited
		case len(p.Status) == 0:
			return info.Status != proto.Working
		}
		return slices.Contains(p.Status, info.Status)
	}
	if p.Exit {
		s.mu.Lock()
		unmarked := s.info.CommandExit == nil && !s.awaiting && s.info.Status != proto.Exited
		s.mu.Unlock()
		if unmarked {
			return nil, errors.New("no command to wait for: the pane wasn't started with one, or its shell (cmd) can't tell when it ends")
		}
	}
	var timeout <-chan time.Time
	if p.Timeout > 0 {
		t := time.NewTimer(time.Duration(p.Timeout) * time.Millisecond)
		defer t.Stop()
		timeout = t.C
	}
	// An agent given a prompt takes a moment to start working: waiting
	// for it to stop right away would end at once. Give it a little time
	// to start.
	if len(p.Status) == 0 && !p.Exit {
		s.mu.Lock()
		ch, st, since := s.changed, s.info.Status, s.info.Since
		s.mu.Unlock()
		if st != proto.Working && time.Since(time.UnixMilli(since)) > time.Second {
			select {
			case <-ch:
			case <-time.After(1500 * time.Millisecond):
			case <-c.done:
				return nil, errors.New("canceled")
			}
		}
	}
	for {
		s.mu.Lock()
		info, ch, closed := s.info, s.changed, s.closed
		s.mu.Unlock()
		if closed {
			return info, errors.New("pane closed")
		}
		if want(info) {
			return info, nil
		}
		select {
		case <-ch:
		case <-timeout:
			return info, errors.New("timed out")
		case <-c.done:
			return nil, errors.New("canceled")
		case <-d.quit:
			return nil, errors.New("kerod exited")
		}
	}
}
