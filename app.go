package main

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"

	"kero/internal/actions"
	"kero/internal/client"
	"kero/internal/proto"
	"kero/internal/settings"

	"kero/locales"
)

// connState is how the app stands with kerod.
type connState int

const (
	connConnecting connState = iota
	connReady
	connVersion // kerod of another version runs
	connFailed
)

// prefs are what the app remembers between runs; the sessions themselves
// are kerod's.
type prefs struct {
	Selected      string          `json:"selected,omitempty"`
	SidebarWidth  float32         `json:"sidebarWidth,omitempty"`
	SidebarHidden bool            `json:"sidebarHidden,omitempty"`
	Collapsed     map[string]bool `json:"collapsed,omitempty"`
	FontSize      float32         `json:"fontSize,omitempty"`
	// Side is the view the side panel shows, "" while it is hidden, and
	// SideWidth its width.
	Side      string  `json:"side,omitempty"`
	SideWidth float32 `json:"sideWidth,omitempty"`
}

const (
	defaultSidebar = 268
	minSidebar     = 200
	maxSidebar     = 440
	defaultFont    = 13
	maxTerms       = 12 // terminals kept attached, most recently shown
)

// termEntry is a session's terminal in the app: attached to kerod, which
// streams the session to it.
type termEntry struct {
	term    *terminal.Terminal
	stream  *client.Stream
	err     string
	started time.Time
}

// App is the app's state. It lives on the main thread: other goroutines
// change it through Window.Update.
type App struct {
	win *mygo.Window

	// hosts are the kerods the app shows, this machine's first; st is
	// what they hold, each host's sessions and projects after the one's
	// before, and owner the host of each session, pane and project.
	hosts  []*host
	owner  map[string]*host
	st     proto.State
	loaded bool // a state came

	prefs      prefs
	set        settings.Settings // the user's settings: Settings' controls edit it
	applied    settings.Settings // set, as last applied and saved
	setWin     *mygo.Window      // the Settings window, while open
	ss         settingsState
	selected   string
	terms      map[string]*termEntry
	webs       map[string]*webEntry // browser panes' pages, by pane
	lru        []string
	refs       map[string]*ui.Handle // panes' terminals, and splits, by id
	focus      map[string]string     // the pane the user is in, by session
	layoutDrag struct {              // the split whose divider is dragged
		session, split string
		ratio          float64 // where the pointer puts it, past its bounds
	}

	active   bool
	focused  bool
	statuses map[string]proto.Status // as last seen, for notifications

	renaming        string
	renamingProject string
	renameBuf       string

	renameFrames int
	chrome       chrome // where the sidebar's animation puts things

	pal          paletteState
	find         findState
	confirm      *confirmation
	sideDrag     float32 // the width as a drag of the sidebar's edge began
	pendingToast string
	// later are actions that change what the view is building, run once
	// it is built.
	later []func()

	// Focus follows the mouse: the pane the pointer went into, and where
	// the pointer was last over a pane, in the window.
	hoverPane string
	hoverAt   [2]float32

	// Panes dragged: the zone last under the pointer, the pane whose
	// drop preview shows and since when, and the panes just moved, which
	// spring in.
	lastZone     dropZone
	previewKey   string
	previewSince time.Time
	previewShown bool
	arrived      map[string]bool
	copyText     string
	peek         peek // the image a path Command hovers shows
	// from is the host whose program asked for the action being run (kero
	// do), nil for the user's.
	from   *host
	picker folderPicker // the folders of a host, to open a project in
	side   sideState    // the side panel, beside a session's panes
}

// confirmation is a question the app asks before something it cannot undo.
type confirmation struct {
	open    bool
	title   string
	detail  string
	action  string
	destroy bool
	run     func()
}

func newApp() *App {
	a := &App{terms: map[string]*termEntry{}, webs: map[string]*webEntry{}, statuses: map[string]proto.Status{}, active: true, focused: true,
		refs: map[string]*ui.Handle{}, focus: map[string]string{}, arrived: map[string]bool{}}
	a.loadPrefs()
	a.set = settings.Load()
	a.ss.problems = settings.Problems()
	a.applied = a.set.Clone()
	a.selected = a.prefs.Selected
	a.hosts = []*host{{conn: connConnecting}}
	return a
}

func prefsPath() string { return filepath.Join(proto.Dir(), "app.json") }

func (a *App) loadPrefs() {
	if b, err := os.ReadFile(prefsPath()); err == nil {
		json.Unmarshal(b, &a.prefs)
	}
	if a.prefs.SidebarWidth == 0 {
		a.prefs.SidebarWidth = defaultSidebar
	}
	a.prefs.SidebarWidth = min(max(a.prefs.SidebarWidth, minSidebar), maxSidebar)
	if a.prefs.FontSize == 0 {
		a.prefs.FontSize = defaultFont
	}
	if a.prefs.Collapsed == nil {
		a.prefs.Collapsed = map[string]bool{}
	}
}

