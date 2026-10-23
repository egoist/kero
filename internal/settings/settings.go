// Package settings is kero's settings: one file, settings.json in kero's
// directory, that the app writes from its Settings window and kerod reads
// as it starts panes, so that the shell, its environment and the
// scrollback apply to new panes at once.
package settings

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"kero/internal/adblock"
	"kero/internal/proto"
	"kero/internal/remote"
)

// Settings are the user's choices. The zero value of a field is never a
// choice of its own: Load fills defaults in.
type Settings struct {
	// General
	NewSessionDir     string `json:"newSessionDir"`     // "current", "project" or "home"
	SessionName       string `json:"sessionName"`       // what names an unnamed session: proto.NameFocused, NameLead or NameFolder
	FocusFollowsMouse bool   `json:"focusFollowsMouse"` // a pane the pointer enters takes the focus
	ConfirmClose      bool   `json:"confirmClose"`      // before closing a pane a program runs in
	RestoreSessions   bool   `json:"restoreSessions"`   // after kerod restarts, as after a reboot
	ResumeAgents      bool   `json:"resumeAgents"`      // as it restores sessions: the agents' own
	QuitConfirm       bool   `json:"quitConfirm"`       // tell, the first time, that quitting keeps sessions

	// Appearance
	Appearance    string  `json:"appearance"`    // "system", "light" or "dark"
	Language      string  `json:"language"`      // "system", or one of Languages
	Background    string  `json:"background"`    // a wash, see Backgrounds
	Vibrancy      bool    `json:"vibrancy"`      // the window's material under the wash
	WindowOpacity float32 `json:"windowOpacity"` // how much of the wash covers the window, 0.3 to 1

	// Terminal
	FontFamily   string  `json:"fontFamily"` // "" the font kero carries; "monospace" the system's
	FontSize     float32 `json:"fontSize"`
	LineHeight   float32 `json:"lineHeight"`
	FontWeight   int     `json:"fontWeight"`
	Ligatures    bool    `json:"ligatures"`
	Thicken      bool    `json:"thicken"`
	MinContrast  float32 `json:"minContrast"`           // a WCAG ratio text keeps with its background
	DimUnfocused bool    `json:"dimUnfocusedTerminals"` // the terminals the user is not in fade
	Cursor       string  `json:"cursor"`                // "block", "bar" or "underline"
	CursorBlink  bool    `json:"cursorBlink"`
	LightTheme   string  `json:"lightTheme"` // "kero", or a Ghostty theme's name
	DarkTheme    string  `json:"darkTheme"`
	OptionAsAlt  bool    `json:"optionAsAlt"`
	CopyOnSelect bool    `json:"copyOnSelect"`
	Clipboard    string  `json:"clipboard"`  // programs reading it: "ask", "allow" or "deny"
	RightClick   string  `json:"rightClick"` // "menu", "paste" or "copyOrPaste"

	// Shell
	Shell      string   `json:"shell"` // "" the account's login shell
	Env        []string `json:"env"`   // "KEY=value", added to every pane's
	Scrollback int      `json:"scrollback"`

	// Notifications
	NotifyWaiting bool `json:"notifyWaiting"` // a session needs you
	NotifyDone    bool `json:"notifyDone"`    // an agent finished
	NotifyFailed  bool `json:"notifyFailed"`  // a program reported it failed
	NotifySound   bool `json:"notifySound"`
	DockBadge     bool `json:"dockBadge"`
	BounceDock    bool `json:"bounceDock"`

	// Agents
	RemoteControl bool `json:"remoteControl"` // kero focus and kero do drive the app

	// Git
	GitStatus  bool   `json:"gitStatus"`  // each pane's branch and changes, which kerod follows
	DiffLayout string `json:"diffLayout"` // the changes panel's diffs: "auto", "unified" or "split"

	// Browser
	BlockAds bool     `json:"blockAds"` // in browser panes, with AdLists
	AdLists  []string `json:"adLists"`  // the filter lists: adblock.Catalog's IDs, or URLs

	// Keyboard: accelerators by action, over the defaults; "" unbinds.
	Shortcuts map[string]string `json:"shortcuts,omitempty"`

	// Hosts are other machines' kerods, which the app shows beside this
	// one's and the CLI reaches with -H.
	Hosts []Host `json:"hosts,omitempty"`
	// Listen are kerod's network listeners, for clients on other machines
	// (tailnet://:7373, tailnet-serve://), and ListenAllow who may connect
	// besides the machine's owner: tailnet logins, tag:name, or *.
	Listen      []string `json:"listen,omitempty"`
	ListenAllow []string `json:"listenAllow,omitempty"`
	// RemoteUpdates lets Kero on another machine that connects update the
	// app here to its version, and restart kerod into it, as it can a
	// server build: off unless the user turns it on here.
	RemoteUpdates bool `json:"remoteUpdates,omitempty"`
}

