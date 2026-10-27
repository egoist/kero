package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"kero/internal/client"
	"kero/internal/proto"
	"kero/internal/settings"
)

// event is a change kero events reports: what kerod's states tell, the
// difference of one from the one before, or a program's notification.
type event struct {
	Event   string `json:"event"`
	Time    int64  `json:"time"` // unix ms
	Session string `json:"session"`
	Pane    string `json:"pane,omitempty"`
	Project string `json:"project,omitempty"`
	// Name is the session's name, as the sidebar shows it.
	Name string `json:"name,omitempty"`
	// pane.status: the statuses, and the pane's message, what it waits
	// for and its agent; session.renamed: the names; session.moved: the
	// projects' ids.
	From    string `json:"from,omitempty"`
	To      string `json:"to,omitempty"`
	Message string `json:"message,omitempty"`
	Kind    string `json:"kind,omitempty"`
	Agent   string `json:"agent,omitempty"`
	// ExitCode is the shell's status, as a pane goes to exited, or the
	// status of the command it started with (command.exited).
	ExitCode *int `json:"exitCode,omitempty"`
	// notice: what the program said.
	Title string `json:"title,omitempty"`
	Body  string `json:"body,omitempty"`
}

// diffState is what changed from one state to the next, at now.
func diffState(prev, next proto.State, now time.Time) []event {
	naming := settings.Load().SessionName
	ms := now.UnixMilli()
	before := map[string]*proto.Session{}
	for i := range prev.Sessions {
		before[prev.Sessions[i].ID] = &prev.Sessions[i]
	}
	var evs []event
	of := func(kind string, s *proto.Session) event {
		return event{Event: kind, Time: ms, Session: s.ID, Project: s.Project, Name: s.DisplayName(naming)}
	}
	for i := range next.Sessions {
		s := &next.Sessions[i]
		old := before[s.ID]
		if old == nil {
			evs = append(evs, of("session.created", s))
			for _, p := range s.Panes {
				e := of("pane.created", s)
				e.Pane = p.ID
				evs = append(evs, e)
			}
			continue
		}
		delete(before, s.ID)
		if from, to := old.DisplayName(naming), s.DisplayName(naming); from != to {
			e := of("session.renamed", s)
			e.From, e.To = from, to
			evs = append(evs, e)
		}
		if old.Project != s.Project {
			e := of("session.moved", s)
			e.From, e.To = old.Project, s.Project
			evs = append(evs, e)
		}
		for j := range s.Panes {
			p := &s.Panes[j]
			was := old.PaneByID(p.ID)
			if was == nil {
				e := of("pane.created", s)
				e.Pane = p.ID
				evs = append(evs, e)
				continue
			}
			if was.Status != p.Status {
				e := of("pane.status", s)
				e.Pane, e.From, e.To = p.ID, string(was.Status), string(p.Status)
				e.Message, e.Kind, e.Agent = p.Message, p.Kind, p.Agent
				if p.Since > 0 {
					e.Time = p.Since
				}
				if p.Status == proto.Exited {
					code := p.ExitCode
					e.ExitCode = &code
				}
				evs = append(evs, e)
			}
			if was.CommandExit == nil && p.CommandExit != nil {
				e := of("command.exited", s)
				code := *p.CommandExit
				e.Pane, e.ExitCode = p.ID, &code
				evs = append(evs, e)
			}
		}
		for _, p := range old.Panes {
			if s.PaneByID(p.ID) == nil {
				e := of("pane.closed", s)
				e.Pane = p.ID
				evs = append(evs, e)
			}
		}
	}
	// What is left of before closed, in the order it was.
	for i := range prev.Sessions {
		if s := before[prev.Sessions[i].ID]; s != nil {
			evs = append(evs, of("session.closed", s))
		}
	}
	return evs
}

// noticeEvent is a program's notification, as an event of its pane.
func noticeEvent(n *proto.Notice, st proto.State, now time.Time) event {
	e := event{Event: "notice", Time: now.UnixMilli(), Session: n.Session, Pane: n.Pane, Title: n.Title, Body: n.Body}
	for i := range st.Sessions {
		if s := &st.Sessions[i]; s.ID == n.Session {
			e.Project, e.Name = s.Project, s.DisplayName(settings.Load().SessionName)
		}
	}
	return e
}

