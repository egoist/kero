package cli

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"
	"unicode"

	"kero/internal/client"
	"kero/internal/clilink"
	"kero/internal/proto"
)

// hookCmd is what an agent runs as its session starts (the hook `kero
// skill setup` installs): it tells the agent that it runs in Kero, in
// which session and pane, and tells kerod the agent's own session, to
// resume after a restart. It never fails the agent: outside Kero, or on
// any trouble, it says nothing.
func hookCmd(args []string) error {
	agent := ""
	if len(args) > 0 {
		agent = args[0]
	}
	if agent == "context" && len(args) >= 3 {
		return contextCmd(args[1], args[2], len(args) > 3 && args[3] == "wait")
	}
	pane := os.Getenv("KERO_PANE")
	var in struct {
		Event   string `json:"hook_event_name"`
		AgentID string `json:"agent_id"`   // set for Claude Code's subagents
		Session string `json:"session_id"` // the agent's own
		Cwd     string `json:"cwd"`
		Source  string `json:"source"` // "startup", "resume", "clear", "compact"
	}
	json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&in)
	if pane == "" || in.Event != "SessionStart" || in.AgentID != "" {
		return nil
	}
	if t := os.Getenv("CODEX_THREAD_ID"); t != "" && in.Session != "" && t != in.Session {
		return nil // a Codex run by another agent in this pane, not the pane's
	}
	sid, away := os.Getenv("KERO_SESSION"), false
	c, err := client.Connect(true)
	if err != nil {
		c = nil
	} else {
		defer c.Close()
		if in.Session != "" {
			// kerod tells the pane: the environment may be that of
			// another, as when Codex's app server, which panes share,
			// runs the hook.
			var r proto.AgentSessionResult
			if c.Call("pane.agentSession", proto.AgentSessionParams{PID: os.Getpid(), Agent: agent, Session: in.Session, Dir: in.Cwd}, &r) != nil {
				return nil
			}
			pane, sid, away = r.Pane, r.Session, r.Away
		}
		if in.Source != "resume" && in.Source != "compact" {
			forgetAgentName(c, pane, sid)
		}
	}
	out := map[string]any{"hookSpecificOutput": map[string]string{
		"hookEventName":     "SessionStart",
		"additionalContext": hookContext(c, pane, sid, away),
	}}
	return json.NewEncoder(os.Stdout).Encode(out)
}

// forgetAgentName drops the name an agent gave session sid, as a new
// conversation starts in its first pane, the one the name came from: the
// session shows the pane's title again.
func forgetAgentName(c *client.Client, pane, sid string) {
	var st proto.State
	if c.Call("state", nil, &st) != nil {
		return
	}
	for _, s := range st.Sessions {
		if s.ID == sid && s.AgentNamed && len(s.Panes) > 0 && s.Panes[0].ID == pane {
			c.Call("rename", proto.RenameParams{ID: sid}, nil)
		}
	}
}

// contextCmd prints what to tell the agent of an agent's session, for an
// agent whose commands run away from its pane, as OpenCode's do in its
// service: nothing when no pane runs that session. wait gives a pane that
// runs the agent a moment to tell its session.
func contextCmd(agent, session string, wait bool) error {
	c, err := client.Connect(true)
	if err != nil {
		return nil
	}
	defer c.Close()
	for deadline := time.Now().Add(1500 * time.Millisecond); ; time.Sleep(150 * time.Millisecond) {
		var st proto.State
		if c.Call("state", nil, &st) != nil {
			return nil
		}
		pending := false
		for _, s := range st.Sessions {
			for _, p := range s.Panes {
				if a := p.AgentSession; a != nil && a.Agent == agent && a.ID == session {
					fmt.Println(hookContext(c, p.ID, s.ID, true))
					return nil
				}
				pending = pending || p.Agent == agent && (p.AgentSession == nil || p.AgentSession.ID != session)
			}
		}
		if !wait || !pending || time.Now().After(deadline) {
			return nil
		}
	}
}

