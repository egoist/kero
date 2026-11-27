package main

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/actions"
	"kero/internal/proto"
)

func TestQuickTerminalMenuAvailability(t *testing.T) {
	a := testApp(t)
	// Window identities alone: no native windows are opened by these tests.
	a.quick.win = &mygo.Window{}
	main, settings := &mygo.Window{}, &mygo.Window{}
	allowed := map[string]bool{
		quickAction: true, "settings.open": true,
		"pane.close": true, "session.close": true,
		"text.bigger": true, "text.smaller": true, "text.reset": true,
		"theme.toggle": true,
	}
	var items []*mygo.MenuItem
	for _, act := range actions.All {
		items = append(items, a.item(act.ID))
	}
	m := mygo.NewMenu(items)
	for _, shown := range []bool{true, false} {
		a.quick.shown = shown
		for _, win := range []*mygo.Window{a.quick.win, main, settings, nil} {
			a.menuWindow(m, win)
			for _, act := range actions.All {
				want := win != a.quick.win || allowed[act.ID]
				if got := a.menuActionAllowed(act.ID, win); got != want {
					t.Errorf("shown=%t, quick source=%t, %s allowed=%t, want %t", shown, win == a.quick.win, act.ID, got, want)
				}
				it := m.ItemByID(act.ID)
				if it == nil || it.IsEnabled() != want {
					t.Errorf("shown=%t, quick source=%t: wrong menu availability for %s", shown, win == a.quick.win, act.ID)
				}
				if it != nil && it.Accelerator != a.accelerator(act) {
					t.Errorf("%s lost its shortcut", act.ID)
				}
			}
		}
	}
	if a.menuActionAllowed("future.mainWindowAction", a.quick.win) {
		t.Error("an unsupported new action was allowed in the quick terminal")
	}
	a.quick.win = nil
	if !a.menuActionAllowed("pane.split.right", nil) {
		t.Error("no source window was mistaken for an uncreated quick terminal")
	}
}

func TestQuickTerminalMenuDoesNotChangeMainWindow(t *testing.T) {
	a := testApp(t)
	a.quick.win = &mygo.Window{}
	before, _ := json.Marshal(a.st)
	// Close on an already hidden panel must stay there, rather than close
	// a pane in the main window. Other callbacks can arrive after blur too.
	for _, id := range []string{
		"pane.split.right", "pane.split.down", "session.new", "session.newHome",
		"session.newWorktree", "project.open", "pane.browser", "browser.address",
		"pane.restart", "pane.zoom", "pane.next", "pane.previous", "pane.right",
		"session.rename", "session.next", "palette.open", "conversation.resume",
		"sidebar.toggle", "files.toggle", "find.open", "pane.close", "session.close",
	} {
		a.runMenuAction(id, a.quick.win)
	}
	after, _ := json.Marshal(a.st)
	if string(after) != string(before) || a.selected != "s1" || a.keyPane != "" || a.confirm != nil || a.prefs.SidebarHidden {
		t.Fatal("quick terminal menu actions changed the main window")
	}
	// The source, not whether the panel is shown, determines availability.
	a.quick.shown = true
	a.runMenuAction("sidebar.toggle", &mygo.Window{})
	if !a.prefs.SidebarHidden {
		t.Fatal("a main-window action was blocked by the visible quick terminal")
	}
}

func TestQuickTerminalDoesNotBlockMainOrRemoteSplit(t *testing.T) {
	for _, remote := range []bool{false, true} {
		t.Run(map[bool]string{false: "main menu", true: "kero do"}[remote], func(t *testing.T) {
			a := testApp(t)
			a.quick.win, a.quick.shown = &mygo.Window{}, true
			a.set.RemoteControl = true
			calls := make(chan proto.CreateParams, 4)
			cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
				if method == "split" {
					var p proto.CreateParams
					if err := json.Unmarshal(raw, &p); err != nil {
						return nil, err
					}
					calls <- p
				}
				return nil, errors.New("test daemon rejected " + method)
			})
			defer stop()
			a.local().cl = cl
			for _, id := range []string{"pane.split.right", "pane.split.down"} {
				a.runMenuAction(id, a.quick.win)
			}
			if remote {
				a.event(a.local(), cl, proto.Message{Event: "action", Action: "pane.split.down"})
			} else {
				a.runMenuAction("pane.split.down", &mygo.Window{})
			}
			select {
			case p := <-calls:
				if p.Split != "a" || p.Direction != "down" {
					t.Fatalf("wrong split target: %+v", p)
				}
			case <-time.After(time.Second):
				t.Fatal("main/remote split was blocked")
			}
			select {
			case p := <-calls:
				t.Fatalf("quick terminal sent an extra split: %+v", p)
			case <-time.After(100 * time.Millisecond):
			}
		})
	}
}

