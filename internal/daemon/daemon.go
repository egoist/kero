// Package daemon is kerod: the process that owns every session's
// pseudo-terminal, so that sessions outlive the app. The app, and the kero
// CLI, attach to it through a Unix socket; quitting the app detaches it,
// and opening it again attaches it where it left off.
package daemon

import (
	"bufio"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/terminal"

	"kero/internal/clilink"
	"kero/internal/proto"
	"kero/internal/settings"
	"kero/internal/shell"
)

// Daemon is kerod's state.
type Daemon struct {
	dir     string
	exe     string
	started time.Time
	log     *log.Logger

	mu       sync.Mutex
	projects []proto.Project
	sessions []*session
	panes    map[string]*pane
	subs     map[*controlConn]struct{}
	conns    int
	idleAt   time.Time
	ending   bool

	viewed atomic.Pointer[string]
	// theme is the colors of the client that last told them, which the
	// panes answer programs' questions about the colors with.
	theme    atomic.Pointer[terminal.Theme]
	changeCh chan struct{}
	saveCh   chan struct{}
	quit     chan struct{}
	quitOnce sync.Once
}

// Run runs the daemon until it is told to shut down, or has had no session
// and no client for a while.
func Run() error {
	dir := proto.Dir()
	if err := os.MkdirAll(filepath.Join(dir, "sessions"), 0o700); err != nil {
		return err
	}
	logf, err := os.OpenFile(filepath.Join(dir, "kerod.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logf.Close()
	if st, _ := logf.Stat(); st != nil && st.Size() > 4<<20 {
		logf.Truncate(0)
	}
	lg := log.New(logf, "", log.LstdFlags|log.Lmicroseconds)

	// One daemon at a time: the lock is the daemon's while it runs.
	lock, err := os.OpenFile(filepath.Join(dir, "kerod.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := lockFile(lock); err != nil {
		return errors.New("kerod is already running")
	}

	sock := proto.SocketPath()
	os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		return err
	}
	os.Chmod(sock, 0o600)
	defer os.Remove(sock)

	exe, _ := os.Executable()
	d := &Daemon{
		dir: dir, exe: exe, started: time.Now(), log: lg,
		subs:     map[*controlConn]struct{}{},
		panes:    map[string]*pane{},
		changeCh: make(chan struct{}, 1),
		saveCh:   make(chan struct{}, 1),
		quit:     make(chan struct{}),
		idleAt:   time.Now(),
	}
	empty := ""
	d.viewed.Store(&empty)
	lg.Printf("kerod %d started (pid %d, %s)", proto.Version, os.Getpid(), exe)
	d.linkCLI()
	d.restore()

	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	notifyStop(sigs)
	go func() {
		s := <-sigs
		lg.Printf("%v: saving and exiting", s)
		d.saveHistories(true)
		d.saveState()
		d.stop()
	}()

	go d.broadcastLoop()
	go d.saveLoop()
	go d.tickLoop()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go d.serve(conn)
		}
	}()
	<-d.quit
	ln.Close()
	return nil
}

func (d *Daemon) stop() { d.quitOnce.Do(func() { close(d.quit) }) }

// linkCLI keeps bin/kero pointing at this executable (package clilink),
// which sessions have on their PATH: the kero CLI, for agents to drive
// other sessions.
func (d *Daemon) linkCLI() {
	if d.exe == "" {
		return
	}
	if err := clilink.Link(d.exe, filepath.Join(d.dir, "bin")); err != nil {
		d.log.Printf("linking the CLI: %v", err)
	}
}

func (d *Daemon) viewedID() string { return *d.viewed.Load() }

// changed asks for the state to go to the subscribers, and to disk.
func (d *Daemon) changed() {
	select {
	case d.changeCh <- struct{}{}:
	default:
	}
	d.save()
}

// save asks for the state to go to disk.
func (d *Daemon) save() {
	select {
	case d.saveCh <- struct{}{}:
	default:
	}
}

// notice passes a program's desktop notification on to the app.
func (d *Daemon) notice(n proto.Notice) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for c := range d.subs {
		c.event(proto.Message{Event: "notice", Notice: &n})
	}
}