// hookContext is what the hook tells an agent in pane, of session sid;
// c is kerod, nil when it is unreachable. away tells an agent whose
// commands don't run in its pane, and don't have its variables.
func hookContext(c *client.Client, pane, sid string, away bool) string {
	var b strings.Builder
	if away {
		fmt.Fprintf(&b, "You are running in Kero, a terminal for coding agents: session %s, pane %s. "+
			"The `kero` command (see the kero skill) runs things beside you, such as a dev server, tests or another agent. "+
			"Your commands don't run in your pane and don't have its $KERO_SESSION and $KERO_PANE: give kero your pane as the target, "+
			"as in `kero split %s --down -- npm run dev`.", sid, pane, pane)
	} else {
		fmt.Fprintf(&b, "You are running in Kero, a terminal for coding agents: session %s, pane %s ($KERO_SESSION and $KERO_PANE). "+
			"The `kero` command (see the kero skill) runs things beside you, such as a dev server, tests or another agent, "+
			"and tells the user what you are doing.", sid, pane)
	}
	if c == nil {
		return b.String()
	}
	var st proto.State
	if c.Call("state", nil, &st) != nil {
		return b.String()
	}
	for _, s := range st.Sessions {
		if s.ID != sid || len(s.Panes) == 0 {
			continue
		}
		switch {
		case s.AgentNamed:
			fmt.Fprintf(&b, " This conversation named the session %q: leave its name alone.", s.Name)
		case s.Name != "":
			fmt.Fprintf(&b, " The user knows this session as %q: leave its name alone.", s.Name)
		}
	}
	return b.String()
}

// integration is what kero installs in an agent, beside its skill, to
// hook it into Kero: a hook in its settings, or a plugin of its own.
type integration interface {
	name() string // the agent, as `kero hook` takes it
	path() string // where it goes
	state() string
	install() error
	remove() error
}

// agentHook is a hook kero installs in an agent's settings: a SessionStart
// command running `kero hook <agent>`.
type agentHook struct {
	agent string // as `kero hook` takes it: "claude", "codebuddy", "codex"
	file  string // the JSON file holding the agent's hooks
}

func (h agentHook) name() string { return h.agent }
func (h agentHook) path() string { return h.file }

// kero is the kero command of Kero's own directory (package clilink),
// which stays where it is as Kero updates.
func kero() string {
	exe := filepath.Join(proto.Dir(), "bin", "kero")
	if runtime.GOOS == "windows" {
		exe += ".exe"
	}
	return exe
}

// command is the hook's command line: the kero command of Kero's own
// directory (package clilink), which stays where it is as Kero updates.
func (h agentHook) command() string {
	if runtime.GOOS == "windows" {
		if h.agent == "codex" {
			return anyShell(kero()) + " hook " + h.agent
		}
		return `"` + kero() + `" hook ` + h.agent
	}
	return "'" + strings.ReplaceAll(kero(), "'", `'\''`) + "' hook " + h.agent
}

// anyShell is a program's path on Windows as a command that each shell
// Codex may run a hook in takes alike: Codex runs it in the shell of the
// user's session, cmd, Windows PowerShell, PowerShell or Git Bash, and
// in cmd without one. PowerShell takes a quoted path for a string, and
// cmd no quote but a double one, so a plain path goes bare, with forward
// slashes, which Git Bash leaves alone and the others run as well. A
// path with a space, or another character a shell reads, goes to cmd in
// double quotes: all but Git Bash take that.
func anyShell(path string) string {
	for _, r := range path {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && !strings.ContainsRune(`_-.:\/`, r) {
			return `cmd /d /c "` + path + `"`
		}
	}
	return filepath.ToSlash(path)
}

