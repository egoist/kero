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
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/egoist/mygo/plugins/terminal"

	"kero/internal/build"
	"kero/internal/clilink"
	"kero/internal/detach"
	"kero/internal/proto"
	"kero/internal/settings"
	"kero/internal/shell"
	"kero/internal/update"
)

// Daemon is kerod's state.
type Daemon struct {
	dir     string
	exe     string
	opts    Options
	started time.Time
	log     *log.Logger

	mu       sync.Mutex
	projects []proto.Project
	sessions []*session
	panes    map[string]*pane
	subs     map[*controlConn]struct{}
	// watchers are the connections that follow the state and notices,
	// as kero events does, but are no app: no action, select or browser
	// call goes to them, nor do they count as an app being open.
	watchers map[*controlConn]struct{}
	clients  map[*proto.ClientInfo]struct{} // the connections, for kero clients
	conns    int
	idleAt   time.Time
	ending   bool
	// restarting: kerod stops to start again, as a remote client asked
	// (proto.KindRestart).
	restarting bool
	// asks are the browser calls waiting for the app's answer, by the
	// number they went out with.
	asks    map[int64]chan proto.BrowserAnswer
	lastAsk int64

	viewed atomic.Pointer[string]
	// theme is the colors of the client that last told them, which the
	// panes answer programs' questions about the colors with.
	theme    atomic.Pointer[terminal.Theme]
	git      *gitFollow
	net      *listeners
	changeCh chan struct{}
	saveCh   chan struct{}
	quit     chan struct{}
	quitOnce sync.Once
}

// Options are how kerod runs.
type Options struct {
	// Serve: kerod runs in the foreground, as a service does (kero daemon
	// serve): it logs to its standard error too, and never exits for being
	// idle.
	Serve bool
	// Listen are network listeners, in place of the configuration's
	// (remote.ParseListen).
	Listen []string
}

// Run runs the daemon until it is told to shut down, or, unless it serves
// (Options.Serve) or listens on the network, has had no session and no
// client for a while.
func Run(opts Options) error {
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
	var logw io.Writer = logf
	if opts.Serve {
		logw = io.MultiWriter(logf, os.Stderr)
	}
	lg := log.New(logw, "", log.LstdFlags|log.Lmicroseconds)
	// What an update of the server build on Windows moved aside, which
	// it could not remove as it ran (update.Replace).
	if build.Server && runtime.GOOS == "windows" {
		update.RemoveOld(update.InstallDir())
	}

	// One daemon at a time: the lock is the daemon's while it runs. One
	// that takes over from a kerod restarting waits for it to let go.
	lock, err := os.OpenFile(filepath.Join(dir, "kerod.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	for wait := time.Now().Add(15 * time.Second); ; {
		err := lockFile(lock)
		if err == nil {
			break
		}
		if os.Getenv(takeoverEnv) == "" || time.Now().After(wait) {
			return errors.New("kerod is already running")
		}
		time.Sleep(100 * time.Millisecond)
	}
	os.Unsetenv(takeoverEnv)

	sock := proto.SocketPath()
	os.Remove(sock)
	ln, err := listenSocket(sock)
	if err != nil {
		return err
	}
	defer os.Remove(sock)

	exe, _ := os.Executable()
	d := &Daemon{
		dir: dir, exe: exe, opts: opts, started: time.Now(), log: lg,
		subs:     map[*controlConn]struct{}{},
		watchers: map[*controlConn]struct{}{},
		clients:  map[*proto.ClientInfo]struct{}{},
		panes:    map[string]*pane{},
		changeCh: make(chan struct{}, 1),
		saveCh:   make(chan struct{}, 1),
		quit:     make(chan struct{}),
		idleAt:   time.Now(),
	}
	d.git = newGitFollow(d)
	empty := ""
	d.viewed.Store(&empty)
	lg.Printf("kerod %d started (Kero %s, pid %d, %s)", proto.Version, build.Version(), os.Getpid(), exe)
	d.linkCLI()
	// The listeners first: Tailscale Serve's socket takes a umask of its
	// own, which no program kerod starts may get.
	d.net = d.listen()
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
	go d.git.loop()
	uid := os.Getuid()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			// The socket is its user's: anyone else's process, as root's
			// that can reach any file, is refused.
			if p := peerUID(conn); p >= 0 && uid >= 0 && p != uid {
				lg.Printf("refused a connection of uid %d", p)
				conn.Close()
				continue
			}
			go d.serve(conn, identity{peer: localPeer(conn), via: "unix"})
		}
	}()
	<-d.quit
	ln.Close()
	d.net.close()
	if d.restarting {
		d.successor()
	}
	return nil
}

