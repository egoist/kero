package settings

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"kero/internal/actions"
	"kero/internal/proto"
)

// kero's configuration is a file of lines `key = value`, as Ghostty's:
// `#` starts a comment, and keys that hold lists, as env and keybind,
// repeat. The keys are Ghostty's where they mean what Ghostty's do. A
// file holds what the user changed; the rest is the defaults. The
// Settings window edits it in place, keeping its comments and order.

// ConfigPath returns the configuration file: $KERO_CONFIG, else
// $XDG_CONFIG_HOME/kero/config, else ~/.config/kero/config; kero-dev in
// place of kero for a development build (proto.Name).
func ConfigPath() string {
	if p := os.Getenv("KERO_CONFIG"); p != "" {
		return p
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, proto.Name(), "config")
}

// key is a key of the configuration: how it reads and writes a setting.
type key struct {
	name string
	doc  string
	list bool // repeats, one value a line
	get  func(*Settings) []string
	set  func(*Settings, []string) error
}

func boolKey(name, doc string, f func(*Settings) *bool) key {
	return key{name: name, doc: doc,
		get: func(s *Settings) []string { return []string{strconv.FormatBool(*f(s))} },
		set: func(s *Settings, v []string) error {
			b, err := strconv.ParseBool(v[len(v)-1])
			if err != nil {
				return fmt.Errorf("%q is not true or false", v[len(v)-1])
			}
			*f(s) = b
			return nil
		}}
}

func choiceKey(name, doc string, f func(*Settings) *string, choices ...string) key {
	return key{name: name, doc: doc + " (" + strings.Join(choices, ", ") + ")",
		get: func(s *Settings) []string { return []string{*f(s)} },
		set: func(s *Settings, v []string) error {
			c := v[len(v)-1]
			if !slices.Contains(choices, c) {
				return fmt.Errorf("%q is none of %s", c, strings.Join(choices, ", "))
			}
			*f(s) = c
			return nil
		}}
}

func stringKey(name, doc string, f func(*Settings) *string) key {
	return key{name: name, doc: doc,
		get: func(s *Settings) []string { return []string{*f(s)} },
		set: func(s *Settings, v []string) error { *f(s) = v[len(v)-1]; return nil }}
}

func numberKey(name, doc string, get func(*Settings) float64, set func(*Settings, float64)) key {
	return key{name: name, doc: doc,
		get: func(s *Settings) []string { return []string{strconv.FormatFloat(get(s), 'f', -1, 64)} },
		set: func(s *Settings, v []string) error {
			n, err := strconv.ParseFloat(v[len(v)-1], 64)
			if err != nil {
				return fmt.Errorf("%q is not a number", v[len(v)-1])
			}
			set(s, n)
			return nil
		}}
}

// mapChoice maps the values of a choice in the file to those of Settings.
func mapChoice(name, doc string, f func(*Settings) *string, file, ours []string) key {
	return key{name: name, doc: doc + " (" + strings.Join(file, ", ") + ")",
		get: func(s *Settings) []string { return []string{file[max(slices.Index(ours, *f(s)), 0)]} },
		set: func(s *Settings, v []string) error {
			i := slices.Index(file, v[len(v)-1])
			if i < 0 {
				return fmt.Errorf("%q is none of %s", v[len(v)-1], strings.Join(file, ", "))
			}
			*f(s) = ours[i]
			return nil
		}}
}