// Host is a machine whose kerod the app shows: its name, and its address
// (package remote).
type Host struct {
	Name string `json:"name"`
	Addr string `json:"addr"`
	// RemoteControl lets the host's programs drive the app, as kero focus
	// and kero do, which remote-control lets this machine's: off unless the
	// user trusts the host with it.
	RemoteControl bool `json:"remoteControl,omitempty"`
	// Color marks the host's sessions in the sidebar and its panes: one of
	// HostColors, "" for the one its name picks.
	Color string `json:"color,omitempty"`
}

// HostColors are the colors a host takes.
var HostColors = []string{"red", "orange", "amber", "green", "teal", "blue", "purple", "pink"}

// Host returns the host of a name, else nil.
func (s *Settings) Host(name string) *Host {
	for i := range s.Hosts {
		if strings.EqualFold(s.Hosts[i].Name, name) {
			return &s.Hosts[i]
		}
	}
	return nil
}

// DefaultWindowOpacity is how much of the window's background the wash
// covers while translucent.
const DefaultWindowOpacity = 0.82

// Default returns the settings of a new install.
func Default() Settings {
	return Settings{
		NewSessionDir:   "current",
		SessionName:     proto.NameFocused,
		ConfirmClose:    true,
		RestoreSessions: true,
		ResumeAgents:    true,
		QuitConfirm:     true,
		Appearance:      "system",
		Language:        "system",
		Background:      "rex",
		Vibrancy:        true,
		WindowOpacity:   DefaultWindowOpacity,
		DimUnfocused:    true,
		FontSize:        13,
		LineHeight:      1.22,
		FontWeight:      400,
		Ligatures:       true,
		MinContrast:     3,
		Cursor:          "block",
		CursorBlink:     true,
		LightTheme:      "kero",
		DarkTheme:       "kero",
		Clipboard:       "ask",
		RightClick:      "menu",
		Scrollback:      4,
		NotifyWaiting:   true,
		NotifyDone:      true,
		NotifyFailed:    true,
		DockBadge:       true,
		RemoteControl:   true,
		GitStatus:       true,
		DiffLayout:      "auto",
		BlockAds:        true,
		AdLists:         slices.Clone(adblock.DefaultLists),
	}
}

// Languages are the languages the app is written in, as the catalogs of
// kero/locales name them.
var Languages = []string{"en", "zh-Hans"}

// Backgrounds are the washes the window can show.
var Backgrounds = []struct{ ID, Name string }{
	{"rex", "Petal"},
	{"mist", "Mist"},
	{"meadow", "Meadow"},
	{"dusk", "Dusk"},
	{"plain", "Plain"},
}

// Path returns the settings' file, the configuration (ConfigPath).
func Path() string { return ConfigPath() }

// legacyPath is where kero kept its settings before the configuration
// file, as JSON, which the first Load moves into it.
func legacyPath() string { return filepath.Join(proto.Dir(), "settings.json") }

var (
	mu       sync.Mutex
	cache    *Settings
	mtime    int64
	problems []string
)

// Load returns the settings, the defaults where the file says nothing.
// It reads the file again when it changed, so that a long-running reader,
// as kerod, sees the app's changes, and the user's.
func Load() Settings {
	mu.Lock()
	defer mu.Unlock()
	migrate()
	st, err := os.Stat(Path())
	if err != nil {
		cache, problems = nil, nil
		return Default()
	}
	if cache != nil && st.ModTime().UnixNano() == mtime {
		return clone(*cache)
	}
	b, err := os.ReadFile(Path())
	if err != nil {
		return Default()
	}
	s, probs := parse(string(b))
	cache, mtime, problems = &s, st.ModTime().UnixNano(), probs
	return clone(s)
}

// Problems returns what the file got wrong, as of the last Load: keys
// kero does not know, and values it cannot take, which keep their
// defaults.
func Problems() []string {
	mu.Lock()
	defer mu.Unlock()
	return slices.Clone(problems)
}

// migrate moves the settings of the JSON file kero kept before into the
// configuration, once; mu is held.
func migrate() {
	if _, err := os.Stat(Path()); err == nil {
		return
	}
	b, err := os.ReadFile(legacyPath())
	if err != nil {
		return
	}
	s := Default()
	if json.Unmarshal(b, &s) != nil {
		return
	}
	s.normalize()
	if write(s) == nil {
		os.Rename(legacyPath(), legacyPath()+".migrated")
	}
}

