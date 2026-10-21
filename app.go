package main

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"os"
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

	cl        *client.Client
	conn      connState
	connErr   string
	daemonApp string // the version of Kero that kerod runs
	retries   int
	st        proto.State
	loaded    bool // a state came

	prefs       prefs
	set         settings.Settings // the user's settings: Settings' controls edit it
	applied     settings.Settings // set, as last applied and saved
	setWin      *mygo.Window      // the Settings window, while open
	ss          settingsState
	selected    string
	terms       map[string]*termEntry
	lru         []string
	refs        map[string]*ui.Handle // panes' terminals, and splits, by id
	focus       map[string]string     // the pane the user is in, by session
	layoutDirty string                // a session whose divider is dragged
	viewSent    *string

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
	a := &App{terms: map[string]*termEntry{}, statuses: map[string]proto.Status{}, active: true, focused: true,
		refs: map[string]*ui.Handle{}, focus: map[string]string{}, arrived: map[string]bool{}}
	a.loadPrefs()
	a.set = settings.Load()
	a.ss.problems = settings.Problems()
	a.applied = a.set.Clone()
	a.selected = a.prefs.Selected
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

// connect connects to kerod, starting it, and follows its state.
func (a *App) connect() {
	go func() {
		cl, err := client.Connect(false)
		a.update(func() {
			if err != nil {
				a.cl = nil
				if errors.Is(err, client.ErrVersion) {
					a.conn = connVersion
					return
				}
				a.conn, a.connErr = connFailed, err.Error()
				a.retries++
				if a.retries < 4 {
					// It may be starting, or restarting: try again.
					time.AfterFunc(time.Duration(a.retries)*400*time.Millisecond, func() { a.update(a.connect) })
				}
				return
			}
			a.cl, a.conn, a.connErr, a.retries = cl, connReady, "", 0
			a.daemonApp = cl.Welcome.App
			cl.OnEvent(func(m proto.Message) { a.update(func() { a.event(cl, m) }) })
			cl.Go("subscribe", nil, nil)
			a.viewSent = nil
			a.reportView()
			go func() {
				<-cl.Done()
				a.update(func() { a.disconnected(cl) })
			}()
		})
	}()
}

// disconnected follows kerod going away, as when it was restarted: the
// terminals attached to it are done, and the app connects again.
func (a *App) disconnected(cl *client.Client) {
	if a.cl != cl {
		return
	}
	a.cl = nil
	a.conn = connConnecting
	for id := range a.terms {
		a.dropTerm(id)
	}
	time.AfterFunc(300*time.Millisecond, func() { a.update(a.connect) })
}

