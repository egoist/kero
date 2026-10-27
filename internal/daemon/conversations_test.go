package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

// A conversation is remembered once, the last to run first, with what
// each sighting tells, and no more of them than kerod keeps.
func TestConversationNote(t *testing.T) {
	var cs convStore
	cs.note(proto.Conversation{Agent: "claude", ID: "a", Dir: "/src/app", Project: "pr", Title: "Fix login"}, 100)
	cs.note(proto.Conversation{Agent: "codex", ID: "b", Dir: "/src/api"}, 200)
	cs.note(proto.Conversation{Agent: "claude", ID: "a", Name: "fix-login"}, 300)
	if len(cs.list) != 2 {
		t.Fatalf("list %+v", cs.list)
	}
	a := cs.list[0]
	if a.ID != "a" || a.Started != 100 || a.Updated != 300 || a.Dir != "/src/app" || a.Project != "pr" || a.Title != "Fix login" || a.Name != "fix-login" {
		t.Errorf("a %+v", a)
	}
	// An older sighting moves nothing.
	cs.dirty = false
	cs.note(proto.Conversation{Agent: "codex", ID: "b", Dir: "/src/api"}, 150)
	if cs.list[1].Updated != 200 || cs.dirty {
		t.Errorf("an older sighting: %+v, dirty %v", cs.list[1], cs.dirty)
	}
	// Nothing a resume can't start.
	cs.note(proto.Conversation{Agent: "claude", ID: "x; rm -rf ~"}, 400)
	cs.note(proto.Conversation{Agent: "vim", ID: "c"}, 400)
	if len(cs.list) != 2 {
		t.Errorf("kept %+v", cs.list)
	}
	for i := range maxConversations + 10 {
		cs.note(proto.Conversation{Agent: "pi", ID: fmt.Sprint("p", i)}, int64(1000+i))
	}
	if len(cs.list) != maxConversations || cs.list[0].ID != fmt.Sprint("p", maxConversations+9) {
		t.Errorf("%d kept, first %s", len(cs.list), cs.list[0].ID)
	}
	if !slices.IsSortedFunc(cs.list, func(x, y proto.Conversation) int { return int(y.Updated - x.Updated) }) {
		t.Error("not the last to run first")
	}
	if !cs.forget("pi", "p50") || cs.forget("pi", "p50") {
		t.Error("forget")
	}
}

// The sidebar hears of a conversation added, renamed, archived or
// forgotten, not of one that runs on; one archived that runs again is
// archived no more.
func TestConversationGen(t *testing.T) {
	var cs convStore
	gen := cs.generation()
	changed := func(want bool, what string) {
		t.Helper()
		if g := cs.generation(); (g != gen) != want {
			t.Errorf("%s: changed %v", what, g != gen)
		}
		gen = cs.generation()
	}
	cs.note(proto.Conversation{Agent: "claude", ID: "a", Dir: "/src"}, 100)
	changed(true, "added")
	cs.note(proto.Conversation{Agent: "claude", ID: "a", Dir: "/src", Title: "Working"}, 200)
	changed(false, "ran on")
	cs.note(proto.Conversation{Agent: "claude", ID: "a", Name: "fix"}, 300)
	changed(true, "named")
	if !cs.archive("claude", "a", true) || !cs.list[0].Archived {
		t.Fatal("archive")
	}
	changed(true, "archived")
	cs.archive("claude", "a", true)
	changed(false, "archived again")
	if cs.archive("claude", "b", true) {
		t.Error("archived an unknown one")
	}
	cs.note(proto.Conversation{Agent: "claude", ID: "a", Name: "fix"}, 400)
	if cs.list[0].Archived {
		t.Error("still archived as it runs again")
	}
	changed(true, "ran again")
	cs.forget("claude", "a")
	changed(true, "forgotten")
}

