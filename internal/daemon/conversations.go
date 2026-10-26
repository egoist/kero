package daemon

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"kero/internal/proto"
)

// kerod remembers the coding agents' conversations that its panes ran, as
// their hooks told it (pane.agentSession), in conversations.json, so that
// one can be picked up again after its pane is gone: the app's palette and
// `kero history` list them, and `kero resume` starts one again in a
// session of its own, with the agent's own resume.

// maxConversations is how many conversations kerod remembers, the last
// to run.
const maxConversations = 200

// convStore is the conversations kerod remembers, the last to run first.
// Its lock comes after d.mu and the panes' own.
type convStore struct {
	mu    sync.Mutex
	list  []proto.Conversation
	dirty bool
	// gen counts the changes to the list that show in the app's sidebar:
	// a conversation added, forgotten, archived, ended or renamed, not
	// one that runs on (State.Conversations).
	gen uint64
	// titles are Claude Code's titles of its conversations, as read from
	// their transcripts at a modification time.
	titles map[string]claudeTitle
}

type claudeTitle struct {
	mod   time.Time
	title string
}

func (d *Daemon) convPath() string { return filepath.Join(d.dir, "conversations.json") }

// loadConversations reads the conversations the last kerod remembered.
func (d *Daemon) loadConversations() {
	data, err := os.ReadFile(d.convPath())
	if err != nil {
		return
	}
	var list []proto.Conversation
	if json.Unmarshal(data, &list) != nil {
		return
	}
	list = slices.DeleteFunc(list, func(c proto.Conversation) bool {
		return resumeCommand(&proto.AgentSession{Agent: c.Agent, ID: c.ID}) == nil
	})
	d.convs.mu.Lock()
	d.convs.list = list
	d.convs.mu.Unlock()
}

// saveConversations writes the conversations down, when they changed.
func (d *Daemon) saveConversations() {
	cs := &d.convs
	cs.mu.Lock()
	if !cs.dirty {
		cs.mu.Unlock()
		return
	}
	cs.dirty = false
	data, err := json.MarshalIndent(cs.list, "", "  ")
	cs.mu.Unlock()
	if err == nil {
		writeAtomic(d.convPath(), data)
	}
}

// note remembers a conversation as it runs, at, keeping what c leaves out
// of what was known, and when it started.
func (cs *convStore) note(c proto.Conversation, at int64) {
	if resumeCommand(&proto.AgentSession{Agent: c.Agent, ID: c.ID}) == nil {
		return
	}
	cs.mu.Lock()
	defer cs.mu.Unlock()
	c.Session, c.Pane = "", ""
	i := slices.IndexFunc(cs.list, func(o proto.Conversation) bool { return o.Agent == c.Agent && o.ID == c.ID })
	if i >= 0 {
		old := cs.list[i]
		c.Started = old.Started
		c.Updated = max(old.Updated, at)
		if c.Dir == "" {
			c.Dir = old.Dir
		}
		if c.Project == "" {
			c.Project = old.Project
		}
		if c.Title == "" {
			c.Title = old.Title
		}
		if c == old {
			return
		}
		// One that runs again is no longer archived. Its title, which an
		// agent may change as it works, shows anew as it ends (noteEnded):
		// a change to it would only have the app ask again and again.
		was, now := old, c
		was.Updated, now.Updated, was.Title, now.Title = 0, 0, "", ""
		if was != now {
			cs.gen++
		}
		cs.list = slices.Delete(cs.list, i, i+1)
	} else {
		c.Started, c.Updated = at, at
		cs.gen++
	}
	// The last to run first.
	j, _ := slices.BinarySearchFunc(cs.list, c.Updated, func(o proto.Conversation, t int64) int {
		switch {
		case o.Updated > t:
			return -1
		case o.Updated < t:
			return 1
		}
		return 0
	})
	cs.list = slices.Insert(cs.list, j, c)
	if len(cs.list) > maxConversations {
		cs.list = cs.list[:maxConversations]
	}
	cs.dirty = true
}

// forget drops a conversation, reporting whether it was known.
func (cs *convStore) forget(agent, id string) bool {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	n := len(cs.list)
	cs.list = slices.DeleteFunc(cs.list, func(o proto.Conversation) bool { return o.Agent == agent && o.ID == id })
	if len(cs.list) == n {
		return false
	}
	cs.dirty = true
	cs.gen++
	return true
}

