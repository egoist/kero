// Package detect tells what an agent in a terminal is doing from what its
// screen shows: working, waiting for the user (blocked), or idle at its
// prompt. A redraw shows the same screen, so it is no work, whatever made
// it: a resize, a keystroke's echo, a clock.
//
// The rules are herdr's (github.com/ogulcancelik/herdr, Apache-2.0, see
// manifests/LICENSE), a manifest per agent, which this package reads as
// herdr's engine does: of the rules that match, the one of the highest
// priority wins; with none, the agent is idle.
package detect

import (
	"bytes"
	"embed"
	"errors"
	"fmt"
	"maps"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/BurntSushi/toml"
)

// State is what an agent is doing.
type State string

const (
	Idle    State = "idle"
	Working State = "working"
	Blocked State = "blocked" // waiting for the user: a permission, a question
	Unknown State = "unknown"
)

// Input is what the rules read: the screen's text, its last rows, the
// terminal's title, and the last progress the agent reported (OSC 9;4),
// after "9;", as "4;3".
type Input struct {
	Screen   string
	Title    string
	Progress string
}

// Result is what the rules tell.
type Result struct {
	State State
	// Rule is the rule that matched, "" when none did.
	Rule string
	// Visible tells that the screen shows the state outright (a prompt
	// box, a permission dialog, a spinner), not by elimination.
	Visible bool
	// Skip tells to keep the state as it was: the screen shows something
	// that tells nothing, as a transcript viewer.
	Skip bool
}

//go:embed manifests/*.toml
var manifestFS embed.FS

// manifests names the manifest of each agent the daemon tells (see
// daemon.agents), where it is not the agent's name.
var manifests = map[string]string{
	"cursor-agent": "cursor",
	"copilot":      "github-copilot",
	"kiro-cli":     "kiro",
}

// engine is the version of herdr's rules this package reads, which a
// manifest's min_engine_version asks for.
const engine = 3

type manifest struct {
	ID    string `toml:"id"`
	Rules []rule `toml:"rules"`
	// Executables are the names of the programs the manifest is for, as
	// the daemon tells agents by (see Executable): the user's manifests'.
	Executables []string `toml:"executables"`
	Aliases     []string `toml:"aliases"`
	MinEngine   int      `toml:"min_engine_version"`
	// What herdr's manifests say of themselves, which tells nothing here.
	Version   any `toml:"version"`
	UpdatedAt any `toml:"updated_at"`
}

type rule struct {
	ID       string `toml:"id"`
	State    State  `toml:"state"`
	Priority int    `toml:"priority"`
	Region   string `toml:"region"`

	VisibleIdle    bool `toml:"visible_idle"`
	VisibleBlocker bool `toml:"visible_blocker"`
	VisibleWorking bool `toml:"visible_working"`
	Skip           bool `toml:"skip_state_update"`

	gate
}

// gate is a rule's conditions, all of which hold: every needle contained
// (ignoring case), every regex matching, every line regex matching a line,
// every gate of all, one of any (when there are any), none of not.
type gate struct {
	Contains  []string `toml:"contains"`
	Regex     []string `toml:"regex"`
	LineRegex []string `toml:"line_regex"`
	All       []gate   `toml:"all"`
	Any       []gate   `toml:"any"`
	Not       []gate   `toml:"not"`

	regex, lineRegex []*regexp.Regexp
}

// UserFile is the user's own agents, agents.toml: a manifest under
// [[agents]] each, which adds an agent or replaces the rules of one kero
// has; "" for none. It is set before the first Load: the daemon reads it
// as it starts.
var UserFile string

var (
	loadOnce    sync.Once
	loaded      map[string]*manifest // by agent
	executables map[string]string    // the user's agents, by executable
	loadErr     error
	problems    []string
)