// What a pane's agent runs is remembered as it runs and after its pane
// closes, under the session's name and the agent's title, and comes back
// in a session that resumes it, which a second resume shows again.
func TestResumeConversation(t *testing.T) {
	d := testDaemon(t)
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	dir := d.projects[0].Dir
	ses, err := d.create(proto.CreateParams{Project: "pr", Name: "fix-login", Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	p := d.findPane(ses.Panes[0].ID)
	p.mu.Lock()
	p.info.AgentSession = &proto.AgentSession{Agent: "claude", ID: "13b997c3"}
	p.info.Title = "✳ Claude Code"
	p.mu.Unlock()
	list := d.conversations()
	if len(list) != 1 || list[0].Session != ses.ID || list[0].Pane != p.info.ID || list[0].Name != "fix-login" || list[0].Title != "" {
		t.Fatalf("running: %+v", list)
	}
	p.mu.Lock()
	p.info.Title = "✳ Fix the login redirect"
	p.mu.Unlock()
	if err := d.removeSession(ses.ID); err != nil {
		t.Fatal(err)
	}
	list = d.conversations()
	if len(list) != 1 || list[0].Session != "" || list[0].Title != "Fix the login redirect" || list[0].Dir != dir || list[0].Project != "pr" {
		t.Fatalf("closed: %+v", list)
	}

	d.saveConversations()
	d2 := testDaemon(t)
	d2.dir = d.dir
	d2.loadConversations()
	if got := d2.conversations(); len(got) != 1 || got[0] != list[0] {
		t.Fatalf("loaded %+v", got)
	}

	s, err := d.resumeConversation(proto.ConversationParams{Agent: "claude", ID: "13b997c3"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.removeSession(s.ID) })
	if s.Name != "fix-login" || !s.AgentNamed || s.Project != "pr" || len(s.Panes) != 1 {
		t.Fatalf("resumed %+v", s)
	}
	rp := s.Panes[0]
	if strings.Join(rp.Command, " ") != "claude --resume 13b997c3" || rp.Dir != dir || rp.AgentSession == nil || rp.AgentSession.ID != "13b997c3" {
		t.Errorf("pane %+v", rp)
	}
	again, err := d.resumeConversation(proto.ConversationParams{Agent: "claude", ID: "13b997c3"})
	if err != nil || again.ID != s.ID {
		t.Errorf("resumed again: %v, %s, not %s", err, again.ID, s.ID)
	}
	if _, err := d.resumeConversation(proto.ConversationParams{Agent: "claude", ID: "nope"}); err == nil {
		t.Error("resumed an unknown conversation")
	}
}

// A conversation whose directory is gone doesn't start in another.
func TestResumeConversationDirGone(t *testing.T) {
	d := testDaemon(t)
	gone := filepath.Join(t.TempDir(), "gone")
	d.convs.note(proto.Conversation{Agent: "codex", ID: "019a", Dir: gone}, 1)
	if _, err := d.resumeConversation(proto.ConversationParams{Agent: "codex", ID: "019a"}); err == nil || !strings.Contains(err.Error(), "gone") {
		t.Errorf("err %v", err)
	}
	if len(d.sessions) != 0 {
		t.Error("started a session")
	}
}

// Claude Code's title of a conversation is the user's (/rename), else
// Claude's own, the last of each its transcript has.
func TestClaudeTitle(t *testing.T) {
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	dir := filepath.Join(cfg, "projects", "-src-app")
	os.MkdirAll(dir, 0o700)
	path := filepath.Join(dir, "13b997c3.jsonl")
	write := func(lines ...string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var cs convStore
	if got := cs.claudeTitle("13b997c3"); got != "" {
		t.Errorf("no transcript: %q", got)
	}
	write(`{"type":"user","message":{"role":"user","content":"fix the login"}}`,
		`{"type":"ai-title","aiTitle":"Login fix","sessionId":"13b997c3"}`,
		`{"type":"ai-title","aiTitle":"Fix login redirect","sessionId":"13b997c3"}`)
	if got := cs.claudeTitle("13b997c3"); got != "Fix login redirect" {
		t.Errorf("ai title: %q", got)
	}
	write(`{"type":"custom-title","customTitle":"auth work\nmore","sessionId":"13b997c3"}`,
		`{"type":"ai-title","aiTitle":"Fix login redirect","sessionId":"13b997c3"}`)
	os.Chtimes(path, timeAfter(path), timeAfter(path))
	if got := cs.claudeTitle("13b997c3"); got != "auth work" {
		t.Errorf("custom title: %q", got)
	}
	if got := cs.claudeTitle("../x"); got != "" {
		t.Errorf("a path: %q", got)
	}
}

// timeAfter is a second after a file's modification time.
func timeAfter(path string) time.Time {
	st, _ := os.Stat(path)
	return st.ModTime().Add(time.Second)
}