func (a *App) savePrefs() {
	a.prefs.Selected = a.selected
	b, err := json.MarshalIndent(a.prefs, "", "  ")
	if err != nil {
		return
	}
	os.MkdirAll(proto.Dir(), 0o700)
	tmp := prefsPath() + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		os.Rename(tmp, prefsPath())
	}
}

// update runs fn on the main thread, and draws.
func (a *App) update(fn func()) {
	if a.win != nil {
		a.win.Update(fn)
	}
}

func (a *App) event(h *host, cl *client.Client, m proto.Message) {
	if h.cl != cl {
		return
	}
	switch m.Event {
	case "state":
		if m.State != nil {
			a.setState(h, *m.State)
		}
	case "select":
		// A host shows its own sessions, none of another machine.
		if !a.remoteControl(h) || a.hostOf(m.Select) != h {
			return
		}
		a.selectSession(m.Select)
		if a.win != nil {
			a.win.Show()
			a.win.Focus()
			mygo.App.Focus()
		}
	case "action":
		if !a.remoteControl(h) {
			return
		}
		if act, ok := actions.Find(m.Action); ok && act.Remote {
			a.from = h
			a.run(act.ID, m.Args)
			a.from = nil
		}
	case "browser":
		// kero browser waits on the answer, which refuses when Remote
		// Control is off, not as an action does, silently.
		if r := m.Browser; r != nil {
			a.browse(h, r, func(res *proto.BrowserResult, err error) {
				ans := proto.BrowserAnswer{Req: r.Req, Result: res}
				if err != nil {
					ans.Result, ans.Error = nil, err.Error()
				}
				cl.Go("browser.answer", ans, nil)
			})
		}
	case "notice":
		// A program's own notification, as a terminal shows it: not
		// while the user looks at its session.
		n := m.Notice
		s := a.session(n.Session)
		if s == nil || n.Session == a.selected && a.active {
			return
		}
		title := n.Title
		if title == "" {
			title = s.DisplayName(a.set.SessionName)
		}
		// A program on another machine says what it likes: the host's
		// name says where it is.
		if h.remote() {
			title = h.name + ": " + title
		}
		a.showNotification(n.Session, title, n.Body)
	}
}

// setState takes a host's state.
func (a *App) setState(h *host, st proto.State) {
	first, hostFirst := !a.loaded, !h.loaded
	h.loaded = true
	// A divider dragged keeps the ratios it set, which the daemon hears of
	// only once it is let go.
	var dragged *proto.Layout
	if s := a.session(a.layoutDrag.session); s != nil {
		dragged = s.Layout
	}
	a.mergeState(h, st)
	a.loaded = true
	if s := a.session(a.layoutDrag.session); s != nil && s.Layout.SameShape(dragged) {
		s.Layout = dragged
	}
	// Terminals of panes gone go too.
	live := map[string]bool{}
	for _, s := range a.st.Sessions {
		for _, p := range s.Panes {
			live[p.ID] = true
		}
	}
	for id := range a.terms {
		if !live[id] {
			a.dropTerm(id)
		}
	}
	for id := range a.webs {
		if !live[id] {
			a.dropWeb(id)
		}
	}
	if a.session(a.selected) == nil {
		a.reselect()
	} else if first || hostFirst && a.hostOf(a.selected) == h {
		a.selectSession(a.selected)
	}
	a.notify(first)
	a.updateTitle()
}

// showNotification shows a notification about a session, which a click
// on it selects.
func (a *App) showNotification(id, title, body string) {
	if !mygo.NotificationsSupported() {
		return
	}
	n := mygo.NewNotification(mygo.NotificationOptions{ID: "session/" + id, Group: id, Title: title, Body: body, Silent: !a.set.NotifySound})
	n.OnClick(func() {
		a.update(func() {
			a.selectSession(id)
			a.win.Show()
			a.win.Focus()
		})
		n.Close()
	})
	go n.Show()
}

// notify tells about sessions that came to need the user, or finished,
// while the user was elsewhere: a notification, and the Dock's badge.
func (a *App) notify(first bool) {
	waiting := 0
	for i := range a.st.Sessions {
		s := &a.st.Sessions[i]
		// A host the app lost shows its sessions as they were: what they
		// say is old news, which tells nothing.
		if h := a.hostOf(s.ID); h.remote() && h.conn != connReady {
			continue
		}
		prev, seen := a.statuses[s.ID]
		a.statuses[s.ID] = s.Status
		if s.Status == proto.Waiting {
			waiting++
		}
		if first || !seen || prev == s.Status || s.ID == a.selected && a.active {
			continue
		}
		var title, body string
		switch {
		case s.Status == proto.Waiting && a.set.NotifyWaiting:
			title, body = locales.NotifyNeedsYouTitle(a.hostedName(s)), s.Message
			if body == "" {
				body = locales.NotifyWaitingBody()
			}
		case s.Status == proto.Failed && a.set.NotifyFailed:
			title, body = locales.NotifyFailedTitle(a.hostedName(s)), s.Message
			if body == "" {
				body = locales.NotifyFailedBody(s.PaneName())
			}
		case s.Status == proto.Idle && prev == proto.Working && s.Unread && a.set.NotifyDone && (s.Agent != "" || s.Message != ""):
			title, body = locales.NotifyDoneTitle(a.hostedName(s)), s.Message
			if body == "" {
				body = locales.NotifyDoneBody(s.Agent, a.hostOf(s.ID).shortDir(s.WorkDir()))
			}
		default:
			continue
		}
		if a.set.BounceDock && (s.Status == proto.Waiting || s.Status == proto.Failed) {
			mygo.App.Dock.Bounce(false)
		}
		a.showNotification(s.ID, title, body)
	}
	for id := range a.statuses {
		if h := a.hostOf(id); a.session(id) == nil || h.remote() && h.conn != connReady {
			delete(a.statuses, id)
		}
	}
	if !a.set.DockBadge {
		waiting = 0
	}
	mygo.App.SetBadgeCount(waiting)
}