// A disabled menu can leave its shortcut to the terminal. The panel must
// consume it before the shell, also after a rebind or a hide/show cycle.
func TestQuickTerminalUnavailableShortcutsDoNotReachShell(t *testing.T) {
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	sink := newSink()
	term, err := terminal.New(terminal.Options{Conn: sink})
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	a.quick.e = &termEntry{term: term}
	a.quick.ref.Focus()
	tt := ui.NewTester(a.quickView, 640, 300)
	tt.Frame()
	for _, act := range actions.All {
		if quickActionAllowed(act.ID) {
			continue
		}
		mods, key := shortcutKey(a.accelerator(act))
		if key != ui.KeyUnknown {
			tt.Key(mods, key)
			tt.Frame()
		}
	}
	if got := sink.quiet(); got != "" {
		t.Fatalf("unavailable default shortcuts reached the shell: %q", got)
	}

	a.set.Shortcuts = map[string]string{"pane.split.right": "Ctrl+D", "session.new": "F2"}
	tt.Frame()
	for range 2 {
		tt.Key(ui.Ctrl, ui.KeyD)
		tt.Key(0, ui.KeyF2)
		tt.Frame()
		tt.SetFocused(false)
		a.quick.e = nil
		tt.Frame()
		a.quick.e = &termEntry{term: term}
		a.quick.ref.Focus()
		tt.SetFocused(true)
		tt.Frame()
	}
	if got := sink.quiet(); got != "" {
		t.Fatalf("custom shortcuts reached the shell: %q", got)
	}
	// Text and unbound shell control keys still work.
	tt.Type("hello")
	tt.Key(ui.Ctrl, ui.KeyC)
	tt.Frame()
	if got := sink.quiet(); got != "hello\x03" {
		t.Fatalf("ordinary input = %q, want hello followed by Ctrl+C", got)
	}
	sink.mu.Lock()
	sink.got = nil
	sink.mu.Unlock()
	// Removing the binding gives Ctrl+D back to the shell.
	a.set.Shortcuts["pane.split.right"] = ""
	tt.Frame()
	tt.Key(ui.Ctrl, ui.KeyD)
	tt.Frame()
	if got := sink.written(t); got != "\x04" {
		t.Fatalf("unbound Ctrl+D = %q, want EOF", got)
	}
}

func TestShortcutKey(t *testing.T) {
	for _, tc := range []struct {
		keys string
		mods ui.Modifiers
		key  ui.Key
	}{
		{"CmdOrCtrl+Shift+D", ui.Cmd | ui.Shift, ui.KeyD},
		{"Ctrl+Alt+Left", ui.Ctrl | ui.Alt, ui.KeyLeft},
		{"F2", 0, ui.KeyF2},
		{"Ctrl++", ui.Ctrl | ui.Shift, ui.KeyEqual},
		{"Ctrl+Plus", ui.Ctrl | ui.Shift, ui.KeyEqual},
		{"CmdOrCtrl+Return", ui.Cmd, ui.KeyEnter},
		{"Ctrl+Esc", ui.Ctrl, ui.KeyEscape},
		{"", 0, ui.KeyUnknown},
		{"Ctrl+NotAKey", 0, ui.KeyUnknown},
		{"NotAMod+D", 0, ui.KeyUnknown},
	} {
		mods, key := shortcutKey(tc.keys)
		if mods != tc.mods || key != tc.key {
			t.Errorf("shortcutKey(%q) = %v/%v, want %v/%v", tc.keys, mods, key, tc.mods, tc.key)
		}
	}
}