// keys are the configuration's keys, in the order a new file and
// `kero config show` list them.
var keys = []key{
	mapChoice("new-session-directory", "where a new session starts", func(s *Settings) *string { return &s.NewSessionDir },
		[]string{"current", "project", "home"}, []string{"current", "project", "home"}),
	choiceKey("session-name", "what names a session you or an agent didn't: the program in the pane you're in, else in the one that most needs you; the program in the one that most needs you; or the first pane's folder",
		func(s *Settings) *string { return &s.SessionName }, proto.NameFocused, proto.NameLead, proto.NameFolder),
	boolKey("focus-follows-mouse", "focus the pane the pointer moves into", func(s *Settings) *bool { return &s.FocusFollowsMouse }),
	boolKey("confirm-close", "ask before closing a pane a program runs in", func(s *Settings) *bool { return &s.ConfirmClose }),
	boolKey("restore-sessions", "start sessions again after kerod restarts, as after a reboot", func(s *Settings) *bool { return &s.RestoreSessions }),
	boolKey("resume-agents", "as sessions start again, resume the conversation of the coding agent each pane ran", func(s *Settings) *bool { return &s.ResumeAgents }),

	choiceKey("window-theme", "the app's appearance", func(s *Settings) *string { return &s.Appearance }, "system", "light", "dark"),
	choiceKey("language", "the app's language; system follows the system's", func(s *Settings) *string { return &s.Language }, append([]string{"system"}, Languages...)...),
	mapChoice("background", "the window's wash", func(s *Settings) *string { return &s.Background },
		[]string{"petal", "mist", "meadow", "dusk", "plain"}, []string{"rex", "mist", "meadow", "dusk", "plain"}),
	boolKey("window-translucent", "let the desktop show through the window", func(s *Settings) *bool { return &s.Vibrancy }),

	stringKey("font-family", "the terminals' font: empty for JetBrains Mono Nerd Font, which Kero carries; monospace for the system's", func(s *Settings) *string { return &s.FontFamily }),
	numberKey("font-size", "in points", func(s *Settings) float64 { return float64(s.FontSize) }, func(s *Settings, n float64) { s.FontSize = float32(n) }),
	numberKey("font-weight", "100 to 900", func(s *Settings) float64 { return float64(s.FontWeight) }, func(s *Settings, n float64) { s.FontWeight = int(n) }),
	numberKey("line-height", "a multiple of the font's", func(s *Settings) float64 { return float64(s.LineHeight) }, func(s *Settings, n float64) { s.LineHeight = float32(n) }),
	boolKey("font-ligatures", "join characters as the font draws them", func(s *Settings) *bool { return &s.Ligatures }),
	boolKey("font-thicken", "a heavier stroke, as Ghostty's", func(s *Settings) *bool { return &s.Thicken }),
	numberKey("minimum-contrast", "the least contrast text keeps with its background, 1 (none) to 21, as Ghostty's", func(s *Settings) float64 { return float64(s.MinContrast) }, func(s *Settings, n float64) { s.MinContrast = float32(min(max(n, 1), 21)) }),
	{name: "theme", doc: "terminal colors: kero, a Ghostty theme, or light:<theme>,dark:<theme>",
		get: func(s *Settings) []string {
			if s.LightTheme == s.DarkTheme {
				return []string{s.LightTheme}
			}
			return []string{"light:" + s.LightTheme + ",dark:" + s.DarkTheme}
		},
		set: func(s *Settings, v []string) error {
			val := v[len(v)-1]
			if !strings.Contains(val, ":") {
				s.LightTheme, s.DarkTheme = val, val
				return nil
			}
			for _, part := range strings.Split(val, ",") {
				k, t, ok := strings.Cut(strings.TrimSpace(part), ":")
				switch {
				case ok && k == "light":
					s.LightTheme = strings.TrimSpace(t)
				case ok && k == "dark":
					s.DarkTheme = strings.TrimSpace(t)
				default:
					return fmt.Errorf("%q: write light:<theme>,dark:<theme>", val)
				}
			}
			return nil
		}},
	choiceKey("cursor-style", "programs may change it", func(s *Settings) *string { return &s.Cursor }, "block", "bar", "underline"),
	boolKey("cursor-style-blink", "", func(s *Settings) *bool { return &s.CursorBlink }),
	boolKey("macos-option-as-alt", "Option sends Alt (Meta) to programs", func(s *Settings) *bool { return &s.OptionAsAlt }),
	boolKey("copy-on-select", "what you select goes to the clipboard", func(s *Settings) *bool { return &s.CopyOnSelect }),
	choiceKey("clipboard-read", "programs reading the clipboard (OSC 52)", func(s *Settings) *string { return &s.Clipboard }, "ask", "allow", "deny"),
	mapChoice("right-click-action", "", func(s *Settings) *string { return &s.RightClick },
		[]string{"context-menu", "paste", "copy-or-paste"}, []string{"menu", "paste", "copyOrPaste"}),

	stringKey("command", "the shell of new panes: empty for your login shell", func(s *Settings) *string { return &s.Shell }),
	{name: "env", doc: "added to every pane's environment, as NAME=value; repeat it", list: true,
		get: func(s *Settings) []string { return slices.Clone(s.Env) },
		set: func(s *Settings, v []string) error {
			s.Env = nil
			for _, kv := range v {
				if !strings.Contains(kv, "=") {
					return fmt.Errorf("%q is not NAME=value", kv)
				}
				s.Env = append(s.Env, kv)
			}
			return nil
		}},
	numberKey("scrollback-limit", "the output each pane keeps, in megabytes; 0 for none", func(s *Settings) float64 { return float64(s.Scrollback) }, func(s *Settings, n float64) { s.Scrollback = int(n) }),

	boolKey("notify-on-waiting", "when a session needs you", func(s *Settings) *bool { return &s.NotifyWaiting }),
	boolKey("notify-on-done", "when an agent finishes", func(s *Settings) *bool { return &s.NotifyDone }),
	boolKey("notify-on-error", "when a program reports it failed", func(s *Settings) *bool { return &s.NotifyFailed }),
	boolKey("notify-sound", "", func(s *Settings) *bool { return &s.NotifySound }),
	boolKey("dock-badge", "the number of sessions that need you", func(s *Settings) *bool { return &s.DockBadge }),
	boolKey("dock-bounce", "once, when a session comes to need you", func(s *Settings) *bool { return &s.BounceDock }),

	boolKey("remote-control", "kero do, kero focus and kero browser drive the app", func(s *Settings) *bool { return &s.RemoteControl }),
	boolKey("git-status", "show the git branch and changes of each session", func(s *Settings) *bool { return &s.GitStatus }),
	choiceKey("diff-layout", "the changes panel's diffs: unified while the panel is narrow and side by side once it's wide, or always one", func(s *Settings) *string { return &s.DiffLayout }, "auto", "unified", "split"),
	{name: "keybind", doc: "<keys>=<action>, over the defaults, as cmd+shift+d=pane.split.down; <keys>=unbind frees keys; see kero actions", list: true,
		get: func(s *Settings) []string {
			var out []string
			for _, a := range actions.All {
				k, ok := s.Shortcuts[a.ID]
				if !ok {
					continue
				}
				if k == "" {
					if a.Keys != "" {
						out = append(out, configKeys(a.Keys)+"=unbind")
					}
					continue
				}
				out = append(out, configKeys(k)+"="+a.ID)
			}
			return out
		},
		set: func(s *Settings, v []string) error {
			s.Shortcuts = nil
			sc := map[string]string{}
			var bad []string
			for _, b := range v {
				i := strings.LastIndex(b, "=")
				if i <= 0 {
					bad = append(bad, fmt.Sprintf("%q is not <keys>=<action>", b))
					continue
				}
				keys, id := accelerator(b[:i]), strings.TrimSpace(b[i+1:])
				if id == "unbind" {
					for _, a := range actions.All {
						if strings.EqualFold(actions.Keys(a, sc), keys) {
							sc[a.ID] = ""
						}
					}
					continue
				}
				if _, ok := actions.Find(id); !ok {
					bad = append(bad, fmt.Sprintf("no action %q", id))
					continue
				}
				sc[id] = keys
			}
			if len(sc) > 0 {
				s.Shortcuts = sc
			}
			if bad != nil {
				return fmt.Errorf("%s", strings.Join(bad, "; "))
			}
			return nil
		}},
}

