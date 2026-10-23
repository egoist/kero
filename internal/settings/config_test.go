package settings

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kero/internal/actions"
)

func TestFormatKeepsTheUsersFile(t *testing.T) {
	file := `# my kero
font-size = 14

# colors
theme = light:Catppuccin Latte,dark:Catppuccin Mocha
some-future-key = yes
env = A=1
env = B=2
`
	s, probs := parse(file)
	if s.FontSize != 14 || s.LightTheme != "Catppuccin Latte" || s.DarkTheme != "Catppuccin Mocha" {
		t.Fatalf("parsed %+v", s)
	}
	if !reflect.DeepEqual(s.Env, []string{"A=1", "B=2"}) {
		t.Errorf("env %q", s.Env)
	}
	if len(probs) != 1 || !strings.Contains(probs[0], "some-future-key") {
		t.Errorf("problems %q", probs)
	}
	s.FontSize = 15
	s.Env = []string{"C=3"}
	s.CursorBlink = false
	out := format(s, file)
	want := `# my kero
font-size = 15

# colors
theme = light:Catppuccin Latte,dark:Catppuccin Mocha
some-future-key = yes
env = C=3
cursor-style-blink = false
`
	if out != want {
		t.Errorf("formatted:\n%s\nwant:\n%s", out, want)
	}
	back, _ := parse(out)
	if !reflect.DeepEqual(back, s) {
		t.Errorf("read back %+v, want %+v", back, s)
	}
}

func TestFormatNewFileHasOnlyChanges(t *testing.T) {
	s := Default()
	settingLines := func(out string) int {
		n := 0
		for _, l := range strings.Split(out, "\n") {
			if l != "" && !strings.HasPrefix(l, "#") {
				n++
			}
		}
		return n
	}
	if out := format(s, ""); settingLines(out) != 0 {
		t.Errorf("defaults wrote settings:\n%s", out)
	}
	s.FontFamily, s.Appearance = "Iosevka Term", "dark"
	out := format(s, "")
	if !strings.Contains(out, "window-theme = dark\n") || !strings.Contains(out, "font-family = Iosevka Term\n") {
		t.Errorf("formatted:\n%s", out)
	}
	if n := settingLines(out); n != 2 {
		t.Errorf("%d settings written, want 2:\n%s", n, out)
	}
}

func TestKeybinds(t *testing.T) {
	s, probs := parse("keybind = cmd+shift+x=pane.split.right\nkeybind = cmd+d=unbind\nkeybind = cmd+==text.bigger\nkeybind = ctrl+q=nope\n")
	if s.Shortcuts["pane.split.right"] != "CmdOrCtrl+Shift+X" {
		t.Errorf("split right %q", s.Shortcuts["pane.split.right"])
	}
	if v, ok := s.Shortcuts["pane.split.right"]; !ok || v == "" {
		t.Errorf("split right lost to the unbind: %q", v)
	}
	if s.Shortcuts["text.bigger"] != "CmdOrCtrl+=" {
		t.Errorf("bigger %q", s.Shortcuts["text.bigger"])
	}
	if len(probs) != 1 || !strings.Contains(probs[0], "nope") {
		t.Errorf("problems %q", probs)
	}
	// Unbinding keys frees the action that has them.
	split, _ := actions.Find("pane.split.right")
	keys := configKeys(split.Keys) // cmd+d on macOS
	s2, _ := parse("keybind = " + keys + "=unbind\n")
	if v, ok := s2.Shortcuts["pane.split.right"]; !ok || v != "" {
		t.Errorf("%s unbound, split right %q %v", keys, v, ok)
	}
	if out := format(s2, ""); !strings.Contains(out, "keybind = "+keys+"=unbind\n") {
		t.Errorf("formatted:\n%s", out)
	}
}

func TestBadValuesKeepDefaults(t *testing.T) {
	s, probs := parse("cursor-style = triangle\nfont-size = big\nconfirm-close = maybe\n")
	d := Default()
	if s.Cursor != d.Cursor || s.FontSize != d.FontSize || s.ConfirmClose != d.ConfirmClose {
		t.Errorf("bad values changed settings: %+v", s)
	}
	if len(probs) != 3 {
		t.Errorf("problems %q", probs)
	}
}

// Kero the frog is on unless the configuration says otherwise, and
// stands at the right unless the configuration says where.
func TestPet(t *testing.T) {
	if !Default().Pet || Default().PetPosition != "right" || Default().PetOffset != 0.5 {
		t.Fatal("the pet is off, or not at the right and middle, by default")
	}
	s, probs := parse("pet = false\npet-position = left\n")
	if s.Pet || s.PetPosition != "left" || len(probs) != 0 {
		t.Fatalf("pet = false, left: %v %q, problems %q", s.Pet, s.PetPosition, probs)
	}
	if out := format(s, ""); !strings.Contains(out, "pet = false\n") || !strings.Contains(out, "pet-position = left\n") {
		t.Errorf("formatted:\n%s", out)
	}
	back, _ := parse(format(s, ""))
	if back.Pet || back.PetPosition != "left" {
		t.Errorf("came back %v %q", back.Pet, back.PetPosition)
	}
	// A custom position keeps its place across the window.
	s, probs = parse("pet-position = custom\npet-offset = 0.25\n")
	if s.PetPosition != "custom" || s.PetOffset != 0.25 || len(probs) != 0 {
		t.Fatalf("custom: %q %v, problems %q", s.PetPosition, s.PetOffset, probs)
	}
	if out := format(s, ""); !strings.Contains(out, "pet-position = custom\n") || !strings.Contains(out, "pet-offset = 0.25\n") {
		t.Errorf("formatted:\n%s", out)
	}
	if back, _ := parse(format(s, "")); back.PetPosition != "custom" || back.PetOffset != 0.25 {
		t.Errorf("came back %q %v", back.PetPosition, back.PetOffset)
	}
	// A place it does not know, or a place past the window, keeps the
	// default.
	if s, probs = parse("pet-position = top\npet-offset = 1.5\n"); s.PetPosition != "right" || s.PetOffset != 0.5 || len(probs) != 1 {
		t.Errorf("bad place: %q %v, problems %q", s.PetPosition, s.PetOffset, probs)
	}
}