func load() {
	loaded = map[string]*manifest{}
	entries, _ := manifestFS.ReadDir("manifests")
	for _, e := range entries {
		name := strings.TrimSuffix(e.Name(), ".toml")
		data, _ := manifestFS.ReadFile("manifests/" + e.Name())
		m, err := parse(data, false)
		if err != nil {
			loadErr = fmt.Errorf("detect: %s: %w", e.Name(), err)
			return
		}
		loaded[name] = m
	}
	var user map[string]*manifest
	user, executables, problems = readUser(UserFile)
	maps.Copy(loaded, user)
}

// parse reads a manifest; strict, it holds it to what this package
// reads, as it does the user's: no key it does not know, a state and a
// region it knows.
func parse(data []byte, strict bool) (*manifest, error) {
	m := &manifest{}
	md, err := toml.Decode(string(data), m)
	if err != nil {
		return nil, err
	}
	if strict {
		if keys := md.Undecoded(); len(keys) > 0 {
			return nil, fmt.Errorf("unknown key %s", keys[0])
		}
		if m.MinEngine > engine {
			return nil, fmt.Errorf("min_engine_version %d: this version of kero reads version %d", m.MinEngine, engine)
		}
		if len(m.Rules) == 0 {
			return nil, errors.New("no rules")
		}
	}
	for i := range m.Rules {
		r := &m.Rules[i]
		if r.Region == "" {
			r.Region = "whole_recent"
		}
		if strict {
			if r.ID == "" {
				return nil, fmt.Errorf("rule %d: no id", i+1)
			}
			switch r.State {
			case Idle, Working, Blocked, Unknown:
			default:
				return nil, fmt.Errorf("rule %s: state %q is not idle, working, blocked or unknown", r.ID, r.State)
			}
			if !validRegion(r.Region) {
				return nil, fmt.Errorf("rule %s: unknown region %q", r.ID, r.Region)
			}
		}
		if err := r.compile(); err != nil {
			return nil, fmt.Errorf("rule %s: %w", r.ID, err)
		}
	}
	return m, nil
}

// readUser reads the user's agents in file: those that read, by the
// agent they are for, with the executables of each; and what is wrong
// with the others, which are left out, one line each.
func readUser(file string) (ms map[string]*manifest, exes map[string]string, problems []string) {
	ms, exes = map[string]*manifest{}, map[string]string{}
	if file == "" {
		return
	}
	data, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	var raw map[string]any
	if err == nil {
		_, err = toml.Decode(string(data), &raw)
	}
	if err != nil {
		return ms, exes, []string{fmt.Sprintf("%s: %v", file, err)}
	}
	for k := range raw {
		if k != "agents" {
			problems = append(problems, fmt.Sprintf("%s: unknown key %s: agents go under [[agents]]", file, k))
		}
	}
	var list []map[string]any
	switch v := raw["agents"].(type) {
	case nil:
	case []map[string]any:
		list = v
	case []any:
		for _, a := range v {
			t, _ := a.(map[string]any)
			list = append(list, t)
		}
	default:
		problems = append(problems, fmt.Sprintf("%s: agents is not an array of tables, [[agents]]", file))
	}
	seen := map[string]bool{}
	for i, a := range list {
		label := fmt.Sprintf("agent %d", i+1)
		if id, ok := a["id"].(string); ok && id != "" {
			label = id
		}
		// Each agent reads as a manifest of its own, as kero's do.
		var buf bytes.Buffer
		err := toml.NewEncoder(&buf).Encode(a)
		var m *manifest
		if err == nil {
			m, err = parse(buf.Bytes(), true)
		}
		if err == nil {
			err = addUser(ms, exes, seen, m)
		}
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: %s: %v", file, label, err))
		}
	}
	return
}