func findKey(name string) *key {
	for i := range keys {
		if keys[i].name == name {
			return &keys[i]
		}
	}
	return nil
}

// configKeys writes an accelerator as the file does: "CmdOrCtrl+Shift+D"
// as "cmd+shift+d".
func configKeys(accel string) string {
	parts := strings.Split(accel, "+")
	if strings.HasSuffix(accel, "++") {
		parts = append(parts[:len(parts)-2], "plus")
	}
	for i, p := range parts {
		switch strings.ToLower(p) {
		case "cmdorctrl", "commandorcontrol", "command":
			parts[i] = "cmd"
		case "control":
			parts[i] = "ctrl"
		case "option":
			parts[i] = "alt"
		default:
			parts[i] = strings.ToLower(p)
		}
	}
	return strings.Join(parts, "+")
}

// accelerator reads keys as the file writes them: "cmd+shift+d" as
// "CmdOrCtrl+Shift+D".
func accelerator(keys string) string {
	keys = strings.TrimSpace(keys)
	parts := strings.Split(keys, "+")
	if strings.HasSuffix(keys, "++") {
		parts = append(parts[:len(parts)-2], "plus")
	}
	names := map[string]string{
		"cmd": "CmdOrCtrl", "super": "CmdOrCtrl", "command": "CmdOrCtrl", "ctrl": "Ctrl", "control": "Ctrl",
		"alt": "Alt", "opt": "Alt", "option": "Alt", "shift": "Shift",
		"enter": "Enter", "return": "Enter", "tab": "Tab", "space": "Space", "backspace": "Backspace", "delete": "Delete",
		"escape": "Escape", "esc": "Escape", "up": "Up", "down": "Down", "left": "Left", "right": "Right",
		"home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown", "plus": "Plus",
	}
	for i, p := range parts {
		l := strings.ToLower(strings.TrimSpace(p))
		if n, ok := names[l]; ok {
			parts[i] = n
		} else {
			parts[i] = strings.ToUpper(l)
		}
	}
	return strings.Join(parts, "+")
}