// follower turns what a watch hears into events.
type follower struct {
	last *proto.State
	// held are notices that came before a state with their session.
	held []*proto.Notice
}

// take is what a message tells, at now.
func (w *follower) take(m proto.Message, now time.Time) []event {
	switch {
	case m.Event == "notice" && m.Notice != nil:
		// A notice can come before the state of its new session: it
		// waits for the next state, which tells its project and name.
		if w.last == nil || !slices.ContainsFunc(w.last.Sessions, func(s proto.Session) bool { return s.ID == m.Notice.Session }) {
			w.held = append(w.held, m.Notice)
			return nil
		}
		return []event{noticeEvent(m.Notice, *w.last, now)}
	case m.Event == "state" && m.State != nil:
		var evs []event
		// The first state is where watching starts from.
		if w.last != nil {
			evs = diffState(*w.last, *m.State, now)
		}
		w.last = m.State
		for _, n := range w.held {
			evs = append(evs, noticeEvent(n, *m.State, now))
		}
		w.held = nil
		return evs
	}
	return nil
}

// eventFilter is which events kero events reports.
type eventFilter struct {
	session, pane string // the target's; "" for all
	project       string // a project's id; "" for all
	statuses      []string
}

func (f eventFilter) match(e event) bool {
	if f.session != "" && e.Session != f.session {
		return false
	}
	// A pane's own events, and those of its session as a whole.
	if f.pane != "" && e.Pane != "" && e.Pane != f.pane {
		return false
	}
	// A session moved out of the project is its last event there.
	if f.project != "" && e.Project != f.project && (e.Event != "session.moved" || e.From != f.project) {
		return false
	}
	if len(f.statuses) > 0 {
		if e.Event != "pane.status" {
			return false
		}
		for _, s := range f.statuses {
			if s == e.To {
				return true
			}
		}
		return false
	}
	return true
}

// present reports whether what the filter follows is in st.
func (f eventFilter) present(st proto.State) bool {
	if f.session == "" {
		return true
	}
	for i := range st.Sessions {
		if s := &st.Sessions[i]; s.ID == f.session {
			return f.pane == "" || s.PaneByID(f.pane) != nil
		}
	}
	return false
}

// gone reports whether an event ends what the filter follows: its
// session closed, or its pane.
func (f eventFilter) gone(e event) bool {
	if f.session == "" || e.Session != f.session {
		return false
	}
	return e.Event == "session.closed" || f.pane != "" && e.Event == "pane.closed" && e.Pane == f.pane
}

// findProject finds a project by its id, its name, or a prefix of its
// id; a name before a prefix of another's id, as kero new -p takes it.
func findProject(st proto.State, ref string) (string, error) {
	var named, prefixed []string
	for _, p := range st.Projects {
		if p.ID == ref {
			return p.ID, nil
		}
		if strings.EqualFold(p.Name, ref) {
			named = append(named, p.ID)
		} else if strings.HasPrefix(p.ID, ref) {
			prefixed = append(prefixed, p.ID)
		}
	}
	ids := named
	if len(ids) == 0 {
		ids = prefixed
	}
	switch len(ids) {
	case 1:
		return ids[0], nil
	case 0:
		return "", fmt.Errorf("%w: no project %q", errNotFound, ref)
	}
	return "", fmt.Errorf("%w: %q names several projects: %s", errNotFound, ref, strings.Join(ids, ", "))
}