func (d *Daemon) broadcastLoop() {
	for range d.changeCh {
		// Coalesce a burst of changes into one message.
		time.Sleep(25 * time.Millisecond)
		select {
		case <-d.changeCh:
		default:
		}
		st := d.state()
		d.mu.Lock()
		for c := range d.subs {
			c.event(proto.Message{Event: "state", State: &st})
		}
		d.mu.Unlock()
	}
}

func (d *Daemon) tickLoop() {
	t := time.NewTicker(400 * time.Millisecond)
	defer t.Stop()
	for now := range t.C {
		d.mu.Lock()
		panes := make([]*pane, 0, len(d.panes))
		for _, p := range d.panes {
			panes = append(panes, p)
		}
		idle := len(d.sessions) == 0 && d.conns == 0
		if !idle {
			d.idleAt = now
		}
		idleFor := now.Sub(d.idleAt)
		d.mu.Unlock()
		changed := false
		for _, s := range panes {
			if s.tick(now) {
				changed = true
			}
		}
		if changed {
			d.changed()
		}
		// Nothing to keep: go, rather than linger in the background.
		if idle && idleFor > 30*time.Second {
			d.log.Printf("idle: exiting")
			d.stop()
			return
		}
	}
}

func newID() string {
	const alphabet = "abcdefghijkmnpqrstuvwxyz23456789"
	var b [7]byte
	rand.Read(b[:])
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b[:])
}

// projectFor returns the project a new session goes in: the one named, or
// the one whose directory holds dir, or a new one for dir's repository.
// d.mu is held.
func (d *Daemon) projectFor(ref, dir string) string {
	if ref != "" {
		for _, p := range d.projects {
			if p.ID == ref || strings.EqualFold(p.Name, ref) {
				return p.ID
			}
		}
		p := proto.Project{ID: newID(), Name: ref, Dir: dir}
		d.projects = append(d.projects, p)
		return p.ID
	}
	if dir == "" {
		if len(d.projects) > 0 {
			return d.projects[0].ID
		}
		dir = proto.Home()
	}
	best, bestLen := "", -1
	for _, p := range d.projects {
		if p.Dir != "" && proto.Within(dir, p.Dir) && len(p.Dir) > bestLen {
			best, bestLen = p.ID, len(p.Dir)
		}
	}
	if best != "" {
		return best
	}
	root := repoRoot(dir)
	name := filepath.Base(root)
	if root == proto.Home() {
		name = "Home"
	}
	p := proto.Project{ID: newID(), Name: name, Dir: root}
	d.projects = append(d.projects, p)
	return p.ID
}

// repoRoot returns the root of the git repository holding dir, or dir.
func repoRoot(dir string) string {
	for d := dir; ; {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d || d == proto.Home() {
			return dir
		}
		d = parent
	}
}

// environment returns the environment of a session's shell.
// ghosttyVersion is the version of Ghostty the terminal emulator, the
// terminal plugin's libghostty-vt, is built from (its build.zig.zon).
const ghosttyVersion = "1.3.2-dev"