// archive moves a conversation to the sidebar's Archived, or back,
// reporting whether it was known.
func (cs *convStore) archive(agent, id string, archived bool) bool {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	i := slices.IndexFunc(cs.list, func(o proto.Conversation) bool { return o.Agent == agent && o.ID == id })
	if i < 0 {
		return false
	}
	if cs.list[i].Archived != archived {
		cs.list[i].Archived = archived
		cs.dirty = true
		cs.gen++
	}
	return true
}

// generation is the count of the list's changes (gen).
func (cs *convStore) generation() uint64 {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.gen
}

func (cs *convStore) find(agent, id string) (proto.Conversation, bool) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	for _, c := range cs.list {
		if c.Agent == agent && c.ID == id {
			return c, true
		}
	}
	return proto.Conversation{}, false
}

// paneConversation is what a pane tells of the conversation its agent
// runs, nil for none; p.mu is held. name is its session's.
func paneConversation(p *pane, project, name string) *proto.Conversation {
	as := p.info.AgentSession
	if as == nil {
		return nil
	}
	c := &proto.Conversation{Agent: as.Agent, ID: as.ID, Dir: p.info.WorkDir(), Project: project, Name: name}
	if t := proto.CleanTitle(p.info.Title); t != "" && !genericTitle(t, as.Agent) {
		c.Title = t
	}
	return c
}

// genericTitle tells a title that says only which agent runs, as Claude
// Code's before its conversation has one.
func genericTitle(t, agent string) bool {
	return strings.EqualFold(t, agent) || strings.EqualFold(t, proto.AgentNames[agent])
}

// noteConversations remembers what the panes' agents run now, with their
// sessions' names and titles. With ended, they end, as their panes close.
func (d *Daemon) noteConversations() {
	now := time.Now().UnixMilli()
	type seen struct {
		c  proto.Conversation
		at int64
	}
	var all []seen
	d.mu.Lock()
	for _, s := range d.sessions {
		for _, p := range s.panes {
			p.mu.Lock()
			if c := paneConversation(p, s.project, s.name); c != nil {
				// When it last wrote: a conversation left at its prompt
				// for a day ran a day ago.
				all = append(all, seen{*c, min(max(p.info.Activity, p.info.Created), now)})
			}
			p.mu.Unlock()
		}
	}
	d.mu.Unlock()
	for _, s := range all {
		d.convs.note(s.c, s.at)
	}
}

// noteEnded remembers the conversation of a pane whose agent ends, or
// whose pane closes, now; p.mu is held.
func (d *Daemon) noteEnded(p *pane) {
	if c := paneConversation(p, "", ""); c != nil {
		// The session's name and project stay as last noted.
		old, ok := d.convs.find(c.Agent, c.ID)
		if ok {
			c.Name = old.Name
		}
		d.convs.note(*c, time.Now().UnixMilli())
		// Ended, it moves to the sidebar's Ended, if it shows.
		d.convs.mu.Lock()
		d.convs.gen++
		d.convs.mu.Unlock()
		d.changed()
	}
}

// conversations lists the conversations kerod remembers, the last to run
// first, with the panes that run them now.
func (d *Daemon) conversations() []proto.Conversation {
	d.noteConversations()
	d.convs.mu.Lock()
	list := slices.Clone(d.convs.list)
	d.convs.mu.Unlock()
	type where struct{ session, pane string }
	running := map[proto.AgentSession]where{}
	d.mu.Lock()
	for _, s := range d.sessions {
		for _, p := range s.panes {
			p.mu.Lock()
			if as := p.info.AgentSession; as != nil {
				running[*as] = where{s.id, p.info.ID}
			}
			p.mu.Unlock()
		}
	}
	d.mu.Unlock()
	for i := range list {
		c := &list[i]
		if w, ok := running[proto.AgentSession{Agent: c.Agent, ID: c.ID}]; ok {
			c.Session, c.Pane = w.session, w.pane
		}
		if c.Agent == "claude" {
			if t := d.convs.claudeTitle(c.ID); t != "" {
				c.Title = t
			}
		}
	}
	return list
}