// eventsCmd follows kerod's state, printing what changes, until the
// target goes, the first match with --once, or the timeout.
func eventsCmd(c *client.Client, st proto.State, args []string) error {
	fl, err := parse(args, map[string]string{"for": "for", "p": "project", "project": "project", "timeout": "timeout", "t": "timeout"},
		map[string]string{"json": "json", "j": "json", "once": "once"})
	if err != nil {
		return err
	}
	var f eventFilter
	// With no target, every session's: it follows others, not itself.
	if len(fl.pos) > 0 {
		t, err := find(st, fl.pos[0])
		if err != nil {
			return err
		}
		f.session, f.pane = t.s.ID, t.pane
	}
	if ref := fl.vals["project"]; ref != "" {
		if f.project, err = findProject(st, ref); err != nil {
			return err
		}
	}
	valid := []proto.Status{proto.Idle, proto.Working, proto.Waiting, proto.Failed, proto.Exited}
	for _, w := range strings.Split(fl.vals["for"], ",") {
		if w = strings.TrimSpace(w); w == "" {
			continue
		}
		ok := false
		for _, v := range valid {
			ok = ok || string(v) == w
		}
		if !ok {
			return usageErr("kero events: no status %q (idle, working, waiting, error, exited)", w)
		}
		f.statuses = append(f.statuses, w)
	}
	timeout, err := parseTimeout(fl.vals["timeout"])
	if err != nil {
		return err
	}

	// The messages wait here, so that kerod is never kept waiting on the
	// output, which would cut the watch off. A state still waiting gives
	// way to the next, whose difference tells the same but for what came
	// and went between; the first, where watching starts from, stays.
	var (
		mu     sync.Mutex
		queue  []proto.Message
		states int
		wake   = make(chan struct{}, 1)
	)
	c.OnEvent(func(m proto.Message) {
		if m.Event != "state" && m.Event != "notice" {
			return
		}
		mu.Lock()
		n := len(queue)
		if m.Event == "state" {
			states++
		}
		if m.Event == "state" && states > 2 && n > 0 && queue[n-1].Event == "state" {
			queue[n-1] = m
		} else {
			queue = append(queue, m)
		}
		mu.Unlock()
		select {
		case wake <- struct{}{}:
		default:
		}
	})
	if err := c.Call("watch", nil, nil); err != nil {
		if strings.Contains(err.Error(), "unknown method") {
			if onHost != "" {
				return fmt.Errorf("kerod on %s is too old for kero events: update it (kero -H %s daemon update)", onHost, onHost)
			}
			return fmt.Errorf("the running kerod is too old for kero events: run `kero daemon restart` (it restarts sessions)")
		}
		return err
	}
	var expire <-chan time.Time
	if timeout > 0 {
		t := time.NewTimer(time.Duration(timeout) * time.Millisecond)
		defer t.Stop()
		expire = t.C
	}
	// ended is how kero events ends without a match: the target closed, or
	// the timeout passed.
	ended := func() error {
		if fl.set["once"] {
			return exitStatus(1)
		}
		return nil
	}
	enc := json.NewEncoder(os.Stdout)
	var w follower
	for {
		closed := false
		select {
		case <-wake:
		case <-c.Done():
			// What came before still counts.
			closed = true
		case <-expire:
			return ended()
		}
		mu.Lock()
		ms := queue
		queue = nil
		mu.Unlock()
		for _, m := range ms {
			first := w.last == nil
			evs := w.take(m, time.Now())
			if first && w.last != nil && !f.present(*w.last) {
				// The target closed before watching started.
				return ended()
			}
			for _, e := range evs {
				if f.match(e) {
					if fl.set["json"] {
						err = enc.Encode(e)
					} else {
						_, err = fmt.Println(eventLine(e))
					}
					if err != nil || fl.set["once"] {
						return err
					}
				}
				if f.gone(e) {
					return ended()
				}
			}
		}
		if closed {
			return fmt.Errorf("%w: kerod went away", errUnreachable)
		}
	}
}

// eventLine is an event as kero events prints it without --json.
func eventLine(e event) string {
	at := time.UnixMilli(e.Time).Format("15:04:05")
	who := e.Name
	if who == "" {
		who = e.Session
	}
	if e.Pane != "" {
		who += " " + e.Pane
	}
	var what string
	switch e.Event {
	case "pane.status":
		what = e.From + " → " + e.To
		if e.ExitCode != nil && *e.ExitCode != 0 {
			what += fmt.Sprintf(" (%d)", *e.ExitCode)
		}
		if e.Message != "" {
			what += "  " + e.Message
		}
	case "command.exited":
		what = fmt.Sprintf("command exited %d", *e.ExitCode)
	case "session.renamed":
		what = "renamed " + e.From + " → " + e.To
	case "session.moved":
		what = "moved " + e.From + " → " + e.To
	case "notice":
		what = "notice: " + e.Body
		if e.Title != "" {
			what = "notice: " + e.Title + ": " + e.Body
		}
	default:
		// pane.created → pane created
		what = strings.Replace(e.Event, ".", " ", 1)
	}
	return at + "  " + who + "  " + what
}