func (a *App) updateTitle() {
	if a.win == nil {
		return
	}
	title := "Kero"
	if s := a.session(a.selected); s != nil {
		title = a.hostedName(s)
	}
	a.win.SetTitle(title)
}

func (a *App) session(id string) *proto.Session {
	if id == "" {
		return nil
	}
	for i := range a.st.Sessions {
		if a.st.Sessions[i].ID == id {
			return &a.st.Sessions[i]
		}
	}
	return nil
}

func (a *App) project(id string) *proto.Project {
	for i := range a.st.Projects {
		if a.st.Projects[i].ID == id {
			return &a.st.Projects[i]
		}
	}
	return nil
}

// group is a project with its sessions, as the sidebar lists them.
type group struct {
	host     *host
	project  proto.Project
	sessions []*proto.Session
	// first: the first of its host's in the sidebar, whose header tells
	// how the app stands with the host.
	first bool
}

// key is what the group's collapse is remembered by: its project's id,
// and for a remote host's sessions of no project, its host's.
func (g group) key() string {
	if g.project.ID == "" && g.host.remote() {
		return "other:" + g.host.name
	}
	return g.project.ID
}

// groups returns the projects of every host, as the sidebar lists them.
func (a *App) groups() []group {
	var gs []group
	for _, h := range a.hosts {
		gs = append(gs, a.hostGroups(h)...)
	}
	return gs
}

// hostGroups returns a host's projects, with their sessions.
func (a *App) hostGroups(h *host) []group {
	var gs []group
	known := map[string]bool{}
	for _, p := range a.st.Projects {
		if a.hostOf(p.ID) != h {
			continue
		}
		known[p.ID] = true
		g := group{host: h, project: p}
		for i := range a.st.Sessions {
			if a.st.Sessions[i].Project == p.ID {
				g.sessions = append(g.sessions, &a.st.Sessions[i])
			}
		}
		gs = append(gs, g)
	}
	other := group{host: h, project: proto.Project{ID: "", Name: locales.SidebarOtherProject()}}
	for i := range a.st.Sessions {
		if s := &a.st.Sessions[i]; !known[s.Project] && a.hostOf(s.ID) == h {
			other.sessions = append(other.sessions, s)
		}
	}
	if len(other.sessions) > 0 {
		gs = append(gs, other)
	}
	return gs
}

// collapsed reports whether a group's sessions are hidden in the sidebar.
func (a *App) collapsed(g group) bool { return a.prefs.Collapsed[g.key()] }

// visibleOrder returns the sessions in the sidebar's order, those of
// collapsed projects left out unless selected.
func (a *App) visibleOrder() []string {
	var ids []string
	for _, g := range a.groups() {
		for _, s := range g.sessions {
			if !a.collapsed(g) || s.ID == a.selected {
				ids = append(ids, s.ID)
			}
		}
	}
	return ids
}

func (a *App) selectSession(id string) {
	if a.session(id) == nil {
		return
	}
	changed := a.selected != id
	a.selected = id
	s := a.session(id)
	for _, p := range s.Panes {
		a.ensureTerm(p.ID)
	}
	if pane := a.focusOf(s); pane != "" {
		a.touch(pane)
	}
	a.focusTerminal()
	a.reportView()
	a.updateTitle()
	if changed {
		a.savePrefs()
	}
}

// reportView tells each host's kerod which of its sessions the user looks
// at, which it then never marks unread.
func (a *App) reportView() {
	shown := a.selectedHost()
	for _, h := range a.hosts {
		if h.cl == nil {
			continue
		}
		id := ""
		if a.active && a.focused && h == shown {
			id = a.selected
		}
		if h.viewSent != nil && *h.viewSent == id {
			continue
		}
		h.viewSent = &id
		h.cl.Go("view", proto.ViewParams{ID: id}, nil)
	}
}

// touch moves a terminal to the front of those kept attached, dropping
// the one shown longest ago past the limit.
func (a *App) touch(id string) {
	a.lru = slices.DeleteFunc(a.lru, func(x string) bool { return x == id })
	a.lru = append(a.lru, id)
	for len(a.lru) > maxTerms {
		a.dropTerm(a.lru[0])
	}
}

