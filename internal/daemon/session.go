package daemon

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/detect"
	"kero/internal/proto"
	"kero/internal/settings"
)

// idleHold: an agent's screen that stops showing work, without showing
// its prompt either, is idle once it has stayed so this long: a turn's
// spinner line can go between two redraws.
const idleHold = 700 * time.Millisecond

// pane is a shell the daemon keeps running in a pseudo-terminal, with a
// terminal emulator of its own (libghostty-vt, headless) that keeps its
// screen and scrollback for the clients that attach later.
type pane struct {
	d   *Daemon
	sid string // the session's it belongs to

	// mu guards the fields below, and orders the output the emulator and
	// the clients get with clients attaching. The emulator's callbacks
	// (OnTitle, OnNotify) run within Feed, with mu held.
	mu   sync.Mutex
	info proto.Pane
	// cellW and cellH are the size of a cell in pixels on the client
	// that last resized the pane, 0 until one did.
	cellW, cellH int
	proc         *ptyProc
	term         *terminal.Terminal
	clients      map[*attachment]struct{}
	shellPID     int
	fgPGID       int
	cwdAt        time.Time

	dirty bool // output since the history on disk
	// seen is what the screen showed when the status last came from it,
	// which a status of other origin (a notification, the user's input)
	// then stands against until the screen shows something else; looked
	// tells that the screen was read since it last changed; idleFrom
	// holds back working going idle (idleHold).
	seen     detect.State
	looked   bool
	idleFrom time.Time
	// osc finds OSC 7501 and 133 in the output; records are the programs'
	// status reports (OSC 7501), by id, and reported tells that one came.
	osc      oscScanner
	records  map[string]proto.Record
	reported bool
	// awaiting tells that the command the pane started with runs, whose
	// end its shell will tell (OSC 133;D, see shellArgs).
	awaiting bool
	closed   bool
	changed  chan struct{} // closed and replaced on every status change
	// framing tells that frames for the clients are due, after output.
	framing bool
}

// headless connects the daemon's emulator to the program: it reads
// nothing (the daemon feeds it), and writes the emulator's answers to the
// program's queries. It is the session's only emulator: clients show its
// frames (terminal.Mirror), and answer nothing but the clipboard's reads it
// forwards them.
type headless struct {
	s      *pane
	closed chan struct{}
	once   sync.Once
}

func (h *headless) Read([]byte) (int, error) {
	<-h.closed
	return 0, io.EOF
}

func (h *headless) Write(p []byte) (int, error) {
	h.s.mu.Lock()
	proc := h.s.proc
	h.s.mu.Unlock()
	if proc != nil {
		proc.Write(p)
	}
	return len(p), nil
}

func (h *headless) Close() error {
	h.once.Do(func() { close(h.closed) })
	return nil
}

func newPane(d *Daemon, sid string, info proto.Pane) (*pane, error) {
	s := &pane{d: d, sid: sid, info: info, clients: map[*attachment]struct{}{}, changed: make(chan struct{})}
	s.info.Progress = -1
	if s.info.Cols <= 0 || s.info.Rows <= 0 {
		s.info.Cols, s.info.Rows = 120, 36
	}
	sb := settings.Load().Scrollback << 20
	if sb == 0 {
		sb = -1 // none
	}
	term, err := terminal.New(terminal.Options{
		Conn:       &headless{s: s, closed: make(chan struct{})},
		Scrollback: sb,
		// Programs' reads of the clipboard go on to the clients, whose
		// terminals answer them, asking the user as they would.
		ClipboardRead: terminal.ClipboardForward,
		OnTitle:       s.onTitle,
		OnNotify:      s.onNotify,
	})
	if err != nil {
		return nil, err
	}
	term.Resize(s.info.Cols, s.info.Rows)
	term.UseTheme(d.theme.Load())
	s.term = term
	return s, nil
}