// resumeConversation shows the session running a conversation, or starts
// one that resumes it, in the directory and project it ran in.
func (d *Daemon) resumeConversation(p proto.ConversationParams) (proto.Session, error) {
	c, ok := d.convs.find(p.Agent, p.ID)
	if !ok {
		return proto.Session{}, fmt.Errorf("no conversation %s of %s", p.ID, p.Agent)
	}
	as := proto.AgentSession{Agent: c.Agent, ID: c.ID}
	d.mu.Lock()
	for _, s := range d.sessions {
		for _, pn := range s.panes {
			pn.mu.Lock()
			runs := pn.info.AgentSession != nil && *pn.info.AgentSession == as
			pn.mu.Unlock()
			if runs {
				s.focus, s.zoomed = pn.info.ID, ""
				info := d.sessionInfo(s)
				d.mu.Unlock()
				d.changed()
				return info, nil
			}
		}
	}
	project := ""
	for _, pr := range d.projects {
		if pr.ID == c.Project {
			project = pr.ID
		}
	}
	d.mu.Unlock()
	if c.Dir != "" {
		if st, err := os.Stat(c.Dir); err != nil || !st.IsDir() {
			return proto.Session{}, fmt.Errorf("the conversation's directory %s is gone", proto.ShortDir(c.Dir))
		}
	}
	info, err := d.create(proto.CreateParams{
		Project: project, Name: c.Name, Dir: c.Dir, Command: resumeCommand(&as), After: p.After, Cols: p.Cols, Rows: p.Rows,
	})
	if err != nil {
		return info, err
	}
	d.mu.Lock()
	if s := d.findSessionLocked(info.ID); s != nil {
		// The name was the agent's, or the user's: either way, the
		// conversation's, not a name for the session to keep for the next.
		s.agentNamed = s.name != ""
		for _, pn := range s.panes {
			pn.mu.Lock()
			pn.info.AgentSession = &as
			pn.mu.Unlock()
		}
		info = d.sessionInfo(s)
	}
	d.mu.Unlock()
	d.convs.note(c, time.Now().UnixMilli())
	d.changed()
	d.log.Printf("session %s resumes %s conversation %s", info.ID, c.Agent, c.ID)
	return info, nil
}

// errNoTranscript: Claude Code keeps no transcript of the conversation.
var errNoTranscript = errors.New("no transcript")

// claudeTitle is Claude Code's title of one of its conversations: the one
// the user gave it (/rename), else Claude's own; "" when it has none.
func (cs *convStore) claudeTitle(id string) string {
	path, mod, err := claudeTranscript(id)
	if err != nil {
		return ""
	}
	cs.mu.Lock()
	t, ok := cs.titles[id]
	cs.mu.Unlock()
	if ok && t.mod.Equal(mod) {
		return t.title
	}
	title := readClaudeTitle(path)
	cs.mu.Lock()
	if cs.titles == nil {
		cs.titles = map[string]claudeTitle{}
	}
	cs.titles[id] = claudeTitle{mod, title}
	cs.mu.Unlock()
	return title
}

// claudeTranscript finds the transcript of a Claude Code conversation, in
// the folder of the project it ran in, and when it last changed.
func claudeTranscript(id string) (string, time.Time, error) {
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		dir = filepath.Join(proto.Home(), ".claude")
	}
	// id is a session's, as resumeCommand takes it: no pattern's letters.
	if !agentSessionRe.MatchString(id) {
		return "", time.Time{}, errNoTranscript
	}
	matches, _ := filepath.Glob(filepath.Join(dir, "projects", "*", id+".jsonl"))
	for _, m := range matches {
		if st, err := os.Stat(m); err == nil && st.Mode().IsRegular() {
			return m, st.ModTime(), nil
		}
	}
	return "", time.Time{}, errNoTranscript
}

// readClaudeTitle reads a Claude Code transcript's title: its last
// custom-title, else its last ai-title. Claude writes them again as the
// conversation goes on, so its end has them.
func readClaudeTitle(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	const tail = 256 << 10
	if st, err := f.Stat(); err == nil && st.Size() > tail {
		f.Seek(st.Size()-tail, io.SeekStart)
	}
	custom, ai := "", ""
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), 4<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if !bytes.Contains(line, []byte(`-title"`)) {
			continue
		}
		var e struct {
			Type        string `json:"type"`
			CustomTitle string `json:"customTitle"`
			AITitle     string `json:"aiTitle"`
		}
		if json.Unmarshal(line, &e) != nil {
			continue
		}
		switch e.Type {
		case "custom-title":
			custom = e.CustomTitle
		case "ai-title":
			ai = e.AITitle
		}
	}
	if t := strings.TrimSpace(custom); t != "" {
		return titleLine(t)
	}
	return titleLine(strings.TrimSpace(ai))
}

// titleLine keeps a title to a line, and to 200 bytes.
func titleLine(t string) string {
	t, _, _ = strings.Cut(t, "\n")
	if len(t) > 200 {
		t = strings.ToValidUTF8(t[:200], "")
	}
	return t
}