func (a *App) dropTerm(id string) {
	if e := a.terms[id]; e != nil {
		if e.term != nil {
			e.term.Close()
		}
		if e.stream != nil {
			e.stream.Close()
		}
		delete(a.terms, id)
	}
	if a.find.pane == id {
		a.find.pane = ""
	}
	a.lru = slices.DeleteFunc(a.lru, func(x string) bool { return x == id })
}

// gated holds back the stream's frames until the terminal takes the size
// of the first, which then shows the session as it is.
type gated struct {
	*client.Stream
	ready chan struct{}
}

func (g *gated) Read(p []byte) (int, error) {
	<-g.ready
	return g.Stream.Read(p)
}

// ensureTerm attaches a terminal to a session, unless one is.
func (a *App) ensureTerm(id string) {
	h := a.hostOf(id)
	if a.terms[id] != nil || h.conn != connReady || a.isBrowser(id) {
		return
	}
	e := &termEntry{started: time.Now()}
	a.terms[id] = e
	dialer := h.dialer()
	go func() {
		stream, err := client.AttachVia(dialer, id)
		if err != nil {
			a.update(func() {
				if a.terms[id] == e {
					e.err = err.Error()
				}
			})
			return
		}
		g := &gated{Stream: stream, ready: make(chan struct{})}
		o := a.termOptions(id, g)
		// The terminal shows kerod's frames: kerod's terminal is the
		// session's, ours shows what it shows, cell for cell, and lays out
		// nothing of the program's own. It takes the sizes kerod's does,
		// between the frames of one size and the next.
		o.ResizeByConn = true
		term, err := terminal.New(o)
		if err != nil {
			stream.Close()
			a.update(func() {
				if a.terms[id] == e {
					e.err = err.Error()
				}
			})
			return
		}
		term.Resize(stream.Welcome.Cols, stream.Welcome.Rows)
		stream.OnResized = term.Resize
		close(g.ready)
		a.update(func() {
			if a.terms[id] != e {
				term.Close()
				stream.Close()
				return
			}
			e.term, e.stream = term, stream
			if a.selected == id {
				a.focusTerminal()
			}
		})
	}()
}

func (a *App) termFont() terminal.Font {
	f := terminal.Font{Family: a.termFamily(), Size: a.set.FontSize, Weight: a.set.FontWeight,
		LineHeight: a.set.LineHeight, Thicken: a.set.Thicken}
	if !a.set.Ligatures {
		f.Features = []string{"-calt", "-liga", "-dlig"}
	}
	return f
}

// termThemes returns the terminal's colors in light and dark windows:
// kero's, on the card's color, or a Ghostty theme of the user's choice.
func (a *App) termThemes() (light, dark *terminal.Theme) {
	pick := func(name string, def *terminal.Theme) *terminal.Theme {
		if name == "" || name == "kero" {
			return def
		}
		if t, err := terminal.GhosttyTheme(name); err == nil {
			return t
		}
		return def
	}
	return pick(a.set.LightTheme, lightTermTheme), pick(a.set.DarkTheme, darkTermTheme)
}

func (a *App) termOptions(id string, conn *gated) terminal.Options {
	light, dark := a.termThemes()
	o := terminal.Options{
		Conn:          conn,
		Font:          a.termFont(),
		Theme:         light,
		DarkTheme:     dark,
		Cursor:        map[string]terminal.CursorStyle{"block": terminal.CursorBlock, "bar": terminal.CursorBar, "underline": terminal.CursorUnderline}[a.set.Cursor],
		NoBlink:       !a.set.CursorBlink,
		OptionAsAlt:   a.set.OptionAsAlt,
		ClipboardRead: map[string]terminal.ClipboardAccess{"ask": terminal.ClipboardAsk, "allow": terminal.ClipboardAllow, "deny": terminal.ClipboardDeny}[a.set.Clipboard],
		RightClick:    map[string]terminal.RightClickAction{"menu": terminal.RightClickContextMenu, "paste": terminal.RightClickPaste, "copyOrPaste": terminal.RightClickCopyOrPaste}[a.set.RightClick],
		// The pane's card shows under it, dimmed when the user is in
		// another pane.
		Transparent: true,
		// Text lines up with the pane's title; a full-screen program's
		// colors reach the card's edges.
		Padding:      terminal.Padding{X: 16, Y: 6},
		PaddingColor: terminal.PaddingExtend,
		// Text a program colored for the other appearance, as a dark
		// theme's light grays on a light one, stays legible.
		MinimumContrast: a.set.MinContrast,
		// Every terminal zooms together, and the size is remembered.
		OnZoom: func(z terminal.Zoom) bool {
			a.zoom(z.Steps, z.Reset)
			return true
		},
		// ⌘K and the context menu's Clear clear kerod's terminal, the
		// session's: cleared here alone, kerod's next frames, drawn from a
		// screen still full, would put rows back wrong.
		OnClear: func(terminal.Clear) bool {
			conn.Clear(proto.ClearScreen)
			return true
		},
		OpenLink: func(link string) bool { return a.openLink(id, link) },
		// A selection copied as it ends shows nothing else: say so.
		OnCopy: func(_ string, by terminal.CopySource) {
			if by == terminal.CopySelect {
				a.toast(locales.ToastCopiedToClipboard())
				if a.win != nil {
					a.win.Invalidate()
				}
			}
		},
	}
	if a.set.CopyOnSelect {
		o.CopyOnSelect = terminal.CopyOnSelectClipboard
	}
	// Files and images pasted into a pane of another machine go there; a
	// local pane's paste reads only what it takes, as it did.
	if a.hostOf(id).remote() {
		o.OnPaste = func(d transfer.Data) bool { return a.remotePaste(id, d) }
	}
	return o
}