// takeoverEnv tells a kerod that starts as another restarts to wait for
// its lock.
const takeoverEnv = "KERO_TAKEOVER"

// successor starts the kerod that follows this one, as it restarts: the
// service's, which its manager starts again, else one of this executable,
// which waits for this one to let go of the lock, and restores its
// sessions.
func (d *Daemon) successor() {
	if underService() {
		return
	}
	cmd := exec.Command(d.exe, os.Args[1:]...)
	cmd.Dir = proto.Home()
	cmd.Env = append(os.Environ(), takeoverEnv+"=1")
	if _, err := detach.Start(cmd); err != nil {
		d.log.Printf("restarting: %v", err)
	}
}

// underService reports whether a service manager runs kerod, which starts
// it again as it exits: the unit and the agent of kero daemon
// install-service say so.
func underService() bool { return os.Getenv("KERO_SERVICE") == "1" }

// localPeer names the process at the other end of the socket.
func localPeer(c net.Conn) string {
	if uid := peerUID(c); uid >= 0 {
		return fmt.Sprintf("uid %d", uid)
	}
	return "local"
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
	if bin := d.binFirst(); bin != "" {
		if err := writeZshenv(bin); err != nil {
			d.log.Printf("writing zsh's startup file: %v", err)
		}
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
	d.broadcastLocked(proto.Message{Event: "notice", Notice: &n})
}

// broadcastLocked sends m to the apps and the watchers; d.mu is held.
func (d *Daemon) broadcastLocked(m proto.Message) {
	for c := range d.subs {
		c.event(m)
	}
	for c := range d.watchers {
		c.watchEvent(m)
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
		// The state is taken under the lock it goes out under, so that
		// the states a connection gets are in order: a watcher tells
		// changes from the difference of two.
		d.mu.Lock()
		st := d.stateLocked()
		d.broadcastLocked(proto.Message{Event: "state", State: &st})
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
		// A server, or a kerod others reach over the network, stays.
		idle := len(d.sessions) == 0 && d.conns == 0 && !d.opts.Serve && !d.net.active()
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

// repoRoot returns the root of the git repository holding dir, or dir. A
// linked worktree's is its repository's main checkout, wherever it lies.
func repoRoot(dir string) string {
	for d := dir; ; {
		if fi, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			if !fi.IsDir() {
				if main := worktreeMain(d); main != "" {
					return main
				}
			}
			return d
		}
		parent := filepath.Dir(d)
		if parent == d || d == proto.Home() {
			return dir
		}
		d = parent
	}
}

// worktreeMain returns the main checkout of the linked worktree at dir,
// whose .git is a file, or "" when it is none: a submodule's, or a bare
// repository's worktree. The file names the worktree's git directory, and
// that directory's commondir file the repository's.
func worktreeMain(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, ".git"))
	if err != nil {
		return ""
	}
	gitdir, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir:")
	if !ok {
		return ""
	}
	gitdir = gitPath(dir, strings.TrimSpace(gitdir))
	b, err = os.ReadFile(filepath.Join(gitdir, "commondir"))
	if err != nil {
		return ""
	}
	common := gitPath(gitdir, strings.TrimSpace(string(b)))
	if filepath.Base(common) != ".git" {
		return ""
	}
	if fi, err := os.Stat(common); err != nil || !fi.IsDir() {
		return ""
	}
	return filepath.Dir(common)
}