// start starts the shell, running command first when set.
func (s *pane) start(command []string, env []string) error {
	shell := userShell()
	name := shellName(shell)
	args := shellArgs(shell, command)
	dir := s.info.Dir
	if st, err := os.Stat(dir); dir == "" || err != nil || !st.IsDir() {
		dir = proto.Home()
	}
	proc, err := startPTY(ptyOptions{
		Path: shell, Args: args, Dir: dir,
		Env:  s.d.environment(s.sid, s.info.ID, shell, env),
		Cols: s.info.Cols, Rows: s.info.Rows,
	})
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.proc = proc
	s.shellPID = proc.PID()
	s.info.PID = s.shellPID
	s.info.Dir = dir
	s.info.Shell = name
	s.info.CommandExit = nil
	s.awaiting = len(command) > 0 && marksExit(shell)
	s.mu.Unlock()
	go s.pump(proc)
	return nil
}

// pump reads the program's output until it ends.
func (s *pane) pump(proc *ptyProc) {
	buf := make([]byte, 64<<10)
	for {
		n, err := proc.Read(buf)
		if n > 0 {
			s.output(buf[:n])
		}
		if err != nil {
			break
		}
	}
	select {
	case <-proc.exited:
	case <-time.After(time.Second):
		proc.Kill()
		<-proc.exited
	}
	s.exited(proc)
}

func (s *pane) output(p []byte) {
	now := time.Now()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	before := s.info.Status
	s.osc.scan(p, s.handleOSC, s.fullReset)
	s.term.Feed(p)
	s.dirty = true
	s.info.Activity = now.UnixMilli()
	s.looked = false
	s.frameSoon()
	changed := s.info.Status != before
	s.mu.Unlock()
	if changed {
		s.d.changed()
	}
}

func (s *pane) onTitle(title string) {
	// s.mu is held (see session.mu).
	if s.info.Title != title {
		s.info.Title = title
		s.looked = false
		s.d.changed()
	}
}

// onNotify takes a program's desktop notification (OSC 9, 777, 99),
// which tells nothing of its status: a program that needs the user says
// so with "kero report blocked" or "kero notify". An agent's screen tells
// whether it waits, and its notification only words the wait, as Claude
// Code's "needs your permission"; its "waiting for your input", a while
// after a turn, is dropped. Any other program's goes on to the app as it
// is. s.mu is held.
func (s *pane) onNotify(title, body string) {
	title, body = strings.TrimSpace(title), strings.TrimSpace(body)
	if body == "" {
		title, body = "", title
	}
	if body == "" {
		return
	}
	if detect.Known(s.info.Agent) {
		if s.info.Status == proto.Waiting {
			s.info.Message = body
			s.d.changed()
		}
		return
	}
	go s.d.notice(proto.Notice{Session: s.sid, Title: title, Body: body})
}

// flag marks the pane as needing the user, as "kero notify" asks; s.mu
// is held.
func (s *pane) flag(title, body string) {
	msg := strings.TrimSpace(body)
	if msg == "" {
		msg = strings.TrimSpace(title)
	}
	s.needsUser(msg)
}

// needsUser marks the session waiting for the user; s.mu is held.
func (s *pane) needsUser(msg string) {
	if s.info.Status == proto.Exited || s.declared() {
		return
	}
	s.setStatus(proto.Waiting)
	if msg != "" {
		s.info.Message = msg
	}
	if !s.viewed() {
		s.info.Unread = true
	}
	s.d.changed()
}

func (s *pane) viewed() bool { return s.d.viewedID() == s.sid }

// setStatus changes the status, waking those waiting on it; s.mu is held.
func (s *pane) setStatus(st proto.Status) {
	if s.info.Status == st {
		return
	}
	s.info.Status = st
	s.info.Since = time.Now().UnixMilli()
	s.wake()
}

// wake wakes those waiting on the pane; s.mu is held.
func (s *pane) wake() {
	close(s.changed)
	s.changed = make(chan struct{})
}