// zoom makes every terminal's text bigger or smaller, which Settings
// remembers as the font's size.
func (a *App) zoom(steps int, reset bool) {
	s := a.set
	s.FontSize = min(max(s.FontSize+float32(steps), 8), 36)
	if reset {
		s.FontSize = settings.Default().FontSize
	}
	if s.FontSize != a.set.FontSize {
		a.applySettings(s)
	}
}

// applySettings makes settings the app's, saving them: the terminals take
// what changed at once, and are attached again for what only a new
// terminal takes.
func (a *App) applySettings(s settings.Settings) { a.apply(s, true) }

// apply makes settings the app's, saving them to the configuration when
// they come from the app rather than from the file.
func (a *App) apply(s settings.Settings, save bool) {
	old := a.applied
	a.set, a.applied = s, s.Clone()
	if save {
		if err := settings.Save(s); err != nil {
			a.toast(locales.ToastSaveSettingsFailed(err.Error()))
		}
	}
	font := old.FontFamily != s.FontFamily || old.FontSize != s.FontSize || old.FontWeight != s.FontWeight ||
		old.LineHeight != s.LineHeight || old.Ligatures != s.Ligatures || old.Thicken != s.Thicken
	themes := old.LightTheme != s.LightTheme || old.DarkTheme != s.DarkTheme
	anew := old.Cursor != s.Cursor || old.CursorBlink != s.CursorBlink || old.OptionAsAlt != s.OptionAsAlt ||
		old.Clipboard != s.Clipboard || old.RightClick != s.RightClick
	light, dark := a.termThemes()
	for id, e := range a.terms {
		if e.term == nil {
			continue
		}
		if anew {
			a.dropTerm(id) // attached again as it shows
			continue
		}
		if font {
			e.term.SetFont(a.termFont())
		}
		if themes {
			e.term.SetTheme(light, dark)
		}
		if old.MinContrast != s.MinContrast {
			e.term.SetMinimumContrast(s.MinContrast)
		}
		if old.CopyOnSelect != s.CopyOnSelect {
			mode := terminal.CopyOnSelectNone
			if s.CopyOnSelect {
				mode = terminal.CopyOnSelectClipboard
			}
			e.term.SetCopyOnSelect(mode)
		}
	}
	if old.Appearance != s.Appearance && a.win != nil {
		// Only in the running app: before it runs, the call waits for it.
		mygo.Theme.SetSource(mygo.ThemeSource(s.Appearance))
	}
	if old.Language != s.Language && a.win != nil {
		mygo.App.SetLocale(localeTag(s.Language))
	}
	if old.Vibrancy != s.Vibrancy && a.win != nil {
		a.win.SetVibrancy(vibrancyFor(s))
	}
	if !maps.Equal(old.Shortcuts, s.Shortcuts) && a.win != nil {
		mygo.App.SetMenu(a.menu())
	}
	if old.DockBadge != s.DockBadge {
		a.notify(true)
	}
	if !slices.Equal(old.Hosts, s.Hosts) && a.win != nil {
		a.syncHosts()
	}
	if a.win != nil {
		a.win.Invalidate()
	}
	if a.setWin != nil {
		a.setWin.Invalidate()
	}
}

// watchConfig applies the configuration as the user saves it in an
// editor, and tells what it got wrong. The system hints at changes in the
// file's directory (FSEvents on macOS), where an editor's save, which
// replaces the file, shows too: a hint is all it takes, as Load reads the
// file again only when its modification time changed, so the watch keeps
// no snapshot and stats nothing. The app's own saves come back as changes
// already applied, which change nothing.
func (a *App) watchConfig() {
	dir := filepath.Dir(settings.Path())
	for {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return
		}
		w, err := mygo.WatchFiles(context.Background(), dir, mygo.FileWatchOptions{HintsOnly: true})
		if err != nil {
			return
		}
		for {
			if _, err := w.Next(context.Background()); err != nil {
				break // the directory went: watch it again, made anew
			}
			a.reloadConfig()
		}
		w.Close()
	}
}