func (a *App) event(cl *client.Client, m proto.Message) {
	if a.cl != cl {
		return
	}
	switch m.Event {
	case "state":
		if m.State != nil {
			a.setState(*m.State)
		}
	case "select":
		if !a.set.RemoteControl {
			return
		}
		a.selectSession(m.Select)
		if a.win != nil {
			a.win.Show()
			a.win.Focus()
			mygo.App.Focus()
		}
	case "action":
		if !a.set.RemoteControl {
			return
		}
		if act, ok := actions.Find(m.Action); ok && act.Remote {
			a.run(act.ID, m.Args)
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
		a.showNotification(n.Session, title, n.Body)
	}
}

func (a *App) setState(st proto.State) {
	first := !a.loaded
	a.st, a.loaded = st, true
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
	if a.session(a.selected) == nil {
		ids := a.visibleOrder()
		if len(ids) == 0 {
			a.selected = ""
		} else {
			a.selectSession(ids[0])
		}
	} else if first {
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
			title, body = locales.NotifyNeedsYouTitle(s.DisplayName(a.set.SessionName)), s.Message
			if body == "" {
				body = locales.NotifyWaitingBody()
			}
		case s.Status == proto.Failed && a.set.NotifyFailed:
			title, body = locales.NotifyFailedTitle(s.DisplayName(a.set.SessionName)), s.Message
			if body == "" {
				body = locales.NotifyFailedBody(s.PaneName())
			}
		case s.Status == proto.Idle && prev == proto.Working && s.Unread && a.set.NotifyDone && (s.Agent != "" || s.Message != ""):
			title, body = locales.NotifyDoneTitle(s.DisplayName(a.set.SessionName)), s.Message
			if body == "" {
				body = locales.NotifyDoneBody(s.Agent, proto.ShortDir(s.WorkDir()))
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
		if a.session(id) == nil {
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
		title = s.DisplayName(a.set.SessionName)
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
	project  proto.Project
	sessions []*proto.Session
}

func (a *App) groups() []group {
	var gs []group
	known := map[string]bool{}
	for _, p := range a.st.Projects {
		known[p.ID] = true
		g := group{project: p}
		for i := range a.st.Sessions {
			if a.st.Sessions[i].Project == p.ID {
				g.sessions = append(g.sessions, &a.st.Sessions[i])
			}
		}
		gs = append(gs, g)
	}
	other := group{project: proto.Project{ID: "", Name: locales.SidebarOtherProject()}}
	for i := range a.st.Sessions {
		if !known[a.st.Sessions[i].Project] {
			other.sessions = append(other.sessions, &a.st.Sessions[i])
		}
	}
	if len(other.sessions) > 0 {
		gs = append(gs, other)
	}
	return gs
}

// visibleOrder returns the sessions in the sidebar's order, those of
// collapsed projects left out unless selected.
func (a *App) visibleOrder() []string {
	var ids []string
	for _, g := range a.groups() {
		for _, s := range g.sessions {
			if !a.prefs.Collapsed[g.project.ID] || s.ID == a.selected {
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

// reportView tells kerod which session the user looks at, which it then
// never marks unread.
func (a *App) reportView() {
	if a.cl == nil {
		return
	}
	id := ""
	if a.active && a.focused {
		id = a.selected
	}
	if a.viewSent != nil && *a.viewSent == id {
		return
	}
	a.viewSent = &id
	a.cl.Go("view", proto.ViewParams{ID: id}, nil)
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
	if a.terms[id] != nil || a.conn != connReady {
		return
	}
	e := &termEntry{started: time.Now()}
	a.terms[id] = e
	go func() {
		stream, err := client.Attach(id)
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
		// An image alone on the clipboard pastes as the path of a file
		// with it, which agents take as an image they attach.
		OnPaste: func(d transfer.Data) bool { return a.pasteImage(id, d) },
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

func (a *App) call(method string, params any, done func(err error)) {
	if a.cl == nil {
		return
	}
	a.cl.Go(method, params, func(err error) {
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
// else the project's.
func (a *App) newSession(projectID string) {
	if a.cl == nil {
		return
	}
	p := proto.CreateParams{Project: projectID}
	if cur := a.session(a.selected); cur != nil {
		if projectID == "" || cur.Project == projectID {
			p.Project, p.After = cur.Project, cur.ID
			if a.set.NewSessionDir == "current" {
				p.Dir = cur.FocusPane().WorkDir()
			}
		}
		p.Cols, p.Rows = cur.Cols, cur.Rows
	}
	if a.set.NewSessionDir == "home" {
		p.Dir = proto.Home()
	}
	if p.Project == "" && len(a.st.Projects) == 0 {
		p.Dir = proto.Home()
	}
	cl := a.cl
	go func() {
		var s proto.Session
		err := cl.Call("create", p, &s)
		a.update(func() {
			if err != nil {
				a.toast(err.Error())
				return
			}
			// The state with it may come after the answer.
			a.addPending(s)
			a.selectSession(s.ID)
		})
	}()
}

// addPending puts a session just created into the state until the
// daemon's comes with it.
func (a *App) addPending(s proto.Session) {
	if a.session(s.ID) != nil {
		return
	}
	a.st.Sessions = append(a.st.Sessions, s)
	if a.project(s.Project) == nil {
		a.st.Projects = append(a.st.Projects, proto.Project{ID: s.Project, Name: filepath.Base(s.Dir), Dir: s.Dir})
	}
}

// openProject asks for a folder, and starts a session there, in its
// project.
func (a *App) openProject() {
	if a.cl == nil {
		return
	}
	cl, win := a.cl, a.win
	go func() {
		paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{
			Parent: win, Title: locales.OpenProjectTitle(), Directory: true, ButtonLabel: locales.CommonOpen(),
			Message: locales.OpenProjectMessage(),
		})
		if err != nil || len(paths) == 0 {
			return
		}
		var p proto.Project
		if err := cl.Call("project.create", proto.ProjectParams{Dir: paths[0]}, &p); err != nil {
			a.update(func() { a.toast(err.Error()) })
			return
		}
		var s proto.Session
		err = cl.Call("create", proto.CreateParams{Project: p.ID, Dir: paths[0]}, &s)
		a.update(func() {
			if err != nil {
				a.toast(err.Error())
				return
			}
			delete(a.prefs.Collapsed, p.ID)
			a.addPending(s)
			a.selectSession(s.ID)
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
	a.call("close", proto.IDParams{ID: id}, nil)
}

func (a *App) restartSession(id string) {
	a.call("restart", proto.IDParams{ID: id}, nil)
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
	a.call("rename", proto.RenameParams{ID: id, Name: name}, nil)
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
			a.call("project.rename", proto.ProjectParams{ID: id, Name: name}, nil)
		}
	}
	a.focusTerminal()
}

func (a *App) moveSession(id, project string) {
	if s := a.session(id); s != nil {
		s.Project = project
	}
	a.call("move", proto.MoveParams{ID: id, Project: project, Index: -1}, nil)
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

// jumpToAttention goes to the next session that needs the user, after the
// one shown, else to the next with something unseen.
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

// quitAndEnd ends every session and kerod, then quits.
func (a *App) quitAndEnd() {
	n := len(a.st.Sessions)
	a.confirm = &confirmation{
		open:    true,
		title:   locales.ConfirmQuitAllTitle(),
		detail:  locales.ConfirmQuitAllDetail(n),
		action:  locales.ConfirmQuitAllAction(),
		destroy: true,
		run: func() {
			cl := a.cl
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
func (a *App) daemonStale() bool {
	return a.conn == connReady && a.daemonApp != mygo.App.Version()
}

// offerRestart restarts kerod into this version of Kero, asking first
// while programs run in sessions, as the restart ends them.
func (a *App) offerRestart() {
	n := 0
	for i := range a.st.Sessions {
		if busy(&a.st.Sessions[i]) {
			n++
		}
	}
	if n == 0 {
		a.restartDaemon()
		return
	}
	was := locales.RestartEarlierVersion()
	if a.daemonApp != "" {
		was = a.daemonApp
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

// restartDaemon restarts kerod, as when it is of another version: its
// sessions start again where they were, with their scrollback.
func (a *App) restartDaemon() {
	a.conn = connConnecting
	go func() {
		err := stopDaemon()
		a.update(func() {
			if err != nil {
				a.conn, a.connErr = connFailed, err.Error()
				return
			}
			a.connect()
		})
	}()
}
