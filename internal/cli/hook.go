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
	"reflect"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/BurntSushi/toml"

	"kero/internal/client"
	"kero/internal/clilink"
	"kero/internal/proto"
)

// hookCmd is what an agent runs as its session starts (the hook `kero
// skill setup` installs): it tells the agent that it runs in Kero, in
// which session and pane, and to name the session after its task; and
// tells kerod the agent's own session, to resume after a restart. It never
// fails the agent: outside Kero, or on any trouble, it says nothing.
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
		AgentID string `json:"agent_id"`          // set for Claude Code's subagents
		Session string `json:"session_id"`        // the agent's own
		Parent  string `json:"parent_session_id"` // set for Vibe's subagents
		Cwd     string `json:"cwd"`
		Source  string `json:"source"` // "startup", "resume", "clear", "compact"
	}
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&in); err != nil || pane == "" || in.AgentID != "" {
		return nil
	}
	if agent == "vibe" {
		// shortcut: no Vibe startup/switch hooks; replace checkpoints when available.
		if in.Session == "" || in.Parent != "" || (in.Event != "pre_tool" && in.Event != "post_agent") {
			return nil
		}
	} else if in.Event != "SessionStart" {
		return nil
	}
	if t := os.Getenv("CODEX_THREAD_ID"); agent != "vibe" && t != "" && in.Session != "" && t != in.Session {
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
		if agent != "vibe" && in.Source != "resume" && in.Source != "compact" {
			forgetAgentName(c, pane, sid)
		}
	}
	if agent == "vibe" {
		return nil
	}
	out := map[string]any{"hookSpecificOutput": map[string]string{
		"hookEventName":     "SessionStart",
		"additionalContext": hookContext(c, pane, sid, away),
	}}
	return json.NewEncoder(os.Stdout).Encode(out)
}

// forgetAgentName drops the name an agent gave session sid, as a new
// conversation starts in its first pane, the one the name came from: the
// session shows the pane's title until the new agent names its own task.
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
		case s.Panes[0].ID != pane:
			b.WriteString(" You run in one of the session's other panes: leave its name alone.")
		default:
			fmt.Fprintf(&b, " The session has no name yet. As soon as you know your task, name the session after it "+
				"in a few words joined by dashes, so the user finds it in Kero's sidebar: `kero rename %s fix-login-redirect`. "+
				"Do it once, without asking or mentioning it.", sid)
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

// agentHook installs `kero hook <agent>` in the agent's settings:
// SessionStart for Claude/Codex, or Vibe's conversation checkpoints.
type agentHook struct {
	agent string // as `kero hook` takes it
	file  string // the JSON or TOML file holding the agent's hooks
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
		return `"` + kero() + `" hook ` + h.agent
	}
	return "'" + strings.ReplaceAll(kero(), "'", `'\''`) + "' hook " + h.agent
}

// ours tells kero's hook commands, of this kero or another's.
func (h agentHook) ours(command string) bool {
	return strings.Contains(command, "kero") && strings.HasSuffix(command, " hook "+h.agent)
}

// state is "current", "outdated" (kero's hook, of another command line)
// or "missing".
func (h agentHook) state() string {
	if h.agent == "vibe" {
		return h.vibeState()
	}
	b, err := os.ReadFile(h.file)
	if err != nil {
		return "missing"
	}
	settings, err := parseObject(b)
	if err != nil {
		return "missing"
	}
	state := "missing"
	h.each(settings, func(command string) {
		if command == h.command() {
			state = "current"
		} else if state == "missing" {
			state = "outdated"
		}
	})
	return state
}