// reloadConfig applies the configuration as the file now has it.
func (a *App) reloadConfig() {
	cur := settings.Load()
	problems := settings.Problems()
	a.update(func() {
		changed := strings.Join(problems, "\n") != strings.Join(a.ss.problems, "\n")
		a.ss.problems = problems
		if !reflect.DeepEqual(cur, a.applied) {
			a.apply(cur, false)
		}
		if changed && len(problems) > 0 {
			a.toast(locales.ToastConfigProblems(len(problems)))
		}
		if a.setWin != nil {
			a.setWin.Invalidate()
		}
	})
}

func vibrancyFor(s settings.Settings) mygo.Vibrancy {
	if s.Vibrancy {
		return mygo.VibrancySidebar
	}
	return mygo.VibrancyNone
}

var lineSuffix = regexp.MustCompile(`(:\d+){1,2}$`)

// openLink opens what a Command+click opens: URLs with the system, and
// file paths printed in the session, relative to its directory, in the
// app that opens them.
func (a *App) openLink(id, link string) bool {
	if h := a.hostOf(id); h.remote() {
		// A link another machine's program printed opens here only as a
		// web page; a file:// one, and any path, are the host's; any other,
		// as of an app of this machine, does not open.
		if u, err := url.Parse(link); err == nil && strings.Contains(link, "://") {
			switch strings.ToLower(u.Scheme) {
			case "http", "https":
				return false
			case "file":
				a.openRemotePath(h, id, u.Path)
			default:
				a.toast(locales.HostLinkRefused(h.name, u.Scheme))
			}
			return true
		}
		// A path of another machine is never a file of this one.
		a.openRemotePath(h, id, link)
		return true
	}
	if strings.Contains(link, "://") {
		return false
	}
	path := a.resolvePath(id, link)
	if path == "" {
		return false
	}
	openPath(path)
	return true
}

// resolvePath returns the file a path printed in a pane names, relative to
// the directory of the program that printed it, or "" for no such file.
// id is a pane's, or a session's for its pane in front.
func (a *App) resolvePath(id, link string) string {
	path := lineSuffix.ReplaceAllString(link, "")
	if strings.HasPrefix(path, "~/") || runtime.GOOS == "windows" && strings.HasPrefix(path, `~`) {
		path = filepath.Join(proto.Home(), path[2:])
	}
	if !filepath.IsAbs(path) {
		if dir := a.workDir(id); dir != "" {
			path = filepath.Join(dir, path)
		}
	}
	if _, err := os.Stat(path); err != nil {
		return ""
	}
	return path
}

// workDir returns the working directory of the pane, or of the session's
// pane in front, by id.
func (a *App) workDir(id string) string {
	for i := range a.st.Sessions {
		if p := a.st.Sessions[i].PaneByID(id); p != nil {
			return p.WorkDir()
		}
	}
	if s := a.session(id); s != nil {
		return s.WorkDir()
	}
	return ""
}

// --- actions ---

// call calls a method of the kerod that has id: a session's, a pane's or
// a project's, toasting a failure unless done takes it.
func (a *App) call(id, method string, params any, done func(err error)) {
	a.callOn(a.hostOf(id), method, params, done)
}

// callOn calls a method of a host's kerod.
func (a *App) callOn(h *host, method string, params any, done func(err error)) {
	if h.cl == nil {
		// What the app showed at once comes back as the host does: say so.
		err := errors.New(locales.HostNotConnected(h.label()))
		if done != nil {
			done(err)
		} else {
			a.toast(err.Error())
		}
		return
	}
	h.cl.Go(method, params, func(err error) {
		if done != nil || err != nil {
			a.update(func() {
				if done != nil {
					done(err)
				} else {
					a.toast(err.Error())
				}
			})
		}
	})
}

func (a *App) toast(msg string) { a.pendingToast = msg }

// newSession starts a session in a project: in the directory of the
// session shown when it is the project's, as a terminal's new tab does,
// else the project's. With no project, it is the shown session's host's.
func (a *App) newSession(projectID string) {
	h := a.selectedHost()
	if projectID != "" {
		h = a.hostOf(projectID)
	}
	a.newSessionOn(h, projectID)
}

// newSessionOn starts a session on a host, in a project of its, "" for
// the one of the session shown there, else the first.
func (a *App) newSessionOn(h *host, projectID string) {
	if h.cl == nil {
		return
	}
	p := proto.CreateParams{Project: projectID}
	if cur := a.session(a.selected); cur != nil && a.hostOf(cur.ID) == h {
		if projectID == "" || cur.Project == projectID {
			p.Project, p.After = cur.Project, cur.ID
			if a.set.NewSessionDir == "current" {
				p.Dir = cur.FocusPane().WorkDir()
			}
		}
		p.Cols, p.Rows = cur.Cols, cur.Rows
	}
	home := proto.Home()
	if h.remote() {
		home = "~" // the host's, as kerod there takes it
	}
	if a.set.NewSessionDir == "home" {
		p.Dir = home
	}
	if p.Project == "" && len(a.projectsOf(h)) == 0 {
		p.Dir = home
	}
	a.create(h, p, "")
}

