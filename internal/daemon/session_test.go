package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

// testPane is a pane with no program, whose output the test writes.
func testPane(t *testing.T) *pane {
	t.Helper()
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	d := &Daemon{changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1)}
	d.viewed.Store(new(string))
	s, err := newPane(d, "s", proto.Pane{ID: "p", Status: proto.Idle, Cols: 96, Rows: 28})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.term.Close() })
	return s
}

// show writes a program's redraw of the whole screen.
func (s *pane) show(text string) {
	s.output([]byte("\x1b[H\x1b[2J" + strings.ReplaceAll(strings.TrimRight(text, "\n"), "\n", "\r\n")))
}

func claudeScreen(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "detect", "testdata", "claude-"+name+".txt"))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func (s *pane) status(now time.Time) proto.Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.look(now)
	return s.info.Status
}

// Claude Code at its prompt repaints its screen as the sidebar hides and
// the pane resizes, over and over: still idle. Its turn is work, and the
// prompt back is idle again.
func TestClaudeRedrawIsNoWork(t *testing.T) {
	s := testPane(t)
	s.info.Agent, s.info.Title = "claude", "✳ Claude Code"
	now := time.Now()
	idle := claudeScreen(t, "idle")
	s.show(idle)
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("at the prompt: %s", st)
	}
	for i := range 20 {
		s.resize(96-i, 28, 0, 0)
		s.show(idle)
		now = now.Add(16 * time.Millisecond)
		if st := s.status(now); st != proto.Idle {
			t.Fatalf("redraw %d after a resize: %s", i, st)
		}
	}
	s.show(claudeScreen(t, "working"))
	if st := s.status(now); st != proto.Working {
		t.Fatalf("in a turn: %s", st)
	}
	// Redraws of the turn, as a resize makes, are the same turn.
	s.resize(80, 28, 0, 0)
	s.show(claudeScreen(t, "working"))
	if st := s.status(now); st != proto.Working {
		t.Fatalf("in a turn, resized: %s", st)
	}
	s.show(idle)
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("after the turn: %s", st)
	}
	if !s.info.Unread {
		t.Error("a turn that ended unseen is not unread")
	}
	s.show(claudeScreen(t, "blocked"))
	if st := s.status(now); st != proto.Waiting {
		t.Fatalf("asking to run a command: %s", st)
	}
	// Keys that move in the dialog leave it asking.
	s.input(nil)
	if st := s.status(now); st != proto.Waiting {
		t.Fatalf("asking, after a key: %s", st)
	}
	s.show(idle)
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("back at the prompt: %s", st)
	}
}

// Claude Code at its prompt for a while notifies "waiting for your
// input": its screen, at the prompt, tells it is idle, not waiting. Its
// notification at a permission dialog words the wait. "kero notify" from
// it needs the user all the same.
func TestAgentNotifyFollowsScreen(t *testing.T) {
	s := testPane(t)
	s.info.Agent = "claude"
	now := time.Now()
	s.show(claudeScreen(t, "idle"))
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("at the prompt: %s", st)
	}
	s.output([]byte("\x1b]9;Claude is waiting for your input\x07"))
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("notified at the prompt: %s", st)
	}
	s.output([]byte("\x07"))
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("bell at the prompt: %s", st)
	}
	s.show(claudeScreen(t, "blocked"))
	if st := s.status(now); st != proto.Waiting {
		t.Fatalf("asking to run a command: %s", st)
	}
	s.output([]byte("\x1b]9;Claude needs your permission to use Bash\x07"))
	if st := s.status(now); st != proto.Waiting || s.info.Message != "Claude needs your permission to use Bash" {
		t.Fatalf("notified while asking: %s %q", st, s.info.Message)
	}
	s.show(claudeScreen(t, "idle"))
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("back at the prompt: %s", st)
	}
	s.mu.Lock()
	s.flag("", "Need your API key to continue")
	s.mu.Unlock()
	if st := s.status(now); st != proto.Waiting || s.info.Message != "Need your API key to continue" {
		t.Fatalf("kero notify: %s %q", st, s.info.Message)
	}
}

// A program's bell and notification tell nothing of its status: vim
// beeps at a wrong key, a build notifies it is done.
func TestProgramNotifyIsNoWait(t *testing.T) {
	s := testPane(t)
	s.fgPGID, s.shellPID = 2, 1
	now := time.Now()
	s.output([]byte("\x07\x1b]9;Build finished\x07\x1b]777;notify;make;Build finished\x07"))
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("after a bell and notifications: %s", st)
	}
}

// A program that is no agent works while its title turns as a spinner:
// a clock it draws, however long it ticks, is not work.
func TestProgramWorksByTitle(t *testing.T) {
	s := testPane(t)
	now := time.Now()
	for i := range 30 {
		s.output([]byte("\x1b[32;1H" + now.Format("05")))
		now = now.Add(time.Second)
		if st := s.status(now); st != proto.Idle {
			t.Fatalf("clock tick %d: %s", i, st)
		}
	}
	s.output([]byte("\x1b]0;⠋ building\x07"))
	if st := s.status(now); st != proto.Working {
		t.Fatalf("title turning: %s", st)
	}
	s.output([]byte("\x1b]0;done\x07"))
	if st := s.status(now); st != proto.Idle {
		t.Fatalf("title still: %s", st)
	}
}