// The background's opacity is a number in the configuration, 0 to 1,
// and is the default when it is out of range.
func TestWindowOpacity(t *testing.T) {
	if Default().WindowOpacity != DefaultWindowOpacity {
		t.Fatalf("default opacity %v, want %v", Default().WindowOpacity, DefaultWindowOpacity)
	}
	s, probs := parse("window-opacity = 0.5\n")
	if s.WindowOpacity != 0.5 || len(probs) != 0 {
		t.Fatalf("window-opacity = 0.5: %v, problems %q", s.WindowOpacity, probs)
	}
	if out := format(s, ""); !strings.Contains(out, "window-opacity = 0.5\n") {
		t.Errorf("formatted:\n%s", out)
	}
	if back, _ := parse(format(s, "")); back.WindowOpacity != 0.5 {
		t.Errorf("came back %v", back.WindowOpacity)
	}
	if s, probs := parse("window-opacity = 0\n"); s.WindowOpacity != 0 || len(probs) != 0 {
		t.Errorf("window-opacity = 0: %v, problems %q", s.WindowOpacity, probs)
	}
	if s, probs := parse("window-opacity = 1.5\n"); s.WindowOpacity != DefaultWindowOpacity || len(probs) != 0 {
		t.Errorf("window-opacity = 1.5: %v, problems %q", s.WindowOpacity, probs)
	}
	if out := format(Default(), ""); strings.Contains(out, "window-opacity") {
		t.Errorf("the default opacity was written:\n%s", out)
	}
}

// The background's blur is on unless the configuration turns it off.
func TestWindowBlur(t *testing.T) {
	if !Default().WindowBlur {
		t.Fatal("blur is off by default")
	}
	s, probs := parse("window-blur = false\n")
	if s.WindowBlur || len(probs) != 0 {
		t.Fatalf("window-blur = false: %v, problems %q", s.WindowBlur, probs)
	}
	if out := format(s, ""); !strings.Contains(out, "window-blur = false\n") {
		t.Errorf("formatted:\n%s", out)
	}
	if back, _ := parse(format(s, "")); back.WindowBlur {
		t.Error("the blur came back on")
	}
}

// Kero elsewhere updates the app here only once the user lets it.
func TestRemoteUpdatesOptIn(t *testing.T) {
	if Default().RemoteUpdates {
		t.Error("remote updates are on by default")
	}
	s, probs := parse("remote-updates = true\n")
	if !s.RemoteUpdates || len(probs) != 0 {
		t.Errorf("remote-updates = true: %v, problems %q", s.RemoteUpdates, probs)
	}
}

func TestMigratesSettingsJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", filepath.Join(dir, "config", "kero", "config"))
	os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"fontSize": 16, "appearance": "dark", "background": "rex"}`), 0o600)
	mu.Lock()
	cache = nil
	mu.Unlock()
	s := Load()
	if s.FontSize != 16 || s.Appearance != "dark" {
		t.Fatalf("migrated %+v", s)
	}
	b, err := os.ReadFile(Path())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "font-size = 16") || strings.Contains(string(b), "background") {
		t.Errorf("config:\n%s", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "settings.json")); err == nil {
		t.Error("settings.json stayed")
	}
}

func TestAdLists(t *testing.T) {
	tests := []struct {
		file     string
		want     []string
		problems int
	}{
		{"", []string{"easylist", "easyprivacy"}, 0},
		{"browser-filter-list = easylist\nbrowser-filter-list = peter-lowe\nbrowser-filter-list = easylist", []string{"easylist", "peter-lowe"}, 0},
		{"browser-filter-list =", []string{}, 0},
		{"browser-filter-list = easylist\nbrowser-filter-list =\nbrowser-filter-list = fanboy-cookie", []string{"fanboy-cookie"}, 0},
		{"browser-filter-list = https://lists.example/ads.txt", []string{"https://lists.example/ads.txt"}, 0},
		{"browser-filter-list = easylist\nbrowser-filter-list = no-such-list\nbrowser-filter-list = ftp://lists.example/x", []string{"easylist"}, 1},
	}
	for _, tt := range tests {
		s, probs := parse(tt.file)
		if !reflect.DeepEqual(s.AdLists, tt.want) || len(probs) != tt.problems {
			t.Errorf("%q: lists %q, problems %q", tt.file, s.AdLists, probs)
		}
		// What is saved reads back the same: no lists as none, not the
		// defaults.
		if back, _ := parse(format(s, "")); !reflect.DeepEqual(back.AdLists, s.AdLists) {
			t.Errorf("%q: saved and read back %q, want %q", tt.file, back.AdLists, s.AdLists)
		}
	}
	if out := format(Default(), ""); strings.Contains(out, "browser-filter-list") {
		t.Errorf("the default lists were written:\n%s", out)
	}
}