// create starts a session on a host, and shows it, opening the project
// expand in the sidebar.
func (a *App) create(h *host, p proto.CreateParams, expand string) {
	cl := h.cl
	if cl == nil {
		return
	}
	go func() {
		var s proto.Session
		err := cl.Call("create", p, &s)
		a.update(func() {
			if err != nil {
				a.toast(err.Error())
				return
			}
			if expand != "" {
				delete(a.prefs.Collapsed, expand)
			}
			// The state with it may come after the answer.
			a.addPending(h, s)
			a.selectSession(s.ID)
		})
	}()
}

// addPending puts a session just created into the state until its host's
// comes with it.
func (a *App) addPending(h *host, s proto.Session) {
	if a.session(s.ID) != nil {
		return
	}
	a.own(h, s)
	a.st.Sessions = append(a.st.Sessions, s)
	if a.project(s.Project) == nil {
		a.st.Projects = append(a.st.Projects, proto.Project{ID: s.Project, Name: path.Base(filepath.ToSlash(s.Dir)), Dir: s.Dir})
	}
}

// openProject asks for a folder, and starts a session there, in its
// project: of this machine, with the system's dialog, else, with hosts,
// of any machine, with the app's picker, from the shown session's.
func (a *App) openProject() {
	// With hosts, the app's picker, which goes to any machine, this one
	// too, as the sidebar has no host of its own to start on.
	if h := a.selectedHost(); h.remote() || len(a.hosts) > 1 {
		a.openProjectOn(h)
		return
	}
	h := a.local()
	if h.cl == nil {
		return
	}
	win := a.win
	go func() {
		paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{
			Parent: win, Title: locales.OpenProjectTitle(), Directory: true, ButtonLabel: locales.CommonOpen(),
			Message: locales.OpenProjectMessage(),
		})
		if err != nil || len(paths) == 0 {
			return
		}
		a.update(func() { a.openProjectAt(h, paths[0]) })
	}()
}

// openProjectAt starts a session in a folder of a host, in its project.
func (a *App) openProjectAt(h *host, dir string) {
	cl := h.cl
	if cl == nil {
		return
	}
	go func() {
		var p proto.Project
		if err := cl.Call("project.create", proto.ProjectParams{Dir: dir}, &p); err != nil {
			a.update(func() { a.toast(err.Error()) })
			return
		}
		a.update(func() {
			a.create(h, proto.CreateParams{Project: p.ID, Dir: dir}, p.ID)
		})
	}()
}

// busy reports whether closing a session would end a program the user may
// care about: anything but the shell at its prompt.
func busy(s *proto.Session) bool {
	return s.Status != proto.Exited && s.Process != ""
}

func (a *App) closeSession(id string, ask bool) {
	s := a.session(id)
	if s == nil {
		return
	}
	if ask && a.set.ConfirmClose && busy(s) {
		name := s.DisplayName(a.set.SessionName)
		a.confirm = &confirmation{
			open:    true,
			title:   locales.ConfirmCloseTitle(name),
			detail:  locales.ConfirmCloseSessionDetail(s.Process),
			action:  locales.ActionCloseSession(),
			destroy: true,
			run:     func() { a.closeSession(id, false) },
		}
		return
	}
	h := a.hostOf(id)
	if id == a.selected {
		// The next session takes its place, else the one before.
		ids := a.visibleOrder()
		i := slices.Index(ids, id)
		next := ""
		if i >= 0 && i+1 < len(ids) {
			next = ids[i+1]
		} else if i > 0 {
			next = ids[i-1]
		}
		a.selected = next
		if next != "" {
			a.selectSession(next)
		}
	}
	for _, p := range s.Panes {
		a.dropTerm(p.ID)
	}
	a.st.Sessions = slices.DeleteFunc(a.st.Sessions, func(x proto.Session) bool { return x.ID == id })
	a.callOn(h, "close", proto.IDParams{ID: id}, nil)
}

func (a *App) restartSession(id string) {
	a.call(id, "restart", proto.IDParams{ID: id}, nil)
}

func (a *App) startRename(id string) {
	s := a.session(id)
	if s == nil {
		return
	}
	a.renaming, a.renamingProject, a.renameBuf, a.renameFrames = id, "", s.DisplayName(a.set.SessionName), 0
}

func (a *App) commitRename() {
	id, name := a.renaming, strings.TrimSpace(a.renameBuf)
	a.renaming = ""
	s := a.session(id)
	if s == nil || name == s.DisplayName(a.set.SessionName) {
		a.focusTerminal()
		return
	}
	s.Name = name // at once; the daemon's state follows
	a.call(id, "rename", proto.RenameParams{ID: id, Name: name}, nil)
	a.focusTerminal()
	a.updateTitle()
}

func (a *App) startProjectRename(id string) {
	for _, p := range a.st.Projects {
		if p.ID == id {
			a.renaming, a.renamingProject, a.renameBuf, a.renameFrames = "", id, p.Name, 0
		}
	}
}