// line is a line of a configuration file.
type line struct {
	text       string
	key, value string // for a line setting a key
}

func parseLines(data string) []line {
	var out []line
	for _, raw := range strings.Split(strings.TrimRight(data, "\n"), "\n") {
		l := line{text: raw}
		t := strings.TrimSpace(raw)
		if t != "" && !strings.HasPrefix(t, "#") {
			if k, v, ok := strings.Cut(t, "="); ok {
				l.key = strings.TrimSpace(k)
				l.value = strings.TrimSpace(v)
				if len(l.value) >= 2 && l.value[0] == '"' && l.value[len(l.value)-1] == '"' {
					l.value = l.value[1 : len(l.value)-1]
				}
			} else {
				l.key = t // a key without a value: a problem
			}
		}
		if raw != "" || len(out) > 0 {
			out = append(out, l)
		}
	}
	if len(data) == 0 {
		return nil
	}
	return out
}

// parse reads a configuration over the defaults, with what it got wrong.
func parse(data string) (Settings, []string) {
	s := Default()
	var problems []string
	values := map[string][]string{}
	var order []string
	for n, l := range parseLines(data) {
		if l.key == "" {
			continue
		}
		if findKey(l.key) == nil {
			problems = append(problems, fmt.Sprintf("line %d: no setting %q", n+1, l.key))
			continue
		}
		if _, seen := values[l.key]; !seen {
			order = append(order, l.key)
		}
		values[l.key] = append(values[l.key], l.value)
	}
	for _, name := range order {
		k := findKey(name)
		v := values[name]
		if !k.list && v[len(v)-1] == "" && name != "font-family" && name != "command" {
			continue // a key left empty keeps its default
		}
		if err := k.set(&s, v); err != nil {
			problems = append(problems, name+": "+err.Error())
		}
	}
	s.normalize()
	return s, problems
}

func quote(v string) string {
	if v == "" || strings.ContainsAny(v, "#") || strings.TrimSpace(v) != v {
		return strconv.Quote(v)
	}
	return v
}

// format writes s into a configuration, over the file's lines: a key the
// file sets takes its new values where it is; one the file leaves out is
// written at the end when it differs from its default. Comments, blank
// lines and keys kero does not know stay as they are.
func format(s Settings, data string) string {
	def := Default()
	lines := parseLines(data)
	written := map[string]bool{}
	var out []string
	emit := func(k *key) {
		for _, v := range k.get(&s) {
			out = append(out, k.name+" = "+quote(v))
		}
		written[k.name] = true
	}
	for _, l := range lines {
		k := findKey(l.key)
		switch {
		case k == nil:
			out = append(out, l.text)
		case written[k.name]:
			// A list's other lines: its values went at its first.
		default:
			emit(k)
		}
	}
	if len(lines) == 0 {
		out = append(out, header...)
	}
	for i := range keys {
		k := &keys[i]
		if written[k.name] || slices.Equal(k.get(&s), k.get(&def)) {
			continue
		}
		emit(k)
	}
	return strings.Join(out, "\n") + "\n"
}

var header = []string{
	"# Kero's configuration, as Ghostty's: one setting a line, `key = value`.",
	"# It holds what differs from the defaults. Kero's Settings window edits",
	"# it in place, keeping your comments; what you save here applies at once.",
	"# `kero config show` lists every key, with its default.",
	"",
}

// Reference writes every key with its value in s, and what it does, as
// `kero config show` prints it.
func Reference(s Settings) string {
	var b strings.Builder
	for _, k := range keys {
		if k.doc != "" {
			b.WriteString("# " + k.doc + "\n")
		}
		vals := k.get(&s)
		if len(vals) == 0 {
			b.WriteString("# " + k.name + " =\n")
		}
		for _, v := range vals {
			b.WriteString(k.name + " = " + quote(v) + "\n")
		}
		b.WriteString("\n")
	}
	return b.String()
}