// gitPath returns a path as git writes it, against dir when relative.
func gitPath(dir, path string) string {
	path = filepath.FromSlash(path)
	if !filepath.IsAbs(path) {
		path = filepath.Join(dir, path)
	}
	return filepath.Clean(path)
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
			k == "KERO_SESSION", k == "KERO_PANE", k == "KERO_HOST", k == "KERO_ZDOTDIR", k == takeoverEnv, k == "KERO_SERVICE", k == "INVOCATION_ID", k == "MYGO_GHOSTTY_VT", k == "TMUX", k == "TMUX_PANE",
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

// watchEvent queues an event for a watcher, which tells changes from
// each state and notice in turn: one far behind is cut off, as a stalled
// write cuts it off, rather than left to miss some without knowing.
func (c *controlConn) watchEvent(m proto.Message) {
	select {
	case c.out <- m:
	default:
		if c.conn != nil {
			c.conn.Close()
		}
	}
}

// identity is who a connection comes from, as kero clients shows it.
type identity struct {
	peer string // "uid 501", "alice@example.com"
	via  string // "unix", "tailnet", "tailnet-serve"
	// client is what the client said it is, for a remote connection.
	client string
}

// serve serves a connection of the socket.
func (d *Daemon) serve(conn net.Conn, id identity) {
	defer conn.Close()
	r := bufio.NewReaderSize(conn, 64<<10)
	conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	line, err := proto.ReadLine(r, 64<<10)
	if err != nil {
		return
	}
	conn.SetReadDeadline(time.Time{})
	d.serveHello(conn, r, line, id)
}

// serveHello serves a connection, after its Hello, line, which r reads
// on from.
func (d *Daemon) serveHello(conn net.Conn, r *bufio.Reader, line []byte, id identity) {
	d.mu.Lock()
	d.conns++
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		d.conns--
		d.mu.Unlock()
	}()
	defer conn.Close()

	var hello proto.Hello
	if err := json.Unmarshal(line, &hello); err != nil {
		return
	}
	// A bridge on this machine passes on a remote client's connection,
	// saying who it is, which kero clients shows as the bridge claims it:
	// only a bridge's ways, ssh and wsl. A listener's own say is the only
	// one of a connection it took.
	if id.via == "unix" && (hello.Via == "ssh" || hello.Via == "wsl") {
		id = identity{peer: hello.Peer, via: hello.Via, client: hello.Client}
		if id.peer == "" {
			id.peer = localPeer(conn)
		}
	}
	welcome := proto.Welcome{Version: proto.Version, PID: os.Getpid(), Started: d.started.UnixMilli(), App: build.Version(), Build: build.Daemon}
	if hello.Version != proto.Version {
		welcome.Error = fmt.Sprintf("kerod speaks protocol %d, the client %d", proto.Version, hello.Version)
		json.NewEncoder(conn).Encode(welcome)
		return
	}
	info := &proto.ClientInfo{Kind: hello.Kind, Peer: id.peer, Via: id.via, Client: id.client, Since: time.Now().UnixMilli()}
	if info.Kind != "attach" {
		info.Kind = "control"
	} else {
		info.Session = hello.Session
	}
	d.mu.Lock()
	d.clients[info] = struct{}{}
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.clients, info)
		d.mu.Unlock()
	}()
	switch hello.Kind {
	case "attach":
		d.serveAttach(conn, r, hello, welcome)
	default:
		json.NewEncoder(conn).Encode(welcome)
		d.serveControl(conn, r)
	}
}

// clientList lists the connections, the oldest first.
func (d *Daemon) clientList() []proto.ClientInfo {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make([]proto.ClientInfo, 0, len(d.clients))
	for c := range d.clients {
		out = append(out, *c)
	}
	slices.SortFunc(out, func(a, b proto.ClientInfo) int { return int(a.Since - b.Since) })
	return out
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
			if typed(payload) {
				s.claim(a)
			}
			s.input(payload)
		case proto.FrameResize:
			if c, rr, cw, ch, ok := proto.ParseResizePixels(payload); ok {
				s.ask(a, c, rr, cw, ch)
			}
		case proto.FrameClaim:
			s.claim(a)
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

// typed reports whether input a client sends is the user's, typed or
// pasted or a mouse report, and not one of the focus reports (mode 1004)
// its terminal sends as its pane gains or loses the keyboard, which an
// app moves without the user, as when the session it showed closed.
func typed(input []byte) bool {
	s := string(input)
	return s != "\x1b[I" && s != "\x1b[O"
}

func (d *Daemon) serveControl(conn net.Conn, r *bufio.Reader) {
	c := &controlConn{conn: conn, enc: json.NewEncoder(conn), out: make(chan proto.Message, 64), done: make(chan struct{})}
	defer close(c.done)
	defer func() {
		d.mu.Lock()
		delete(d.subs, c)
		delete(d.watchers, c)
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
		line, err := proto.ReadLine(r, proto.MaxLine)
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