func (d *Daemon) environment(sid, pid, shell string, extra []string) []string {
	env := make([]string, 0, len(os.Environ())+8)
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch {
		case k == "CLAUDECODE", k == "TERM_PROGRAM", k == "TERM_PROGRAM_VERSION", k == "TERM_SESSION_ID",
			k == "ITERM_SESSION_ID", k == "WINDOWID", k == "KITTY_WINDOW_ID", k == "LC_TERMINAL", k == "LC_TERMINAL_VERSION",
			k == "KERO_SESSION", k == "KERO_PANE", k == "MYGO_GHOSTTY_VT", k == "TMUX", k == "TMUX_PANE",
			strings.HasPrefix(k, "CLAUDE_CODE_"), strings.HasPrefix(k, "GHOSTTY_"),
			strings.HasPrefix(k, "VSCODE_"), strings.HasPrefix(k, "__CF"), k == "XPC_SERVICE_NAME":
			continue
		}
		env = append(env, kv)
	}
	set := func(kv string) {
		k, _, _ := strings.Cut(kv, "=")
		for i, e := range env {
			// Windows' names are of any case: its PATH is "Path".
			if ek, _, _ := strings.Cut(e, "="); ek == k || runtime.GOOS == "windows" && strings.EqualFold(ek, k) {
				env[i] = kv
				return
			}
		}
		env = append(env, kv)
	}
	set("TERM=xterm-256color")
	set("COLORTERM=truecolor")
	// kero's emulator is Ghostty's: programs that know Ghostty, as coding
	// agents for their notifications and keyboard, take it for one.
	// LC_TERMINAL names kero, as iTerm2 names itself there.
	set("TERM_PROGRAM=ghostty")
	set("TERM_PROGRAM_VERSION=" + ghosttyVersion)
	set("LC_TERMINAL=kero")
	set(fmt.Sprintf("LC_TERMINAL_VERSION=%d", proto.Version))
	// The shell the pane runs, not the one whoever started kerod had. On
	// Windows, only a POSIX shell's: programs there take $SHELL for one.
	if runtime.GOOS != "windows" || posixShell(shellName(shell)) {
		set("SHELL=" + shell)
	}
	set("KERO_SESSION=" + sid)
	set("KERO_PANE=" + pid)
	set("KERO_SOCKET=" + proto.SocketPath())
	if os.Getenv("LANG") == "" && os.Getenv("LC_ALL") == "" && os.Getenv("LC_CTYPE") == "" {
		set("LANG=en_US.UTF-8")
	}
	// The CLI, after what the user's profile puts first.
	path := os.Getenv("PATH")
	if path == "" && runtime.GOOS != "windows" {
		path = "/usr/bin:/bin:/usr/sbin:/sbin"
	}
	set("PATH=" + path + string(os.PathListSeparator) + filepath.Join(d.dir, "bin"))
	for _, kv := range settings.Load().Env {
		if strings.Contains(kv, "=") {
			set(kv)
		}
	}
	for _, kv := range extra {
		set(kv)
	}
	return env
}