// Save writes the settings into the configuration, keeping what the user
// wrote around them (see format).
func Save(s Settings) error {
	mu.Lock()
	defer mu.Unlock()
	s.normalize()
	if err := write(s); err != nil {
		return err
	}
	c := clone(s)
	cache, problems = &c, nil
	if st, err := os.Stat(Path()); err == nil {
		mtime = st.ModTime().UnixNano()
	}
	return nil
}

// write writes the configuration; mu is held.
func write(s Settings) error {
	old, _ := os.ReadFile(Path())
	data := format(s, string(old))
	if err := os.MkdirAll(filepath.Dir(Path()), 0o755); err != nil {
		return err
	}
	tmp := Path() + ".tmp"
	if err := os.WriteFile(tmp, []byte(data), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, Path())
}

// Clone returns a copy that shares nothing with s.
func (s Settings) Clone() Settings { return clone(s) }

func clone(s Settings) Settings {
	s.Env = append([]string(nil), s.Env...)
	s.AdLists = slices.Clone(s.AdLists)
	s.Hosts = slices.Clone(s.Hosts)
	s.Listen = slices.Clone(s.Listen)
	s.ListenAllow = slices.Clone(s.ListenAllow)
	if s.Shortcuts != nil {
		m := make(map[string]string, len(s.Shortcuts))
		for k, v := range s.Shortcuts {
			m[k] = v
		}
		s.Shortcuts = m
	}
	return s
}

// normalize keeps values in range, as a file edited by hand may not.
func (s *Settings) normalize() {
	d := Default()
	oneOf := func(v *string, def string, ok ...string) {
		for _, o := range ok {
			if *v == o {
				return
			}
		}
		*v = def
	}
	oneOf(&s.NewSessionDir, d.NewSessionDir, "current", "project", "home")
	oneOf(&s.Appearance, d.Appearance, "system", "light", "dark")
	oneOf(&s.Language, d.Language, append([]string{"system"}, Languages...)...)
	oneOf(&s.Cursor, d.Cursor, "block", "bar", "underline")
	oneOf(&s.Clipboard, d.Clipboard, "ask", "allow", "deny")
	oneOf(&s.RightClick, d.RightClick, "menu", "paste", "copyOrPaste")
	oneOf(&s.DiffLayout, d.DiffLayout, "auto", "unified", "split")
	if s.WindowOpacity < 0.3 || s.WindowOpacity > 1 {
		s.WindowOpacity = d.WindowOpacity
	}
	known := false
	for _, b := range Backgrounds {
		known = known || b.ID == s.Background
	}
	if !known {
		s.Background = d.Background
	}
	if s.FontSize < 8 || s.FontSize > 36 {
		s.FontSize = d.FontSize
	}
	if s.LineHeight < 0.8 || s.LineHeight > 2.5 {
		s.LineHeight = d.LineHeight
	}
	if s.FontWeight < 100 || s.FontWeight > 900 {
		s.FontWeight = d.FontWeight
	}
	if s.Scrollback < 0 || s.Scrollback > 256 {
		s.Scrollback = d.Scrollback
	}
	if s.LightTheme == "" {
		s.LightTheme = d.LightTheme
	}
	if s.DarkTheme == "" {
		s.DarkTheme = d.DarkTheme
	}
}

// ParseHost reads a host as the configuration's host key writes it:
// name=address, then its options: remote-control, color=<one of
// HostColors>.
func ParseHost(line string) (Host, error) {
	name, rest, ok := strings.Cut(strings.TrimSpace(line), "=")
	name = strings.TrimSpace(name)
	fields := strings.Fields(rest)
	if !ok || len(fields) == 0 {
		return Host{}, fmt.Errorf("%q is not name=address", line)
	}
	if !remote.ValidName(name) {
		return Host{}, fmt.Errorf("%q can't name a host: use letters, digits, dots and dashes (and not local)", name)
	}
	a, err := remote.ParseAddr(fields[0])
	if err != nil {
		return Host{}, err
	}
	h := Host{Name: name, Addr: a.String()}
	for _, o := range fields[1:] {
		switch k, v, _ := strings.Cut(o, "="); {
		case o == "remote-control":
			h.RemoteControl = true
		case k == "color" && slices.Contains(HostColors, v):
			h.Color = v
		case k == "color":
			return Host{}, fmt.Errorf("%s: no color %q (%s)", name, v, strings.Join(HostColors, ", "))
		default:
			return Host{}, fmt.Errorf("%s: no option %q (remote-control, color=…)", name, o)
		}
	}
	return h, nil
}