// An agent's screen that stops showing work without showing its prompt is
// idle only once it has stayed so (idleHold).
func TestWorkingHeldBeforeIdle(t *testing.T) {
	s := testPane(t)
	s.info.Agent = "claude"
	now := time.Now()
	s.show(claudeScreen(t, "working"))
	if st := s.status(now); st != proto.Working {
		t.Fatalf("in a turn: %s", st)
	}
	s.show("⏺ Some answer")
	if st := s.status(now); st != proto.Working {
		t.Fatalf("between redraws: %s", st)
	}
	if st := s.status(now.Add(idleHold)); st != proto.Idle {
		t.Fatalf("after %s: %s", idleHold, st)
	}
}

// A restore resumes Claude Code's and Codex's sessions, and nothing a
// state file could slip in.
func TestResumeCommand(t *testing.T) {
	for _, c := range []struct {
		agent, id, want string
	}{
		{"claude", "13b997c3-f8b3-4b3e-bb8a-ca1b5d1b9787", "claude --resume 13b997c3-f8b3-4b3e-bb8a-ca1b5d1b9787"},
		{"codex", "019a2b3c-4d5e", "codex resume 019a2b3c-4d5e"},
		{"pi", "0f3c2a1b-8e9d", "pi --session 0f3c2a1b-8e9d"},
		{"opencode", "ses_ea7b9b964ffemfrVYxK9yw55Gz", "opencode --session ses_ea7b9b964ffemfrVYxK9yw55Gz"},
		{"claude", "x; rm -rf ~", ""},
		{"claude", "", ""},
		{"vim", "abc", ""},
	} {
		got := strings.Join(resumeCommand(&proto.AgentSession{Agent: c.agent, ID: c.id}), " ")
		if got != c.want {
			t.Errorf("%s %q: got %q, want %q", c.agent, c.id, got, c.want)
		}
	}
	if resumeCommand(nil) != nil {
		t.Error("resumed nothing")
	}
}

// An agent's hook tells of the pane whose shell runs it; one that runs
// under none, as in Codex's app server that panes share, tells of the
// pane that can only be the agent's, and of none when several could be.
func TestAgentPane(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	d := &Daemon{changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1), panes: map[string]*pane{}}
	d.viewed.Store(new(string))
	add := func(id, agent, dir string, session bool) *pane {
		info := proto.Pane{ID: id, Agent: agent, Dir: dir, Status: proto.Idle, Cols: 80, Rows: 24}
		if session {
			info.AgentSession = &proto.AgentSession{Agent: agent, ID: "old-" + id}
		}
		p, err := newPane(d, "s", info)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { p.term.Close() })
		d.panes[id] = p
		return p
	}
	name := func(p *pane) string {
		if p == nil {
			return "none"
		}
		return p.info.ID
	}
	check := func(what string, pid int, dir, want string, wantAway bool) {
		t.Helper()
		p, away := d.agentPane(pid, "codex", dir)
		if name(p) != want || away != wantAway {
			t.Errorf("%s: %s away=%v, want %s away=%v", what, name(p), away, want, wantAway)
		}
	}

	a := add("a", "codex", "/repo", true)
	check("its only pane, telling a new session", 0, "", "a", true)
	add("b", "codex", "/repo", false)
	check("its only pane yet to tell", 0, "", "b", true)
	add("c", "codex", "/other", false)
	check("of two yet to tell, the one in its dir", 0, "/other", "c", true)
	check("two yet to tell, in a dir neither is in", 0, "/worktree", "none", true)
	add("d", "claude", "/repo", false)
	check("two yet to tell, no dir", 0, "", "none", true)

	// Run under a pane's shell: that pane, whatever the others.
	a.shellPID = os.Getppid()
	check("under a's shell", os.Getpid(), "", "a", false)

	// Under Codex's app server that panes share, which a's Codex started
	// under a's shell: not a, which has its session, but the one pane yet
	// to tell its own (kero#237).
	if runtime.GOOS == "windows" {
		return
	}
	d.panes["c"].mu.Lock()
	d.panes["c"].info.Status = proto.Exited
	d.panes["c"].mu.Unlock()
	server := exec.Command("sh", "-c", "sleep 30; :", "codex", "app-server", "--listen", "unix://", "--managed-daemon")
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { server.Process.Kill(); server.Wait() })
	// Its command line shows once it has exec'd, which Start may return
	// before.
	for i := 0; !sharedService(server.Process.Pid); i++ {
		if i == 5000 {
			t.Fatalf("the app server shows %q", procArgs(server.Process.Pid))
		}
		time.Sleep(time.Millisecond)
	}
	a.shellPID = os.Getpid()
	check("under the app server a's Codex started", server.Process.Pid, "", "b", true)
}