// tick follows the foreground program and the shell's directory, and ends
// work that went quiet.
func (s *pane) tick(now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.proc == nil || s.info.Status == proto.Exited {
		return false
	}
	changed := false
	pg := s.proc.Foreground()
	s.fgPGID = pg
	proc, agent := "", ""
	if pg != 0 && pg != s.shellPID {
		proc = procName(pg)
		args := procArgs(pg)
		agent = detectAgent(proc, args)
		if proc == "node" || proc == "bun" || proc == "python" || proc == "python3" || proc == "deno" {
			// A script: name it by the script, as "codex", not "node".
			if len(args) > 1 {
				proc = strings.TrimSuffix(filepath.Base(args[1]), filepath.Ext(args[1]))
			}
		}
		if agent != "" {
			proc = agent
		}
	}
	if proc == "" && s.info.Process != "" {
		// The program ended: its live reports go with it, and an agent's
		// session is no more to resume.
		s.dropLive()
		if s.info.AgentSession != nil {
			s.info.AgentSession = nil
			s.d.save()
		}
	}
	if proc != s.info.Process || agent != s.info.Agent {
		s.info.Process, s.info.Agent = proc, agent
		s.seen, s.looked = "", false
		changed = true
	}
	if now.Sub(s.cwdAt) > 1500*time.Millisecond || proc == "" && s.info.ProcessDir != "" {
		s.cwdAt = now
		if dir := procCwd(s.shellPID); dir != "" && dir != s.info.Dir {
			s.info.Dir = dir
			changed = true
			s.d.save()
		}
		// The program's own, from its group's leader, as an agent's that
		// went into a worktree: the shell under it stays where it was.
		pdir := ""
		if proc != "" {
			pdir = procCwd(pg)
		}
		if pdir == s.info.Dir {
			pdir = ""
		}
		if pdir != s.info.ProcessDir {
			s.info.ProcessDir = pdir
			changed = true
		}
	}
	if s.look(now) {
		changed = true
	}
	return changed
}

// look sets the status from what the screen shows, when it may have
// changed: an agent's from its rules (package detect), any other
// program's from its title, which turns as a spinner while it works. Only
// a change of what shows changes the status, so that a redraw changes
// nothing, as one after a resize; s.mu is held.
func (s *pane) look(now time.Time) bool {
	if s.declared() {
		// What the program declares stands; once it ends, the screen
		// tells again.
		s.seen = ""
		return false
	}
	if s.looked && s.idleFrom.IsZero() || s.info.Status == proto.Exited {
		return false
	}
	s.looked = true
	st, visible := detect.Idle, true
	if detect.Known(s.info.Agent) {
		r := detect.Detect(s.info.Agent, detect.Input{Screen: s.screen(), Title: s.info.Title})
		if r.Skip {
			return false
		}
		st, visible = r.State, r.Visible
	} else if proto.TitleBusy(s.info.Title) {
		st = detect.Working
	}
	if st == s.seen {
		s.idleFrom = time.Time{}
		return false
	}
	if st == detect.Idle && !visible && s.info.Status == proto.Working {
		if s.idleFrom.IsZero() {
			s.idleFrom = now
		}
		if now.Sub(s.idleFrom) < idleHold {
			return false
		}
	}
	s.idleFrom = time.Time{}
	s.seen = st
	before := s.info.Status
	switch st {
	case detect.Working:
		s.setStatus(proto.Working)
		s.info.Message = ""
	case detect.Blocked:
		s.needsUser("")
	default:
		if before == proto.Working || before == proto.Waiting {
			s.setStatus(proto.Idle)
			s.info.Message = ""
			if before == proto.Working && !s.viewed() {
				s.info.Unread = true
			}
		}
	}
	return s.info.Status != before
}

// screen returns the text of the screen: the last rows of the terminal's
// text; s.mu is held.
func (s *pane) screen() string {
	text := strings.TrimRight(s.term.Text(), "\n")
	lines := strings.Split(text, "\n")
	return strings.Join(lines[max(0, len(lines)-s.info.Rows):], "\n") + "\n"
}

// input writes what the user typed to the program.
func (s *pane) input(p []byte) {
	s.mu.Lock()
	proc := s.proc
	changed := false
	if len(s.records) > 0 {
		s.dismissFinished()
	}
	// Waiting is over once the user acts, unless the screen still asks,
	// as a permission dialog does until it is answered.
	if s.info.Status == proto.Waiting && !s.declared() && s.seen != detect.Blocked || s.info.Status == proto.Failed {
		s.setStatus(proto.Idle)
		s.info.Message = ""
		changed = true
	}
	if s.info.Unread {
		s.info.Unread = false
		changed = true
	}
	s.mu.Unlock()
	if proc != nil {
		proc.Write(p)
	}
	if changed {
		s.d.changed()
	}
}