func (a *App) commitProjectRename() {
	id, name := a.renamingProject, strings.TrimSpace(a.renameBuf)
	a.renamingProject = ""
	for i := range a.st.Projects {
		if p := &a.st.Projects[i]; p.ID == id && name != "" && name != p.Name {
			p.Name = name // at once; the daemon's state follows
			a.call(id, "project.rename", proto.ProjectParams{ID: id, Name: name}, nil)
		}
	}
	a.focusTerminal()
}

func (a *App) moveSession(id, project string) {
	if s := a.session(id); s != nil {
		s.Project = project
	}
	a.call(id, "move", proto.MoveParams{ID: id, Project: project, Index: -1}, nil)
}

func (a *App) selectOffset(d int) {
	ids := a.visibleOrder()
	if len(ids) == 0 {
		return
	}
	i := slices.Index(ids, a.selected)
	if i < 0 {
		i = 0
	} else {
		i = (i + d + len(ids)) % len(ids)
	}
	a.selectSession(ids[i])
}

// jumpTo goes to the next session that want takes, after the one shown,
// in the sidebar's order, opening its project, and reports whether there
// was one.
func (a *App) jumpTo(want func(*proto.Session) bool) bool {
	var ids []string
	for _, g := range a.groups() {
		for _, s := range g.sessions {
			ids = append(ids, s.ID)
		}
	}
	i := slices.Index(ids, a.selected)
	for k := 1; k <= len(ids); k++ {
		id := ids[(i+k+len(ids))%len(ids)]
		if s := a.session(id); s != nil && id != a.selected && want(s) {
			delete(a.prefs.Collapsed, s.Project)
			a.selectSession(id)
			return true
		}
	}
	return false
}

// jumpToAttention goes to the next session that needs the user, after the
// one shown, else to the next with something unseen.
func (a *App) jumpToAttention() {
	if a.jumpTo(func(s *proto.Session) bool { return s.Status == proto.Waiting }) ||
		a.jumpTo(func(s *proto.Session) bool { return s.Unread }) {
		return
	}
	a.toast(locales.ToastNothingNeedsYou())
}

func (a *App) toggleSidebar() {
	a.prefs.SidebarHidden = !a.prefs.SidebarHidden
	a.savePrefs()
}

func (a *App) toggleProject(id string) {
	a.prefs.Collapsed[id] = !a.prefs.Collapsed[id]
	if !a.prefs.Collapsed[id] {
		delete(a.prefs.Collapsed, id)
	}
	a.savePrefs()
}

// quitAndEnd ends every session of this machine, and its kerod, then
// quits: other machines' keep running.
func (a *App) quitAndEnd() {
	n := len(a.sessionsOf(a.local()))
	a.confirm = &confirmation{
		open:    true,
		title:   locales.ConfirmQuitAllTitle(),
		detail:  quitAllDetail(n, len(a.hosts) > 1),
		action:  locales.ConfirmQuitAllAction(),
		destroy: true,
		run: func() {
			cl := a.local().cl
			go func() {
				if cl != nil {
					cl.Call("shutdown", nil, nil)
				}
				mygo.App.Quit()
			}()
		},
	}
}

// daemonStale reports whether kerod runs another version of Kero than
// this one, as after an update: it speaks the protocol, but runs the code
// of before until it restarts.
func (a *App) daemonStale() bool { return a.local().stale() }

// offerRestart restarts kerod into this version of Kero, asking first
// while programs run in sessions, as the restart ends them.
func (a *App) offerRestart() {
	h := a.local()
	n := a.busyCount(h)
	if n == 0 {
		a.restartDaemon()
		return
	}
	was := locales.RestartEarlierVersion()
	if h.daemonApp != "" {
		was = h.daemonApp
	}
	a.confirm = &confirmation{
		open:    true,
		title:   locales.ConfirmRestartServiceTitle(),
		detail:  locales.RestartStaleDetail(was, mygo.App.Version(), locales.RestartRunning(n)),
		action:  locales.CommonRestartService(),
		destroy: true,
		run:     a.restartDaemon,
	}
}

// busyCount counts a host's sessions whose programs a restart of its
// kerod would end.
func (a *App) busyCount(h *host) int {
	n := 0
	for _, s := range a.sessionsOf(h) {
		if busy(&s) {
			n++
		}
	}
	return n
}

// restartDaemon restarts this machine's kerod, as when it is of another
// version: its sessions start again where they were, with their
// scrollback.
func (a *App) restartDaemon() {
	h := a.local()
	h.conn = connConnecting
	go func() {
		err := stopDaemon()
		a.update(func() {
			if err != nil {
				h.conn, h.err = connFailed, err.Error()
				return
			}
			a.connect()
		})
	}()
}

// quitAllDetail says what Quit and End All ends: this machine's sessions,
// as other machines' keep running.
func quitAllDetail(n int, hosts bool) string {
	d := locales.ConfirmQuitAllDetail(n)
	if hosts {
		d += " " + locales.ConfirmQuitAllHosts()
	}
	return d
}
