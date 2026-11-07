package main

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
	"kero/internal/settings"
	"kero/internal/shell"
	"kero/locales"
)

func TestShellLauncher(t *testing.T) {
	a := testApp(t)
	a.set.Shell = "custom-shell"
	a.shells = []shell.Entry{{Name: "Another shell", Path: "another-shell"}}
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	if err := tt.Click(locales.ShellMenu()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !tt.HasText(locales.ShellOther()) || !tt.HasText("custom-shell · "+locales.ShellDefault()) {
		t.Fatalf("shell menu not shown: %q", tt.Texts())
	}
	shot(t, tt, "shell-launcher")
	if err := tt.Click(locales.ShellOther()); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if !a.pal.open || a.pal.only || a.pal.query != shellQueryPrefix+" " {
		t.Fatal("Other Shells did not open the regular command palette")
	}
	if _, ok := tt.AccessByRole(ui.RoleDialog, locales.PaletteLabel()); !ok {
		t.Fatalf("regular command palette not shown: %q", tt.Texts())
	}
	items := a.paletteItems()
	if len(items) != 2 || items[0].title != locales.ShellPaletteItem("custom-shell") {
		t.Fatalf("shell scope did not show the installed shells with the default first: %+v", items)
	}
	for _, item := range items {
		if !item.shell {
			t.Fatalf("shell scope included a regular command: %q", item.title)
		}
	}
	shot(t, tt, "shell-palette-initial")
	tt.Type("another")
	tt.Frame()
	if a.pal.query != shellQueryPrefix+" another" {
		t.Fatalf("typing replaced the shell filter: %q", a.pal.query)
	}
	if !tt.HasText(locales.ShellPaletteItem("Another shell")) || tt.HasText(locales.ShellPaletteItem("custom-shell")) {
		t.Fatal("command palette did not filter shell entries")
	}
	shot(t, tt, "shell-picker")
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Key(0, ui.KeyBackspace)
	tt.Frame()
	if a.pal.query != "" || len(a.paletteItems()) <= len(items) {
		t.Fatal("clearing shell: did not restore all commands")
	}
	tt.Type("toggle changes")
	tt.Frame()
	if !tt.HasText("Toggle Changes") {
		t.Fatal("Other Shells restricted the command palette to shells")
	}
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	tt.Frame()
	a.openPalette()
	tt.Frame()
	if a.pal.query != "" {
		t.Fatal("opening the regular palette kept the shell filter")
	}
}

func TestShellSelectionIsOneOff(t *testing.T) {
	a := testApp(t)
	a.set.Shell, a.set.ShellArgs = "default-shell", "-NoProfile"
	a.shells = []shell.Entry{{Name: "Another shell", Path: "another-shell"}}
	calls := make(chan proto.CreateParams, 1)
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		if method == "barrier" {
			return nil, nil
		}
		if method != "create" {
			return nil, errors.New("unexpected method " + method)
		}
		var p proto.CreateParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
		calls <- p
		return proto.Session{ID: "s2"}, nil
	})
	defer stop()
	a.openPalette()
	a.pal.query = "shell: another"
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	a.local().cl = cl
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	select {
	case p := <-calls:
		if p.Shell != "another-shell" || len(p.ShellArgs) != 0 || p.Dir != "/tmp" || p.Project != "p1" {
			t.Fatalf("wrong one-off shell request: %+v", p)
		}
	case <-time.After(time.Second):
		t.Fatal("no create request")
	}
	if err := cl.Call("barrier", nil, nil); err != nil {
		t.Fatal(err)
	}
	if a.set.Shell != "default-shell" || a.set.ShellArgs != "-NoProfile" {
		t.Fatal("one-off shell changed defaults")
	}
	a.st, a.selected = proto.State{}, ""
	a.set.ShellDir = t.TempDir()
	a.newSessionOn(a.local(), "")
	select {
	case p := <-calls:
		if p.Dir != a.set.ShellDir || p.Shell != "" {
			t.Fatalf("first session ignored the default startup settings: %+v", p)
		}
	case <-time.After(time.Second):
		t.Fatal("no first-session create request")
	}
	if err := cl.Call("barrier", nil, nil); err != nil {
		t.Fatal(err)
	}
}