// useTheme gives the panes, and those to come, a client's colors, which
// programs asking about them get: Copilot CLI drew its input box dark on
// a light background, as kerod's terminals answered with a dark theme.
func (d *Daemon) useTheme(t proto.Theme) {
	color := func(c [4]byte) ui.Color { return ui.Color{R: c[0], G: c[1], B: c[2], A: c[3]} }
	th := &terminal.Theme{Foreground: color(t.Foreground), Background: color(t.Background), Cursor: color(t.Cursor)}
	for i, c := range t.Palette {
		th.Palette[i] = color(c)
	}
	d.theme.Store(th)
	d.mu.Lock()
	panes := make([]*pane, 0, len(d.panes))
	for _, p := range d.panes {
		panes = append(panes, p)
	}
	d.mu.Unlock()
	for _, p := range panes {
		p.term.UseTheme(th)
	}
}

func (s *pane) resize(cols, rows, cellW, cellH int) {
	if cols <= 0 || rows <= 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	if cellW > 0 && cellH > 0 && (cellW != s.cellW || cellH != s.cellH) {
		// The cells' size in pixels: what the program asking the size in
		// pixels gets, and what the client's mouse reports in pixels count
		// in.
		s.cellW, s.cellH = cellW, cellH
		s.term.ResizePixels(s.info.Cols, s.info.Rows, cellW, cellH)
		if s.proc != nil {
			s.proc.Resize(s.info.Cols, s.info.Rows, cellW, cellH)
		}
	}
	if cols == s.info.Cols && rows == s.info.Rows {
		return
	}
	// The clients show what the screen holds at its old size, which
	// their terminals then take the new size with, as this one does.
	s.frame()
	s.info.Cols, s.info.Rows = cols, rows
	s.term.Resize(cols, rows)
	if s.proc != nil {
		s.proc.Resize(cols, rows, s.cellW, s.cellH)
	}
	// Where this terminal took the size, which the clients' take there
	// too (proto.FrameResized), then what it shows at it.
	for c := range s.clients {
		c.send(proto.FrameResized, proto.ResizePayload(cols, rows))
	}
	s.frame()
}

// clear clears the session's terminal as a client's user asked
// (proto.FrameClear): proto.ClearScreen, the scrollback and the screen
// above the cursor's line, which moves to the top with the shell's prompt,
// but for a full-screen program's screen, which it leaves alone; or
// proto.ClearScrollback. The clients show it with the next frame.
func (s *pane) clear(what byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	switch what {
	case proto.ClearScreen:
		if !s.term.ClearScreen() {
			return
		}
	case proto.ClearScrollback:
		s.term.ClearScrollback()
	default:
		return
	}
	s.dirty = true
	s.looked = false
	s.frameSoon()
}

// frameDelay is how long frames wait after output, for more of it: a
// program's redraw comes in pieces.
const frameDelay = 4 * time.Millisecond

// frameSoon sends the clients a frame shortly; s.mu is held.
func (s *pane) frameSoon() {
	if s.framing || len(s.clients) == 0 {
		return
	}
	s.framing = true
	time.AfterFunc(frameDelay, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.framing = false
		s.frame()
	})
}

// frame sends each client what brings its terminal to what this one
// shows, and asks for another frame when a synchronized update holds this
// one back; s.mu is held.
func (s *pane) frame() {
	due := false
	for c := range s.clients {
		f, later := c.mirror.Frame()
		if len(f) > 0 {
			c.send(proto.FrameOutput, f)
		}
		due = due || later
	}
	if due && !s.framing {
		s.framing = true
		time.AfterFunc(50*time.Millisecond, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			s.framing = false
			s.frame()
		})
	}
}

// exited ends the session as its shell exits: a shell the user exited
// closes it, as a terminal's tab closes; one that failed stays, with its
// output, until the user closes or restarts it.
func (s *pane) exited(proc *ptyProc) {
	s.mu.Lock()
	if s.closed || s.proc != proc {
		s.mu.Unlock()
		return
	}
	code := proc.code
	s.proc = nil
	s.dropLive()
	s.info.ExitCode = code
	s.info.Process, s.info.Agent, s.info.PID = "", "", 0
	if code == 0 {
		s.mu.Unlock()
		s.d.removePane(s.info.ID)
		return
	}
	msg := fmt.Sprintf("\r\n\x1b[0;2m[Process exited with code %d]\x1b[0m", code)
	s.term.Feed([]byte(msg))
	s.frame()
	s.setStatus(proto.Exited)
	if !s.viewed() {
		s.info.Unread = true
	}
	s.mu.Unlock()
	s.d.changed()
}