func addUser(ms map[string]*manifest, exes map[string]string, seen map[string]bool, m *manifest) error {
	id := m.ID
	if id == "" {
		return errors.New("no id")
	}
	key := builtin(id)
	if key == "" {
		key = id
	}
	if seen[key] {
		return fmt.Errorf("%s is there twice", id)
	}
	name := agentName(key)
	list := m.Executables
	if len(list) == 0 && builtin(id) == "" {
		// A new agent: its program has its name.
		list = []string{id}
	}
	for _, x := range list {
		x = strings.ToLower(strings.TrimSpace(x))
		if x == "" || strings.ContainsAny(x, `/\`) {
			return fmt.Errorf("executable %q is not a program's name", x)
		}
		if a, ok := exes[x]; ok && a != name {
			return fmt.Errorf("executable %q is also %s's", x, a)
		}
	}
	for _, x := range list {
		exes[strings.ToLower(strings.TrimSpace(x))] = name
	}
	seen[key] = true
	ms[key] = m
	return nil
}

// builtin returns the file name of the manifest kero has for an agent,
// by its name, the daemon's name for it, its id or an alias; "" for
// none.
func builtin(name string) string {
	if n, ok := manifests[name]; ok {
		return n
	}
	entries, _ := manifestFS.ReadDir("manifests")
	for _, e := range entries {
		stem := strings.TrimSuffix(e.Name(), ".toml")
		if stem == name {
			return stem
		}
		data, _ := manifestFS.ReadFile("manifests/" + e.Name())
		var head struct {
			ID      string   `toml:"id"`
			Aliases []string `toml:"aliases"`
		}
		toml.Decode(string(data), &head)
		if head.ID == name || slices.Contains(head.Aliases, name) {
			return stem
		}
	}
	return ""
}

// agentName is the daemon's name of the agent of a manifest.
func agentName(key string) string {
	for a, n := range manifests {
		if n == key {
			return a
		}
	}
	return key
}

// Load reads the manifests, reporting the first of kero's that does not
// compile. The user's that do not are left out, and Problems tells why.
func Load() error {
	loadOnce.Do(load)
	return loadErr
}

// Problems tells what is wrong with the user's agents that Load left
// out, one line each, naming the file and the agent.
func Problems() []string {
	Load()
	return problems
}

// Check reads the user's agents in file, as the daemon would, telling
// the agents that read and what is wrong with the others.
func Check(file string) (agents []string, problems []string) {
	ms, _, problems := readUser(file)
	for k := range ms {
		agents = append(agents, agentName(k))
	}
	slices.Sort(agents)
	return agents, problems
}

// Executable returns the agent of the user's manifests a program is, by
// the name of its executable, lowercase and without its extension; ""
// for none.
func Executable(name string) string {
	if Load() != nil {
		return ""
	}
	return executables[name]
}

// Known reports whether there are rules for the agent.
func Known(agent string) bool {
	return find(agent) != nil
}

func find(agent string) *manifest {
	if Load() != nil || agent == "" {
		return nil
	}
	if n, ok := manifests[agent]; ok {
		agent = n
	}
	return loaded[agent]
}

// Detect tells what the agent is doing, from its manifest's rules.
func Detect(agent string, in Input) Result {
	m := find(agent)
	if m == nil {
		return Result{State: Unknown}
	}
	var won *rule
	for i := range m.Rules {
		r := &m.Rules[i]
		if won != nil && won.Priority >= r.Priority {
			continue
		}
		text := region(in, r.Region)
		if r.matches(text, strings.ToLower(text)) {
			won = r
		}
	}
	if won == nil {
		return Result{State: Idle}
	}
	res := Result{State: won.State, Rule: won.ID, Skip: won.Skip}
	switch won.State {
	case Idle:
		res.Visible = won.VisibleIdle
	case Blocked:
		res.Visible = won.VisibleBlocker
	case Working:
		res.Visible = won.VisibleWorking
	}
	return res
}

func (g *gate) compile() error {
	for i, s := range g.Contains {
		g.Contains[i] = strings.ToLower(s)
	}
	for _, s := range g.Regex {
		re, err := regexp.Compile(goRegex(s))
		if err != nil {
			return err
		}
		g.regex = append(g.regex, re)
	}
	for _, s := range g.LineRegex {
		re, err := regexp.Compile(goRegex(s))
		if err != nil {
			return err
		}
		g.lineRegex = append(g.lineRegex, re)
	}
	for _, gs := range [][]gate{g.All, g.Any, g.Not} {
		for i := range gs {
			if err := gs[i].compile(); err != nil {
				return err
			}
		}
	}
	return nil
}

// rustEscape is Rust's \u{…} and \uXXXX, which Go's regexp spells \x{…}.
var rustEscape = regexp.MustCompile(`\\u(\{[0-9A-Fa-f]+\}|[0-9A-Fa-f]{4})`)

// goRegex translates a manifest's regex, written for Rust's regex crate,
// to Go's, which takes the same syntax but for \u escapes and Unicode's
// property names.
func goRegex(s string) string {
	s = strings.ReplaceAll(s, `\p{Alphabetic}`, `\pL`)
	return rustEscape.ReplaceAllStringFunc(s, func(m string) string {
		return `\x{` + strings.Trim(m[2:], "{}") + "}"
	})
}

func (g *gate) matches(text, lower string) bool {
	for _, s := range g.Contains {
		if !strings.Contains(lower, s) {
			return false
		}
	}
	for _, re := range g.regex {
		if !re.MatchString(text) {
			return false
		}
	}
	for _, re := range g.lineRegex {
		if !anyLine(text, re) {
			return false
		}
	}
	for i := range g.All {
		if !g.All[i].matches(text, lower) {
			return false
		}
	}
	if len(g.Any) > 0 {
		ok := false
		for i := range g.Any {
			if g.Any[i].matches(text, lower) {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	for i := range g.Not {
		if g.Not[i].matches(text, lower) {
			return false
		}
	}
	return true
}

func anyLine(text string, re *regexp.Regexp) bool {
	for line := range strings.Lines(text) {
		if re.MatchString(strings.TrimRight(line, "\r\n")) {
			return true
		}
	}
	return false
}

// --- regions: the parts of the screen a rule reads ---

func region(in Input, spec string) string {
	s := in.Screen
	switch spec = strings.TrimSpace(spec); spec {
	case "osc_title":
		return in.Title
	case "osc_progress":
		return in.Progress
	case "whole_recent":
		return s
	case "after_last_prompt_marker":
		ls := lines(s)
		for i := len(ls) - 1; i >= 0; i-- {
			if promptLine(ls[i]) {
				return join(ls[i+1:])
			}
		}
		return s
	case "before_current_prompt_marker":
		ls := lines(s)
		if i := currentPrompt(ls); i >= 0 {
			return join(ls[:i])
		}
		return s
	case "whole_recent_without_current_prompt_marker":
		if currentPrompt(lines(s)) >= 0 {
			return ""
		}
		return s
	case "current_prompt_block_marker":
		ls := lines(s)
		if i := currentPrompt(ls); i >= 0 {
			for j := i - 1; j >= 0; j-- {
				if blockLine(ls[j]) {
					return ls[j]
				}
			}
		}
		return ""
	case "after_current_prompt_block_marker":
		ls := lines(s)
		if i := currentPrompt(ls); i >= 0 {
			for j := i - 1; j >= 0; j-- {
				if blockLine(ls[j]) {
					return join(ls[j:])
				}
			}
		}
		return ""
	case "prompt_box_body":
		ls := lines(s)
		top := promptBoxTop(ls)
		if top < 0 {
			return ""
		}
		end := len(ls)
		for j := top + 1; j < len(ls); j++ {
			if horizontalRule(ls[j]) {
				end = j
				break
			}
		}
		return join(ls[top+1 : end])
	case "above_prompt_box":
		return abovePromptBox(s)
	case "last_non_empty_above_prompt_box":
		ls := lines(abovePromptBox(s))
		for i := len(ls) - 1; i >= 0; i-- {
			if strings.TrimSpace(ls[i]) != "" {
				return ls[i]
			}
		}
		return ""
	case "after_last_horizontal_rule":
		ls := lines(s)
		for i := len(ls) - 1; i >= 0; i-- {
			if horizontalRule(ls[i]) {
				return join(ls[i+1:])
			}
		}
		return s
	}
	if n, ok := count(spec, "bottom_lines"); ok {
		ls := lines(s)
		return join(ls[max(0, len(ls)-n):])
	}
	if n, ok := count(spec, "bottom_non_empty_lines"); ok {
		ls := lines(s)
		for i := len(ls) - 1; i >= 0; i-- {
			if strings.TrimSpace(ls[i]) != "" {
				if n--; n == 0 {
					return join(ls[i:])
				}
			}
		}
		return s
	}
	if n, ok := count(spec, "top_non_empty_lines"); ok {
		ls := lines(s)
		end := 0
		for i := range ls {
			if strings.TrimSpace(ls[i]) != "" {
				end = i + 1
				if n--; n == 0 {
					break
				}
			}
		}
		return join(ls[:end])
	}
	return ""
}

// validRegion reports whether region reads a region it knows.
func validRegion(spec string) bool {
	switch strings.TrimSpace(spec) {
	case "osc_title", "osc_progress", "whole_recent", "after_last_prompt_marker",
		"before_current_prompt_marker", "whole_recent_without_current_prompt_marker",
		"current_prompt_block_marker", "after_current_prompt_block_marker",
		"prompt_box_body", "above_prompt_box", "last_non_empty_above_prompt_box",
		"after_last_horizontal_rule":
		return true
	}
	for _, n := range []string{"bottom_lines", "bottom_non_empty_lines", "top_non_empty_lines"} {
		if _, ok := count(strings.TrimSpace(spec), n); ok {
			return true
		}
	}
	return false
}

func count(spec, name string) (int, bool) {
	rest, ok := strings.CutPrefix(spec, name+"(")
	if !ok {
		return 0, false
	}
	rest, ok = strings.CutSuffix(rest, ")")
	if !ok {
		return 0, false
	}
	n, err := strconv.Atoi(rest)
	return n, err == nil && n > 0
}

func lines(s string) []string {
	s = strings.TrimSuffix(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func join(ls []string) string {
	if len(ls) == 0 {
		return ""
	}
	return strings.Join(ls, "\n") + "\n"
}

// promptLine is Codex's prompt: "›" at the start of a line.
func promptLine(l string) bool { return l == "›" || strings.HasPrefix(l, "› ") }

// blockLine starts one of Codex's transcript blocks.
func blockLine(l string) bool {
	return strings.HasPrefix(l, "•") || strings.HasPrefix(l, "■") || strings.HasPrefix(l, "✗") || strings.HasPrefix(l, "✓")
}

// currentPrompt is the index of Codex's prompt line, unless a block comes
// after it; -1 for none.
func currentPrompt(ls []string) int {
	for i := len(ls) - 1; i >= 0; i-- {
		if promptLine(ls[i]) {
			for _, l := range ls[i+1:] {
				if blockLine(l) {
					return -1
				}
			}
			return i
		}
	}
	return -1
}

// promptBoxTop is the index of the prompt box's top border, the second
// rule from the bottom; -1 for none.
func promptBoxTop(ls []string) int {
	n := 0
	for i := len(ls) - 1; i >= 0; i-- {
		if horizontalRule(ls[i]) {
			if n++; n == 2 {
				return i
			}
		}
	}
	return -1
}

func abovePromptBox(s string) string {
	ls := lines(s)
	if top := promptBoxTop(ls); top >= 0 {
		return join(ls[:top])
	}
	return s
}

// horizontalRule is a line of "─", or one starting with three, as a box's
// border with a label.
func horizontalRule(l string) bool {
	t := strings.TrimSpace(l)
	n := 0
	for _, r := range t {
		if r != '─' {
			break
		}
		n++
	}
	if n == 0 {
		return false
	}
	rest := strings.TrimSpace(t[n*len("─"):])
	return rest == "" || n >= 3
}