// ours tells kero's hook commands, of this kero or another's: the
// command of a program named kero, for this agent. A command of another
// program that has "kero" in its name is not kero's, and the user's own
// hook is not kero's to take away.
func (h agentHook) ours(command string) bool {
	suffix := " hook " + h.agent
	if !strings.HasSuffix(command, suffix) {
		return false
	}
	// The program the command names, without the quotes a shell reads
	// its path in: the name of the program is what tells kero's own
	// command from another's.
	program := strings.Map(func(r rune) rune {
		if r == '"' || r == '\'' {
			return -1
		}
		return r
	}, command[:len(command)-len(suffix)])
	if i := strings.LastIndexAny(program, `/\`); i >= 0 {
		program = program[i+1:]
	}
	return program == "kero" || program == "kero.exe"
}

// state is "current", "outdated" (kero's hook, of another command line),
// "missing", or "unreadable" (the file is there and cannot be read — as
// JSON, or in its hooks member).
func (h agentHook) state() string {
	b, err := os.ReadFile(h.file)
	if err != nil {
		if os.IsNotExist(err) {
			return "missing"
		}
		return "unreadable"
	}
	settings, err := parseObject(b)
	if err != nil {
		return "unreadable"
	}
	state := "missing"
	if err := h.each(settings, func(command string) {
		if command == h.command() {
			state = "current"
		} else if state == "missing" {
			state = "outdated"
		}
	}); err != nil {
		return "unreadable"
	}
	return state
}

// each calls fn with the command of each of kero's SessionStart hooks.
// An error says the file names hooks that cannot be read, which is not
// the absence of them — the same looks edit refuses the file for.
func (h agentHook) each(settings object, fn func(command string)) error {
	hooks, err := parseObject(settings.get("hooks"))
	if err != nil {
		return fmt.Errorf("%s: hooks: %w", proto.ShortDir(h.file), err)
	}
	var groups []object
	if raw := hooks.get("SessionStart"); raw != nil {
		if err := json.Unmarshal(raw, &groups); err != nil {
			return fmt.Errorf("%s: hooks.SessionStart: %w", proto.ShortDir(h.file), err)
		}
	}
	for _, g := range groups {
		var handlers []struct{ Type, Command string }
		if raw := g.get("hooks"); raw != nil {
			if err := json.Unmarshal(raw, &handlers); err != nil {
				return fmt.Errorf("%s: hooks.SessionStart.hooks: %w", proto.ShortDir(h.file), err)
			}
		}
		for _, hd := range handlers {
			if hd.Type == "command" && h.ours(hd.Command) {
				fn(hd.Command)
			}
		}
	}
	return nil
}

// install puts the hook in the agent's settings, in place of kero's
// others, keeping the rest of the file as it is.
func (h agentHook) install() error {
	linkCLI()
	return h.edit(true)
}

// linkCLI makes the kero command that hooks and plugins run, should kerod
// not have made it yet.
func linkCLI() {
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		bin := filepath.Join(proto.Dir(), "bin")
		if clilink.Target(bin) == "" {
			clilink.Link(exe, bin)
		}
	}
}

// remove takes kero's hooks out of the agent's settings.
func (h agentHook) remove() error {
	if _, err := os.Stat(h.file); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return h.edit(false)
}

func (h agentHook) edit(add bool) error {
	b, err := os.ReadFile(h.file)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	settings := object{}
	if len(bytes.TrimSpace(b)) > 0 {
		if settings, err = parseObject(b); err != nil {
			return fmt.Errorf("%s: %w", proto.ShortDir(h.file), err)
		}
	}
	hooks, err := parseObject(settings.get("hooks"))
	if err != nil {
		return fmt.Errorf("%s: hooks: %w", proto.ShortDir(h.file), err)
	}
	var groups []object
	if raw := hooks.get("SessionStart"); raw != nil {
		if err := json.Unmarshal(raw, &groups); err != nil {
			return fmt.Errorf("%s: hooks.SessionStart: %w", proto.ShortDir(h.file), err)
		}
	}
	// Already there, alone: nothing to do. Else drop kero's handlers, and
	// the groups they leave empty.
	n, exact := 0, false
	if err := h.each(settings, func(command string) {
		n++
		exact = exact || command == h.command()
	}); err != nil {
		return err
	}
	if add && n == 1 && exact || !add && n == 0 {
		return nil
	}
	kept := groups[:0]
	for _, g := range groups {
		var handlers []json.RawMessage
		json.Unmarshal(g.get("hooks"), &handlers)
		n := len(handlers)
		handlers = slices.DeleteFunc(handlers, func(raw json.RawMessage) bool {
			var hd struct{ Type, Command string }
			json.Unmarshal(raw, &hd)
			return hd.Type == "command" && h.ours(hd.Command)
		})
		if n > 0 && len(handlers) == 0 {
			continue
		}
		if len(handlers) != n {
			g = g.set("hooks", marshal(handlers))
		}
		kept = append(kept, g)
	}
	groups = kept
	if add {
		handler := object{{"type", marshal("command")}, {"command", marshal(h.command())}, {"timeout", marshal(10)}}
		groups = append(groups, object{{"hooks", marshal([]object{handler})}})
	}
	if len(groups) > 0 {
		hooks = hooks.set("SessionStart", marshal(groups))
	} else {
		hooks = hooks.del("SessionStart")
	}
	if len(hooks) > 0 {
		settings = settings.set("hooks", hooks.marshal())
	} else {
		settings = settings.del("hooks")
	}
	out := settings.marshal()
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, out, "", "  "); err != nil {
		return err
	}
	pretty.WriteByte('\n')
	if bytes.Equal(pretty.Bytes(), b) {
		return nil
	}
	return writeFileAtomic(h.file, pretty.Bytes())
}

// agentPlugin is a plugin kero installs for an agent: files of its own,
// in a directory the agent loads plugins from.
type agentPlugin struct {
	agent string
	dir   string            // where the agent loads it from
	files map[string]string // by name in dir: the asset (package agents)
	own   bool              // dir is the plugin's alone, to remove with it
}

//go:embed agents
var agentAssets embed.FS

func (p agentPlugin) name() string { return p.agent }

func (p agentPlugin) path() string {
	if p.own || len(p.files) != 1 {
		return p.dir
	}
	for name := range p.files {
		return filepath.Join(p.dir, name)
	}
	return p.dir
}

// content is a file as kero writes it: the asset, with the kero command
// it runs.
func (p agentPlugin) content(asset string) []byte {
	b, _ := agentAssets.ReadFile(asset)
	b = bytes.ReplaceAll(b, []byte("__KERO__"), marshal(kero()))
	return bytes.ReplaceAll(b, []byte("__AGENT__"), marshal(p.agent))
}

func (p agentPlugin) state() string {
	same, there, unreadable := 0, 0, false
	for name, asset := range p.files {
		b, err := os.ReadFile(filepath.Join(p.dir, name))
		if err != nil {
			if !os.IsNotExist(err) {
				// A file that is there and cannot be read tells neither
				// current nor outdated.
				unreadable = true
			}
			continue
		}
		there++
		if bytes.Equal(b, p.content(asset)) {
			same++
		}
	}
	switch {
	case unreadable:
		return "unreadable"
	case same == len(p.files):
		return "current"
	case there == 0:
		return "missing"
	}
	return "outdated"
}

// ours tells a plugin written to run this Kero's kero command, of this
// kero or an older one: not another Kero's, as a development build's.
func (p agentPlugin) ours() bool {
	for name := range p.files {
		if b, err := os.ReadFile(filepath.Join(p.dir, name)); err == nil && bytes.Contains(b, marshal(kero())) {
			return true
		}
	}
	return false
}

func (p agentPlugin) install() error {
	linkCLI()
	if err := os.MkdirAll(p.dir, 0o755); err != nil {
		return err
	}
	for name, asset := range p.files {
		if err := writeFileAtomic(filepath.Join(p.dir, name), p.content(asset)); err != nil {
			return err
		}
	}
	return nil
}

func (p agentPlugin) remove() error {
	for name := range p.files {
		if err := os.Remove(filepath.Join(p.dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if p.own {
		os.Remove(p.dir) // if nothing else is in it
	}
	return nil
}

// agentHooks returns what kero installs to hook agents into Kero: for
// Claude Code and CodeBuddy Code, and for Codex, Pi, OMP, PiG and
// OpenCode when they are installed (or named).
func agentHooks(agent string) []integration {
	home := proto.Home()
	dirOf := func(env string, def ...string) string {
		if d := os.Getenv(env); d != "" {
			return d
		}
		return filepath.Join(append([]string{home}, def...)...)
	}
	claude := dirOf("CLAUDE_CONFIG_DIR", ".claude")
	codex := dirOf("CODEX_HOME", ".codex")
	// CodeBuddy Code keeps its config under CODEBUDDY_CONFIG_DIR (default
	// ~/.codebuddy), and reads its hooks from the settings file there.
	codebuddy := dirOf("CODEBUDDY_CONFIG_DIR", ".codebuddy")
	pi := dirOf("PI_CODING_AGENT_DIR", ".pi", "agent")
	// OMP keeps its config under PI_CONFIG_DIR (default ~/.omp), with the
	// agent directory in agent/ there. It honors PI_CODING_AGENT_DIR at
	// runtime too, but that names Pi's directory as well, so install next
	// to the config root rather than risk both extensions in one file.
	ompRoot := os.Getenv("PI_CONFIG_DIR")
	if ompRoot == "" {
		ompRoot = filepath.Join(home, ".omp")
	}
	omp := filepath.Join(ompRoot, "agent")
	// PiG, a Go port of Pi, keeps its config under PIG_HOME (default
	// ~/.pig), with the agent directory in agent/ there, which
	// PIG_CODING_AGENT_DIR names. It reads neither ~/.pi nor Pi's
	// environment, so its extension goes in its own directory.
	pigRoot := os.Getenv("PIG_HOME")
	if pigRoot == "" {
		pigRoot = filepath.Join(home, ".pig")
	}
	pig := os.Getenv("PIG_CODING_AGENT_DIR")
	if pig == "" {
		pig = filepath.Join(pigRoot, "agent")
	}
	opencode := filepath.Join(dirOf("XDG_CONFIG_HOME", ".config"), "opencode")
	installed := func(dir string) bool {
		st, err := os.Stat(dir)
		return err == nil && st.IsDir()
	}
	all := []struct {
		agent, dir string
		it         integration
	}{
		{"claude", claude, agentHook{"claude", filepath.Join(claude, "settings.json")}},
		{"codebuddy", codebuddy, agentHook{"codebuddy", filepath.Join(codebuddy, "settings.json")}},
		{"codex", codex, agentHook{"codex", filepath.Join(codex, "hooks.json")}},
		{"pi", pi, agentPlugin{agent: "pi", dir: filepath.Join(pi, "extensions"), files: map[string]string{"kero.ts": "agents/pi.ts"}}},
		{"omp", omp, agentPlugin{agent: "omp", dir: filepath.Join(omp, "extensions"), files: map[string]string{"kero.ts": "agents/pi.ts"}}},
		{"pig", pig, agentPlugin{agent: "pig", dir: filepath.Join(pig, "extensions"), files: map[string]string{"kero.ts": "agents/pi.ts"}}},
		{"opencode", opencode, agentPlugin{agent: "opencode", dir: filepath.Join(opencode, "plugins", "kero"), own: true, files: map[string]string{
			"package.json": "agents/opencode/package.json", "index.js": "agents/opencode/index.js", "tui.js": "agents/opencode/tui.js",
		}}},
	}
	var out []integration
	for _, a := range all {
		switch {
		case agent == a.agent:
			// The agent that is named.
			out = append(out, a.it)
		case agent == "agents":
			// The agents that share a skill directory: not Claude Code's
			// and not CodeBuddy Code's, which have one of their own.
			if a.agent != "claude" && a.agent != "codebuddy" && installed(a.dir) {
				out = append(out, a.it)
			}
		case agent == "":
			// Every agent that is there, and Claude Code's, which Kero
			// talks to most.
			if a.agent == "claude" || installed(a.dir) {
				out = append(out, a.it)
			}
		}
	}
	return out
}

// object is a JSON object that keeps its keys' order, so that editing a
// settings file leaves the rest of it as it was.
type object []member

type member struct {
	Key string
	Val json.RawMessage
}

func parseObject(b []byte) (object, error) {
	if len(bytes.TrimSpace(b)) == 0 {
		return object{}, nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil, errors.New("not a JSON object")
	}
	var o object
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return nil, err
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		o = o.set(t.(string), v)
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("more than one JSON value")
	}
	return o, nil
}

func (o *object) UnmarshalJSON(b []byte) error {
	p, err := parseObject(b)
	*o = p
	return err
}

func (o object) get(key string) json.RawMessage {
	for _, m := range o {
		if m.Key == key {
			return m.Val
		}
	}
	return nil
}

func (o object) set(key string, v json.RawMessage) object {
	for i, m := range o {
		if m.Key == key {
			o[i].Val = v
			return o
		}
	}
	return append(o, member{key, v})
}

func (o object) del(key string) object {
	return slices.DeleteFunc(o, func(m member) bool { return m.Key == key })
}

func (o object) marshal() json.RawMessage {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, m := range o {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(marshal(m.Key))
		b.WriteByte(':')
		b.Write(m.Val)
	}
	b.WriteByte('}')
	return b.Bytes()
}

func (o object) MarshalJSON() ([]byte, error) { return o.marshal(), nil }

func marshal(v any) json.RawMessage {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.Encode(v)
	return bytes.TrimSpace(b.Bytes())
}

// writeFileAtomic replaces a file whole, keeping its mode. A file that is
// a symlink is written through: the symlink stays a symlink, and the file
// it points to changes.
func writeFileAtomic(path string, b []byte) error {
	path = linkTarget(path)
	mode := os.FileMode(0o644)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), mode); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// linkTarget is the file a path's symlinks lead to, even one not there
// yet, else the path itself. A settings file of a dotfiles repo, say, is
// a symlink to the file the repo keeps, and writing the settings must
// change that file and not take the symlink away.
func linkTarget(path string) string {
	for range 40 {
		dest, err := os.Readlink(path)
		if err != nil {
			return path
		}
		if !filepath.IsAbs(dest) {
			dest = filepath.Join(filepath.Dir(path), dest)
		}
		path = dest
	}
	return path
}