// each calls fn with the command of each of kero's SessionStart hooks.
func (h agentHook) each(settings object, fn func(command string)) {
	hooks, _ := parseObject(settings.get("hooks"))
	var groups []object
	json.Unmarshal(hooks.get("SessionStart"), &groups)
	for _, g := range groups {
		var handlers []struct{ Type, Command string }
		json.Unmarshal(g.get("hooks"), &handlers)
		for _, hd := range handlers {
			if hd.Type == "command" && h.ours(hd.Command) {
				fn(hd.Command)
			}
		}
	}
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
	if h.agent == "vibe" {
		return h.editVibe(add)
	}
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
	h.each(settings, func(command string) {
		n++
		exact = exact || command == h.command()
	})
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

func vibeHookName(name any) bool {
	return name == "kero-pre-tool" || name == "kero-post-agent"
}

func (h agentHook) vibeHandlers() []map[string]any {
	return []map[string]any{
		{"name": "kero-pre-tool", "type": "pre_tool", "command": h.command(), "timeout": int64(10)},
		{"name": "kero-post-agent", "type": "post_agent", "command": h.command(), "timeout": int64(10)},
	}
}

// vibeSettings reads all settings, validating the hook list before changing it.
func (h agentHook) vibeSettings() (map[string]any, []map[string]any, error) {
	b, err := os.ReadFile(h.file)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	settings := map[string]any{}
	if _, err := toml.Decode(string(b), &settings); err != nil {
		return nil, nil, fmt.Errorf("%s: %w", proto.ShortDir(h.file), err)
	}
	var hooks []map[string]any
	badList := fmt.Errorf("%s: hooks must be a list of tables", proto.ShortDir(h.file))
	switch raw := settings["hooks"].(type) {
	case nil:
	case []map[string]any:
		hooks = raw
	case []any:
		for _, entry := range raw {
			hook, ok := entry.(map[string]any)
			if !ok {
				return nil, nil, badList
			}
			hooks = append(hooks, hook)
		}
	default:
		return nil, nil, badList
	}
	return settings, hooks, nil
}

func (h agentHook) vibeState() string {
	_, hooks, err := h.vibeSettings()
	if err != nil {
		return "missing"
	}
	var ours []map[string]any
	for _, hook := range hooks {
		if vibeHookName(hook["name"]) {
			ours = append(ours, hook)
		}
	}
	switch {
	case reflect.DeepEqual(ours, h.vibeHandlers()):
		return "current"
	case len(ours) == 0:
		return "missing"
	}
	return "outdated"
}

func (h agentHook) editVibe(add bool) error {
	settings, hooks, err := h.vibeSettings()
	if err != nil {
		return err
	}
	var kept, ours []map[string]any
	for _, hook := range hooks {
		if !vibeHookName(hook["name"]) {
			kept = append(kept, hook)
			continue
		}
		command, _ := hook["command"].(string)
		if !h.ours(command) {
			return fmt.Errorf("%s: hook %q is not Kero's; rename it before setup or removal", proto.ShortDir(h.file), hook["name"])
		}
		ours = append(ours, hook)
	}
	wanted := h.vibeHandlers()
	if add && reflect.DeepEqual(ours, wanted) || !add && len(ours) == 0 {
		return nil
	}
	if add {
		kept = append(kept, wanted...)
	}
	if len(kept) == 0 {
		delete(settings, "hooks")
	} else {
		settings["hooks"] = kept
	}
	// shortcut: re-encoding drops comments; use a preserving editor if required.
	var out bytes.Buffer
	if err := toml.NewEncoder(&out).Encode(settings); err != nil {
		return err
	}
	return writeFileAtomic(h.file, out.Bytes())
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
	return bytes.ReplaceAll(b, []byte("__KERO__"), marshal(kero()))
}

func (p agentPlugin) state() string {
	same, there := 0, 0
	for name, asset := range p.files {
		b, err := os.ReadFile(filepath.Join(p.dir, name))
		if err != nil {
			continue
		}
		there++
		if bytes.Equal(b, p.content(asset)) {
			same++
		}
	}
	switch {
	case same == len(p.files):
		return "current"
	case there == 0:
		return "missing"
	}
	return "outdated"
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
// Claude Code, and for Codex, Pi, OpenCode and Vibe when installed (or named).
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
	pi := dirOf("PI_CODING_AGENT_DIR", ".pi", "agent")
	vibe := dirOf("VIBE_HOME", ".vibe")
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
		{"codex", codex, agentHook{"codex", filepath.Join(codex, "hooks.json")}},
		{"pi", pi, agentPlugin{agent: "pi", dir: filepath.Join(pi, "extensions"), files: map[string]string{"kero.ts": "agents/pi.ts"}}},
		{"opencode", opencode, agentPlugin{agent: "opencode", dir: filepath.Join(opencode, "plugins", "kero"), own: true, files: map[string]string{
			"package.json": "agents/opencode/package.json", "index.js": "agents/opencode/index.js", "tui.js": "agents/opencode/tui.js",
		}}},
		{"vibe", vibe, agentHook{"vibe", filepath.Join(vibe, "hooks.toml")}},
	}
	var out []integration
	for _, a := range all {
		switch {
		case agent == a.agent,
			a.agent == "claude" && agent == "",
			a.agent != "claude" && (agent == "" || agent == "agents") && installed(a.dir):
			out = append(out, a.it)
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

// writeFileAtomic replaces a file whole, keeping its mode.
func writeFileAtomic(path string, b []byte) error {
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