// userShell returns the shell of new panes: the one Settings names, else
// the user's login shell.
func userShell() string {
	if sh := settings.Load().Shell; sh != "" {
		if st, err := os.Stat(expandHome(sh)); err == nil && !st.IsDir() {
			return expandHome(sh)
		}
		// A name on PATH, as "pwsh" or "bash" on Windows.
		if !strings.ContainsAny(sh, `/\`) {
			if p, err := exec.LookPath(sh); err == nil {
				return p
			}
		}
	}
	return shell.Login()
}

func expandHome(p string) string {
	if p == "~" {
		return proto.Home()
	}
	if strings.HasPrefix(p, "~/") || runtime.GOOS == "windows" && strings.HasPrefix(p, `~\`) {
		return filepath.Join(proto.Home(), p[2:])
	}
	return p
}

// agents are the coding agents the sidebar recognizes, by the name of
// their executable or script.
var agents = []string{
	"claude", "codex", "gemini", "opencode", "amp", "aider", "cursor-agent", "droid",
	"qwen", "goose", "crush", "copilot", "kiro-cli", "cline", "auggie", "kimi", "pi",
}

func detectAgent(name string, args []string) string {
	cands := []string{name}
	for i, a := range args {
		if i > 2 {
			break
		}
		cands = append(cands, filepath.Base(a))
	}
	for _, c := range cands {
		c = strings.ToLower(strings.TrimSuffix(c, filepath.Ext(c)))
		for _, a := range agents {
			if c == a || strings.HasPrefix(c, a+"-") && a != "pi" {
				return a
			}
		}
	}
	// Scripts installed by npm: …/node_modules/@openai/codex/bin/codex.js,
	// or …\@anthropic-ai\claude-code\cli.js, which npm's shims run on
	// Windows, where nothing names the script after the command.
	for i, a := range args {
		if i > 2 {
			break
		}
		a = strings.ReplaceAll(a, `\`, "/")
		for _, ag := range agents {
			if len(ag) > 3 && (strings.Contains(a, "/"+ag+"/") || strings.Contains(a, "/"+ag+"-code/")) {
				return ag
			}
		}
	}
	return ""
}

// controlConn is a client's control connection.
type controlConn struct {
	conn net.Conn
	wmu  sync.Mutex
	enc  *json.Encoder
	out  chan proto.Message
	done chan struct{}
}

func (c *controlConn) write(m proto.Message) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if err := c.enc.Encode(m); err != nil {
		c.conn.Close()
	}
}

// event queues an event for a subscriber, dropping it when it is far
// behind: the next state replaces it anyway.
func (c *controlConn) event(m proto.Message) {
	select {
	case c.out <- m:
	default:
	}
}

func (d *Daemon) serve(conn net.Conn) {
	d.mu.Lock()
	d.conns++
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		d.conns--
		d.mu.Unlock()
	}()
	defer conn.Close()

	r := bufio.NewReaderSize(conn, 64<<10)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := r.ReadBytes('\n')
	if err != nil {
		return
	}
	conn.SetReadDeadline(time.Time{})
	var hello proto.Hello
	if err := json.Unmarshal(line, &hello); err != nil {
		return
	}
	welcome := proto.Welcome{Version: proto.Version, PID: os.Getpid(), Started: d.started.UnixMilli(), App: mygo.App.Version()}
	if hello.Version != proto.Version {
		welcome.Error = fmt.Sprintf("kerod speaks protocol %d, the client %d", proto.Version, hello.Version)
		json.NewEncoder(conn).Encode(welcome)
		return
	}
	switch hello.Kind {
	case "attach":
		d.serveAttach(conn, r, hello, welcome)
	default:
		json.NewEncoder(conn).Encode(welcome)
		d.serveControl(conn, r)
	}
}

func (d *Daemon) serveAttach(conn net.Conn, r *bufio.Reader, hello proto.Hello, welcome proto.Welcome) {
	s := d.findPane(hello.Session)
	if s == nil {
		welcome.Error = "no session " + hello.Session
		json.NewEncoder(conn).Encode(welcome)
		return
	}
	a := newAttachment(conn)
	first, cols, rows, ok := s.attach(a)
	if !ok {
		welcome.Error = "session closed"
		json.NewEncoder(conn).Encode(welcome)
		return
	}
	defer s.detach(a)
	defer a.finish()
	welcome.Cols, welcome.Rows = cols, rows
	if err := json.NewEncoder(conn).Encode(welcome); err != nil {
		return
	}
	if _, err := conn.Write(proto.AppendFrames(nil, proto.FrameOutput, first)); err != nil {
		return
	}
	go a.write()
	for {
		kind, payload, err := proto.ReadFrame(r)
		if err != nil {
			return
		}
		switch kind {
		case proto.FrameInput:
			s.input(payload)
		case proto.FrameResize:
			if c, rr, cw, ch, ok := proto.ParseResizePixels(payload); ok {
				s.resize(c, rr, cw, ch)
			}
		case proto.FrameTheme:
			if th, ok := proto.ParseTheme(payload); ok {
				d.useTheme(th)
			}
		case proto.FrameClear:
			if len(payload) == 1 {
				s.clear(payload[0])
			}
		}
	}
}

func (d *Daemon) serveControl(conn net.Conn, r *bufio.Reader) {
	c := &controlConn{conn: conn, enc: json.NewEncoder(conn), out: make(chan proto.Message, 64), done: make(chan struct{})}
	defer close(c.done)
	defer func() {
		d.mu.Lock()
		delete(d.subs, c)
		d.mu.Unlock()
	}()
	go func() {
		for {
			select {
			case m := <-c.out:
				c.write(m)
			case <-c.done:
				return
			}
		}
	}()
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID     int64           `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(line, &req) != nil {
			continue
		}
		go func() {
			res, err := d.call(c, req.Method, req.Params)
			m := proto.Message{ID: req.ID, Result: res}
			if err != nil {
				m.Error = err.Error()
			}
			c.write(m)
		}()
	}
}