// restart starts a shell again in a session that exited.
func (s *pane) restart() error {
	s.mu.Lock()
	if s.proc != nil {
		s.mu.Unlock()
		return fmt.Errorf("session %s is running", s.info.ID)
	}
	banner := "\r\n\x1b[0;2m[Restarted]\x1b[0m\r\n"
	s.term.Feed([]byte(banner))
	s.frame()
	s.setStatus(proto.Idle)
	s.info.Unread, s.info.Message, s.info.ExitCode = false, "", 0
	s.mu.Unlock()
	if err := s.start(nil, nil); err != nil {
		return err
	}
	s.d.changed()
	return nil
}

// close hangs up the shell and frees the session.
func (s *pane) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	close(s.changed) // wakes those waiting on it
	s.changed = make(chan struct{})
	proc := s.proc
	clients := s.clients
	s.clients = map[*attachment]struct{}{}
	s.mu.Unlock()
	for c := range clients {
		c.send(proto.FrameClosed, nil)
		c.finish()
	}
	if proc != nil {
		proc.Close()
		go func() {
			select {
			case <-proc.exited:
			case <-time.After(2 * time.Second):
				proc.Kill()
			}
		}()
	}
	s.term.Close()
}

// attach registers a client, returning the first frame of its mirror,
// which starts its terminal over from what the session shows; frames
// follow output.
func (s *pane) attach(c *attachment) (first []byte, cols, rows int, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, 0, 0, false
	}
	m, err := s.term.NewMirror()
	if err != nil {
		return nil, 0, 0, false
	}
	c.mirror = m
	first, _ = m.Frame()
	s.clients[c] = struct{}{}
	return first, s.info.Cols, s.info.Rows, true
}

func (s *pane) detach(c *attachment) {
	s.mu.Lock()
	if _, ok := s.clients[c]; ok {
		delete(s.clients, c)
		c.mirror.Close()
	}
	s.mu.Unlock()
}

// history returns what to save of the session, when it changed: its
// scrollback and screen down to the cursor (terminal.History), which a
// restore shows above the new shell.
func (s *pane) history(force bool) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.dirty && !force {
		return nil
	}
	s.dirty = false
	return s.term.History()
}

// readText returns the session's text: the screen, or with scrollback.
func (s *pane) readText(scrollback bool, lines int) string {
	s.mu.Lock()
	text := s.term.Text()
	rows := s.info.Rows
	s.mu.Unlock()
	all := strings.Split(strings.TrimRight(text, "\n "), "\n")
	if !scrollback && lines <= 0 {
		lines = rows
	}
	if lines > 0 && len(all) > lines {
		all = all[len(all)-lines:]
	}
	for i, l := range all {
		all[i] = strings.TrimRight(l, " ")
	}
	return strings.Join(all, "\n") + "\n"
}

// attachment is a client attached to a session: its frames go out in
// order through a queue, so that a slow client never holds the session.
type attachment struct {
	conn   net.Conn
	mirror *terminal.Mirror // what its terminal shows of the session's
	out    chan []byte
	once   sync.Once
	done   chan struct{}
}

func newAttachment(conn net.Conn) *attachment {
	return &attachment{conn: conn, out: make(chan []byte, 8192), done: make(chan struct{})}
}

func (a *attachment) send(kind byte, payload []byte) {
	f := proto.AppendFrames(nil, kind, payload)
	select {
	case a.out <- f:
	case <-a.done:
	default:
		// Too far behind: drop it, and it attaches again, from a first
		// frame.
		a.finish()
	}
}

// finish ends the attachment: the writer flushes what is queued, as a
// closing frame, then closes the connection.
func (a *attachment) finish() {
	a.once.Do(func() { close(a.done) })
}

// write sends the queued frames until the client goes.
func (a *attachment) write() {
	defer a.conn.Close()
	for {
		select {
		case f := <-a.out:
			if _, err := a.conn.Write(f); err != nil {
				a.finish()
				return
			}
		case <-a.done:
			a.conn.SetWriteDeadline(time.Now().Add(time.Second))
			for {
				select {
				case f := <-a.out:
					if _, err := a.conn.Write(f); err != nil {
						return
					}
				default:
					return
				}
			}
		}
	}
}