func TestShellSettings(t *testing.T) {
	a := testApp(t)
	a.ss.page = "shell"
	a.shells = []shell.Entry{{Name: "Test shell", Path: "test-shell"}}
	tt := ui.NewTester(a.settingsView, 900, 1000)
	tt.Frame()
	if err := tt.Click(locales.ShellSystemDefault()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if err := tt.Click("Test shell"); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if a.set.Shell != "test-shell" || settings.Load().Shell != "test-shell" {
		t.Fatalf("shell not saved: %q", a.set.Shell)
	}
	clickRole := func(role ui.Role, name string) {
		t.Helper()
		info, ok := tt.AccessByRole(role, name)
		if !ok {
			t.Fatalf("no control %q with role %v", name, role)
		}
		b := info.Bounds
		tt.ClickAt(b.X+b.W/2, b.Y+b.H/2)
	}
	clickRole(ui.RoleTextField, locales.SetShellArgs())
	tt.Type(`-c "echo hi"`)
	tt.Key(0, ui.KeyEnter)
	for range 3 {
		tt.Frame()
	}
	if a.set.ShellArgs != `-c "echo hi"` || settings.Load().ShellArgs != a.set.ShellArgs {
		t.Fatalf("arguments not saved: %q, texts %q", a.set.ShellArgs, tt.Texts())
	}
	// Invalid quotes stay visible for correction, without overwriting saved args.
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Type(`-c "bad`)
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if a.ss.argsError == "" || a.set.ShellArgs != `-c "echo hi"` {
		t.Fatal("invalid arguments overwrote the valid setting")
	}
	if err := tt.Click(locales.ShellDirectoryInherit()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if err := tt.Click(locales.ShellDirectoryHome()); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if a.set.ShellDir != "~" || settings.Load().ShellDir != "~" {
		t.Fatalf("home selection lost: %q", a.set.ShellDir)
	}
	directoryButton, ok := tt.AccessByRole(ui.RolePopUpButton, locales.SetShellDirectory())
	if !ok || directoryButton.Bounds.W >= 220 {
		t.Fatalf("startup directory button was stretched: %+v", directoryButton)
	}
	if err := tt.Click(locales.ShellDirectoryHome()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if err := tt.Click(locales.ShellDirectoryCustom()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	path := filepath.Join(t.TempDir(), "custom")
	if err := tt.Click(locales.ShellDirectoryPath()); err != nil {
		t.Fatal(err)
	}
	tt.Type(path)
	for range 3 {
		tt.Frame()
	}
	if !strings.EqualFold(a.set.ShellDir, path) || settings.Load().ShellDir != a.set.ShellDir {
		t.Fatalf("custom directory lost: %q", a.set.ShellDir)
	}
	directoryButton, ok = tt.AccessByRole(ui.RolePopUpButton, locales.SetShellDirectory())
	pathInput, pathOK := tt.AccessByRole(ui.RoleTextField, locales.ShellDirectoryPath())
	if !ok || !pathOK || directoryButton.Bounds.W >= 220 || abs(pathInput.Bounds.W-220) > 1 {
		t.Fatalf("custom directory controls have incorrect widths: button %+v, input %+v", directoryButton, pathInput)
	}
	if abs(directoryButton.Bounds.X+directoryButton.Bounds.W-pathInput.Bounds.X-pathInput.Bounds.W) > 1 {
		t.Fatal("directory controls are not right-aligned")
	}
	shot(t, tt, "shell-settings")
	if err := tt.Click(locales.ShellResetProgram()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	tt.Frame()
	if a.set.Shell != "" || settings.Load().Shell != "" {
		t.Fatal("shell reset did not persist")
	}
	if err := tt.Click(locales.ShellSystemDefault()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	custom := filepath.Join(t.TempDir(), "custom shell", "shell.exe")
	tt.Type(custom)
	tt.Frame()
	tt.Key(0, ui.KeyEnter)
	for range 3 {
		tt.Frame()
	}
	if a.set.Shell != custom || settings.Load().Shell != custom {
		t.Fatalf("custom shell program not saved: %q", a.set.Shell)
	}
}

func TestShellArgumentsSaveBeforeLeavingPage(t *testing.T) {
	a := testApp(t)
	a.ss.page = "shell"
	tt := ui.NewTester(a.settingsView, 900, 1000)
	tt.Frame()
	focusArgs := func() {
		t.Helper()
		info, ok := tt.AccessByRole(ui.RoleTextField, locales.SetShellArgs())
		if !ok {
			t.Fatal("shell arguments field missing")
		}
		b := info.Bounds
		tt.ClickAt(b.X+b.W/2, b.Y+b.H/2)
	}
	focusArgs()
	tt.Type("-NoProfile")
	tt.Frame()
	if err := tt.Click(locales.PageGeneral()); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if a.set.ShellArgs != "-NoProfile" || settings.Load().ShellArgs != "-NoProfile" {
		t.Fatalf("leaving the page lost valid arguments: active %q, saved %q", a.set.ShellArgs, settings.Load().ShellArgs)
	}
	if err := tt.Click(locales.PageShell()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	focusArgs()
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Type(`-c "unterminated`)
	tt.Frame()
	if err := tt.Click(locales.PageGeneral()); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if a.set.ShellArgs != "-NoProfile" || settings.Load().ShellArgs != "-NoProfile" {
		t.Fatal("invalid arguments overwrote the last valid setting")
	}
	if err := tt.Click(locales.PageShell()); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		tt.Frame()
	}
	if a.ss.argsDraft != `-c "unterminated` || a.ss.argsError == "" {
		t.Fatal("invalid argument draft was lost when returning to the page")
	}
}

func TestShellPickerInstalled(t *testing.T) {
	a := testApp(t)
	a.openPalette()
	a.pal.query = "Shell:"
	tt := ui.NewTester(a.view, 1100, 640)
	tt.Frame()
	for _, entry := range a.shellInventory() {
		if !tt.HasText(locales.ShellPaletteItem(entry.Name)) {
			t.Errorf("installed shell missing: %+v", entry)
		}
	}
	shot(t, tt, "shell-picker-installed")
	tt.SetDark(true)
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	shot(t, tt, "shell-picker-installed-dark")
}

func TestShellPaletteQuery(t *testing.T) {
	for _, tt := range []struct {
		input, query string
		shellsOnly   bool
	}{
		{"shell:", "", true},
		{"shell: git", "git", true},
		{"ShElL: Git Bash", "Git Bash", true},
		{" \tshell:  pwsh  ", "pwsh", true},
		{"shell:pwsh", "pwsh", true},
		{"shell", "shell", false},
		{"powershell:", "powershell:", false},
		{"git shell:", "git shell:", false},
		{" git ", " git ", false},
	} {
		query, shellsOnly := shellPaletteQuery(tt.input)
		if query != tt.query || shellsOnly != tt.shellsOnly {
			t.Errorf("shellPaletteQuery(%q) = %q, %v; want %q, %v", tt.input, query, shellsOnly, tt.query, tt.shellsOnly)
		}
	}
}
