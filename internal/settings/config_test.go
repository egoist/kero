package settings

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

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

// A quoted value is unquoted as it is read: quote escapes a backslash,
// so only stripping the quotes left a doubled one, and a value with a
// # in it — which quote always escapes — gained a backslash on every
// save. A quoted value whose escape is none is read as it lies.
func TestQuotedValueRoundTrip(t *testing.T) {
	const file = "worktree-dir = C:\\Users\\me\\#work\n" // one backslash each, as the file has them
	s, probs := parse(file)
	if len(probs) != 0 || s.WorktreeDir != `C:\Users\me\#work` {
		t.Fatalf("parsed %q, problems %q", s.WorktreeDir, probs)
	}
	// Save after save: the value stands, instead of gaining a
	// backslash each time.
	for i := 0; i < 3; i++ {
		back, _ := parse(format(s, file))
		if back.WorktreeDir != s.WorktreeDir {
			t.Fatalf("save %d read back %q, want %q", i+1, back.WorktreeDir, s.WorktreeDir)
		}
		s = back
	}
	// A hand's own quoting, whose escape is none, is read as it lies.
	hand, _ := parse(`worktree-dir = "C:\path\to"` + "\n")
	if hand.WorktreeDir != `C:\path\to` {
		t.Errorf("a value a hand quoted: %q", hand.WorktreeDir)
	}
}

func TestValueWithItsOwnQuotesSurvivesSave(t *testing.T) {
	for _, value := range []string{`"quoted"`, `""`} {
		t.Run(value, func(t *testing.T) {
			s := Default()
			s.FontFamily = value
			file := ""
			for i := 0; i < 3; i++ {
				file = format(s, file)
				back, problems := parse(file)
				if len(problems) != 0 || back.FontFamily != value {
					t.Fatalf("save %d read %q, problems %q; want %q", i+1, back.FontFamily, problems, value)
				}
				s = back
			}
		})
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

// A shortcut that takes another action's keys survives the file: the
// other action gives them up, and the one that took them keeps them.
func TestKeybindTakesKeys(t *testing.T) {
	down, _ := actions.Find("pane.split.down")
	s := Default()
	s.Shortcuts = map[string]string{
		"pane.split.right": down.Keys, // the keys of Split Down
		"pane.split.down":  "",        // and Split Down has none now
	}
	out := format(s, "")
	back, probs := parse(out)
	if len(probs) != 0 {
		t.Errorf("problems %q", probs)
	}
	if back.Shortcuts["pane.split.right"] != down.Keys {
		t.Errorf("the shortcut that took the keys: %q", back.Shortcuts["pane.split.right"])
	}
	if v, ok := back.Shortcuts["pane.split.down"]; !ok || v != "" {
		t.Errorf("split down %q %v", v, ok)
	}
	// The freeing comes first in the file, which is read in its order:
	// the action that takes the keys is bound after it.
	low := strings.ToLower(out)
	frees, binds := strings.Index(low, "=unbind"), strings.Index(low, "=pane.split.right")
	if frees < 0 || binds < 0 || frees > binds {
		t.Errorf("the freeing does not come before the binding:\n%s", out)
	}
}

// A file that binds keys and frees them after is read in the order it
// has, as Ghostty reads its own: the keys are free at the end.
func TestKeybindUnbindComesLast(t *testing.T) {
	s, probs := parse("keybind = " + `alt+shift+-=pane.split.right` + "\nkeybind = alt+shift+-=unbind\n")
	if len(probs) != 0 {
		t.Fatalf("problems %q", probs)
	}
	if v, ok := s.Shortcuts["pane.split.right"]; !ok || v != "" {
		t.Errorf("split right %q %v, want no keys: the file freed them last", v, ok)
	}
}

// Ghostty's global: prefix binds the quick terminal as Ghostty's
// configuration writes it.
func TestGlobalKeybind(t *testing.T) {
	s, probs := parse("keybind = global:ctrl+`=quickTerminal.toggle\n")
	if len(probs) != 0 || s.Shortcuts["quickTerminal.toggle"] != "Ctrl+`" {
		t.Errorf("quick terminal %q, problems %q", s.Shortcuts["quickTerminal.toggle"], probs)
	}
	if out := format(s, ""); !strings.Contains(out, "keybind = ctrl+`=quickTerminal.toggle\n") {
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

// A number that is no number — NaN, or past the end of what a float
// holds — keeps the default, and the line is a problem. A size of NaN
// would size a terminal of nothing: it is less than nothing and more
// than anything at once, and every check of it passes.
func TestNotANumberKeepsDefaults(t *testing.T) {
	d := Default()
	for _, c := range []struct {
		line string
		got  func(Settings) float64
		want float64
	}{
		{"font-size = NaN", func(s Settings) float64 { return float64(s.FontSize) }, float64(d.FontSize)},
		{"line-height = nan", func(s Settings) float64 { return float64(s.LineHeight) }, float64(d.LineHeight)},
		{"font-weight = NaN", func(s Settings) float64 { return float64(s.FontWeight) }, float64(d.FontWeight)},
		{"minimum-contrast = +Inf", func(s Settings) float64 { return float64(s.MinContrast) }, float64(d.MinContrast)},
		{"scrollback-limit = -Inf", func(s Settings) float64 { return float64(s.Scrollback) }, float64(d.Scrollback)},
		{"mouse-scroll-multiplier = NaN", func(s Settings) float64 { return float64(s.ScrollPrecision) }, float64(d.ScrollPrecision)},
		{"mouse-scroll-multiplier = precision:nan,discrete:1", func(s Settings) float64 { return float64(s.ScrollDiscrete) }, float64(d.ScrollDiscrete)},
	} {
		s, probs := parse(c.line + "\n")
		if got := c.got(s); got != c.want || math.IsNaN(got) {
			t.Errorf("%s: %v, want %v", c.line, got, c.want)
		}
		if len(probs) != 1 || !strings.Contains(probs[0], "not a number") {
			t.Errorf("%s: problems %q", c.line, probs)
		}
	}
}

// cell-width takes 0.8 to 2, and anything else keeps the default.
func TestCellWidthBounds(t *testing.T) {
	for _, tt := range []struct {
		value string
		want  float32
	}{
		{"1", 1},
		{"1.03", 1.03},
		{"2", 2},
		{"0.8", 0.8},
		{"0.79", Default().CellWidth},
		{"2.01", Default().CellWidth},
		{"NaN", Default().CellWidth},
		{"+Inf", Default().CellWidth},
		{"-Inf", Default().CellWidth},
	} {
		t.Run(tt.value, func(t *testing.T) {
			s, _ := parse("cell-width = " + tt.value + "\n")
			if s.CellWidth != tt.want {
				t.Errorf("cell width = %v, want %v", s.CellWidth, tt.want)
			}
		})
	}
}

// image-storage-limit takes 0 to 1024 megabytes, and anything else keeps
// the default.
func TestImageStorageLimitBounds(t *testing.T) {
	for _, tt := range []struct {
		value string
		want  int
	}{
		{"0", 0},
		{"64", 64},
		{"1024", 1024},
		{"1025", Default().ImageLimit},
		{"-1", Default().ImageLimit},
		{"NaN", Default().ImageLimit},
		{"+Inf", Default().ImageLimit},
		{"-Inf", Default().ImageLimit},
	} {
		t.Run(tt.value, func(t *testing.T) {
			s, _ := parse("image-storage-limit = " + tt.value + "\n")
			if s.ImageLimit != tt.want {
				t.Errorf("image-storage-limit = %v, want %v", s.ImageLimit, tt.want)
			}
		})
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
	if !strings.Contains(string(b), "font-size = 16") || !strings.Contains(string(b), "theme = petal") {
		t.Errorf("config:\n%s", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "settings.json")); err == nil {
		t.Error("settings.json stayed")
	}
}

// A legacy settings file that reads but cannot be migrated is not one
// whose settings are the defaults: say the write failure and leave the
// legacy file for the next start.
func TestLegacySettingsMigrationWriteFailureIsSaid(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permissions are Unix's")
	}
	if os.Geteuid() == 0 {
		t.Skip("root writes into a directory with no write permission")
	}
	dir := t.TempDir()
	t.Setenv("KERO_HOME", dir)
	cfgDir := filepath.Join(dir, "config")
	if err := os.Mkdir(cfgDir, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(cfgDir, "config")
	t.Setenv("KERO_CONFIG", cfg)
	legacy := filepath.Join(dir, "settings.json")
	old := []byte(`{"shell":"/usr/bin/fish","fontSize":16}`)
	if err := os.WriteFile(legacy, old, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(cfgDir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(cfgDir, 0o700) })
	mu.Lock()
	cache, cacheProblems, problems = nil, nil, nil
	mu.Unlock()

	got := Load()
	if got.Shell != "/usr/bin/fish" || got.FontSize != 16 {
		t.Errorf("settings fell back to defaults: %+v", got)
	}
	if ps := Problems(); len(ps) != 1 || !strings.Contains(ps[0], "could not be migrated") {
		t.Fatalf("the migration failure was not said: %q", ps)
	}
	if b, err := os.ReadFile(legacy); err != nil || string(b) != string(old) {
		t.Errorf("legacy settings were lost: %q, %v", b, err)
	}
}

// A legacy settings file with one value of the wrong type is not one that
// says nothing. The shell and the hosts it does hold stay unmigrated, the
// file stays, and the failure is said.
func TestLegacySettingsThatCannotBeReadAreSaid(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", filepath.Join(dir, "config"))
	legacy := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(legacy, []byte(`{"shell":"/usr/bin/fish","fontSize":"big"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	cache, cacheProblems, problems = nil, nil, nil
	mu.Unlock()
	if s := Load(); s.Shell != "" {
		t.Fatalf("settings that could not be read set the shell to %q", s.Shell)
	}
	if got := Problems(); len(got) != 1 || !strings.Contains(got[0], "could not be read") {
		t.Fatalf("problems: %q", got)
	}
	if _, err := os.Stat(Path()); !os.IsNotExist(err) {
		t.Fatalf("a configuration was written from settings that could not be read: %v", err)
	}
	if b, err := os.ReadFile(legacy); err != nil || !strings.Contains(string(b), "/usr/bin/fish") {
		t.Fatalf("the legacy settings did not stay: %q, %v", b, err)
	}
	Load()
	if got := Problems(); len(got) != 1 {
		t.Fatalf("a later read forgot the failure: %q", got)
	}
}

// background, which chose kero's theme before theme took kero's themes
// by name, still does, for theme = kero too; saving writes theme in its
// place.
func TestLegacyBackground(t *testing.T) {
	tests := []struct{ file, light, dark string }{
		{"background = mist\n", "mist", "mist"},
		{"background = mist\ntheme = kero\n", "mist", "mist"},
		{"background = mist\ntheme = light:kero,dark:Catppuccin Mocha\n", "mist", "Catppuccin Mocha"},
		{"theme = dusk\nbackground = mist\n", "dusk", "dusk"},
		{"theme = kero\n", "paper", "paper"},
		{"", "paper", "paper"},
	}
	for _, tt := range tests {
		s, probs := parse(tt.file)
		if s.LightTheme != tt.light || s.DarkTheme != tt.dark || len(probs) > 0 {
			t.Errorf("%q: themes %q and %q, problems %q; want %q and %q", tt.file, s.LightTheme, s.DarkTheme, probs, tt.light, tt.dark)
		}
	}
	if _, probs := parse("background = nope\n"); len(probs) != 1 {
		t.Errorf("problems %q", probs)
	}
	file := "# mine\nbackground = mist\nfont-size = 14\n"
	s, _ := parse(file)
	if out := format(s, file); out != "# mine\ntheme = mist\nfont-size = 14\n" {
		t.Errorf("formatted:\n%s", out)
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

// A line the file still gets wrong stays a problem after the settings
// are saved: format keeps the lines kero does not know, so the file is
// still wrong, and a save that said "no problems" would leave it wrong
// with nothing to show for it — the next Load takes the cache and does
// not look again.
func TestSaveKeepsProblems(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	if err := os.WriteFile(path, []byte("font-size = 14\nsome-future-key = yes\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", path)
	mu.Lock()
	cache = nil
	mu.Unlock()

	Load()
	if got := Problems(); len(got) != 1 || !strings.Contains(got[0], "some-future-key") {
		t.Fatalf("problems %q", got)
	}
	s := Load()
	s.FontSize = 15
	if err := Save(s); err != nil {
		t.Fatal(err)
	}
	if got := Problems(); len(got) != 1 || !strings.Contains(got[0], "some-future-key") {
		t.Errorf("after a save: problems %q, want the unknown key still named", got)
	}
	// The next Load takes the cache: it must say the same.
	if got := Problems(); len(got) != 1 || !strings.Contains(got[0], "some-future-key") {
		t.Errorf("after Load: problems %q", got)
	}
	// And a cold Load says it too: the key is still in the file.
	mu.Lock()
	cache = nil
	mu.Unlock()
	Load()
	if got := Problems(); len(got) != 1 || !strings.Contains(got[0], "some-future-key") {
		t.Errorf("after a fresh Load: problems %q", got)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "some-future-key") {
		t.Errorf("the unknown key left the file:\n%s", b)
	}
	if !strings.Contains(string(b), "font-size = 15") {
		t.Errorf("the saved setting is not in the file:\n%s", b)
	}
}

func TestSaveKeepsASymlinkedConfig(t *testing.T) {
	dir := t.TempDir()
	dotfiles := filepath.Join(dir, "dotfiles", "kero", "config")
	os.MkdirAll(filepath.Dir(dotfiles), 0o755)
	os.WriteFile(dotfiles, []byte("# mine\nfont-size = 14\n"), 0o600)
	link := filepath.Join(dir, "config", "kero", "config")
	os.MkdirAll(filepath.Dir(link), 0o755)
	if err := os.Symlink("../../dotfiles/kero/config", link); err != nil {
		t.Skip(err) // Windows without the privilege
	}
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", link)
	mu.Lock()
	cache = nil
	mu.Unlock()
	s := Load()
	s.FontSize = 16
	if err := Save(s); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Lstat(link); err != nil || st.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the symlink went: %v %v", st, err)
	}
	b, _ := os.ReadFile(dotfiles)
	if string(b) != "# mine\nfont-size = 16\n" {
		t.Errorf("dotfiles' config:\n%s", b)
	}
	if st, _ := os.Stat(dotfiles); st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode().Perm())
	}
}

func TestTargetFollowsSymlinks(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "dotfiles", "config") // not there yet, as before stow's first save
	mid := filepath.Join(dir, "mid")
	link := filepath.Join(dir, "config")
	if err := os.Symlink("dotfiles/config", mid); err != nil {
		t.Skip(err)
	}
	os.Symlink(mid, link)
	if got := target(link); got != file {
		t.Errorf("target(link) = %s, want %s", got, file)
	}
	if got := target(file); got != file {
		t.Errorf("target(file) = %s", got)
	}
}

// TestMouseScrollMultiplier: Ghostty's mouse-scroll-multiplier, with its
// precision: and discrete: prefixes or one number for both, kept in
// Ghostty's bounds.
func TestMouseScrollMultiplier(t *testing.T) {
	for _, c := range []struct {
		line                string
		precision, discrete float32
	}{
		{"", 1, 3},
		{"mouse-scroll-multiplier = 0.5", 0.5, 0.5},
		{"mouse-scroll-multiplier = precision:0.5,discrete:3", 0.5, 3},
		{"mouse-scroll-multiplier = discrete:1", 1, 1},
		{"mouse-scroll-multiplier = precision: 2 , discrete: 6", 2, 6},
		{"mouse-scroll-multiplier = precision:0,discrete:20000", 0.01, 10000},
	} {
		s, probs := parse(c.line + "\n")
		if len(probs) != 0 || s.ScrollPrecision != c.precision || s.ScrollDiscrete != c.discrete {
			t.Errorf("%q: precision %v, discrete %v, problems %q; want %v, %v", c.line, s.ScrollPrecision, s.ScrollDiscrete, probs, c.precision, c.discrete)
		}
		back, _ := parse(format(s, ""))
		if back.ScrollPrecision != s.ScrollPrecision || back.ScrollDiscrete != s.ScrollDiscrete {
			t.Errorf("%q: read back %v, %v", c.line, back.ScrollPrecision, back.ScrollDiscrete)
		}
	}
	for _, bad := range []string{"mouse-scroll-multiplier = fast", "mouse-scroll-multiplier = wheel:2"} {
		if _, probs := parse(bad + "\n"); len(probs) != 1 {
			t.Errorf("%q: problems %q, want one", bad, probs)
		}
	}
	if out := format(Default(), ""); strings.Contains(out, "mouse-scroll-multiplier =") {
		t.Errorf("a new file sets the default:\n%s", out)
	}
}

func TestFontFeature(t *testing.T) {
	for _, c := range []struct {
		file     string
		want     []string
		problems int
	}{
		{"", nil, 0},
		{"font-feature = ss01", []string{"ss01"}, 0},
		{"font-feature = ss01, -calt , cv05=2", []string{"ss01", "-calt", "cv05=2"}, 0},
		{"font-feature = +ss01\nfont-feature = calt=0", []string{"+ss01", "calt=0"}, 0},
		{"font-feature = ss01\nfont-feature =\nfont-feature = ss02", []string{"ss02"}, 0},
		{"font-feature = ss01, ligatures, -calt=1, cv05=x, ss2", []string{"ss01"}, 1},
	} {
		s, probs := parse(c.file + "\n")
		if !reflect.DeepEqual(s.FontFeatures, c.want) || len(probs) != c.problems {
			t.Errorf("%q: features %q, problems %q; want %q", c.file, s.FontFeatures, probs, c.want)
		}
		if back, _ := parse(format(s, "")); !reflect.DeepEqual(back.FontFeatures, s.FontFeatures) {
			t.Errorf("%q: read back %q", c.file, back.FontFeatures)
		}
	}
	if out := format(Default(), ""); strings.Contains(out, "font-feature") {
		t.Errorf("a new file sets font-feature:\n%s", out)
	}
}

// env keeps the good values even when a line among them is not
// NAME=value, and says the bad one at the end; an empty line clears the
// list, as the other lists do.
func TestEnvKeepsTheGoodValues(t *testing.T) {
	for _, c := range []struct {
		file     string
		want     []string
		problems int
	}{
		{"", nil, 0},
		{"env = A=1", []string{"A=1"}, 0},
		{"env = A=1\nenv = B=2", []string{"A=1", "B=2"}, 0},
		{"env = A=1\nenv =\nenv = B=2", []string{"B=2"}, 0},
		{"env = A=1\nenv = BAD\nenv = B=2", []string{"A=1", "B=2"}, 1},
	} {
		s, probs := parse(c.file + "\n")
		if !reflect.DeepEqual(s.Env, c.want) || len(probs) != c.problems {
			t.Errorf("%q: env %q, problems %q; want %q", c.file, s.Env, probs, c.want)
		}
	}
	_, probs := parse("env = A=1\nenv = BAD\nenv = B=2\n")
	if len(probs) != 1 || !strings.Contains(probs[0], "BAD") {
		t.Errorf("problems %q, want one naming BAD", probs)
	}
}

// new-session-directory takes a folder besides its choices, and writes it
// back as it was given.
func TestNewSessionDirectoryFolder(t *testing.T) {
	s, probs := parse("new-session-directory = ~/Developer\n")
	if len(probs) > 0 || s.NewSessionDir != "custom" || s.NewSessionPath != "~/Developer" {
		t.Fatalf("got %q %q, problems %q", s.NewSessionDir, s.NewSessionPath, probs)
	}
	if v := newSessionDirKey.get(&s); v[0] != "~/Developer" {
		t.Errorf("written back as %q", v)
	}
	if _, probs := parse("new-session-directory = Developer\n"); len(probs) != 1 {
		t.Errorf("a relative folder: problems %q", probs)
	}
	bad := Settings{NewSessionDir: "custom"}
	bad.normalize()
	if bad.NewSessionDir != Default().NewSessionDir {
		t.Errorf("custom with no folder kept as %q", bad.NewSessionDir)
	}
}

func TestFontZoom(t *testing.T) {
	if s, _ := parse(""); !s.FontZoom {
		t.Fatal("font-zoom is off without the key")
	}
	s, probs := parse("font-zoom = false\n")
	if len(probs) != 0 || s.FontZoom {
		t.Fatalf("font-zoom = false: %v, %v", s.FontZoom, probs)
	}
	if out := format(s, ""); !strings.Contains(out, "font-zoom = false\n") {
		t.Errorf("font-zoom = false is not written back: %q", out)
	}
}

// quit-ends-sessions is off without the key, and on as written.
func TestQuitEndsSessions(t *testing.T) {
	if Default().QuitEndsSessions {
		t.Fatal("quit-ends-sessions is on by default")
	}
	if s, _ := parse(""); s.QuitEndsSessions {
		t.Fatal("quit-ends-sessions is on without the key")
	}
	s, probs := parse("quit-ends-sessions = true\n")
	if len(probs) != 0 || !s.QuitEndsSessions {
		t.Fatalf("quit-ends-sessions = true: %v, %v", s.QuitEndsSessions, probs)
	}
	if out := format(s, ""); !strings.Contains(out, "quit-ends-sessions = true\n") {
		t.Errorf("quit-ends-sessions = true is not written back: %q", out)
	}
}

// dock-badge takes what the badge counts, and the true and false it had
// before it took modes.
func TestDockBadgeModes(t *testing.T) {
	d := Default()
	if d.DockBadge != DockBadgeWaiting {
		t.Errorf("default dock-badge %q", d.DockBadge)
	}
	for _, tt := range []struct {
		in   string
		want DockBadge
	}{
		{"", DockBadgeWaiting},
		{"dock-badge = waiting\n", DockBadgeWaiting},
		{"dock-badge = waiting-and-unread\n", DockBadgeWaitingUnread},
		{"dock-badge = off\n", DockBadgeOff},
		{"dock-badge = true\n", DockBadgeWaiting},
		{"dock-badge = FALSE\n", DockBadgeOff},
	} {
		s, probs := parse(tt.in)
		if len(probs) != 0 {
			t.Errorf("%q: %v", tt.in, probs)
		}
		if s.DockBadge != tt.want {
			t.Errorf("%q: dock-badge %q, want %q", tt.in, s.DockBadge, tt.want)
		}
		// A mode that isn't the default is written back as itself, and the
		// default as nothing at all, as every key is.
		out := format(s, "")
		switch tt.want {
		case DockBadgeWaiting:
			if strings.Contains(out, "dock-badge") {
				t.Errorf("%q: the default is written back: %q", tt.in, out)
			}
		default:
			if !strings.Contains(out, "dock-badge = "+string(tt.want)+"\n") {
				t.Errorf("%q: written back %q", tt.in, out)
			}
		}
	}
	// A value that is none of them keeps the default, and says why.
	s, probs := parse("dock-badge = sometimes\n")
	if s.DockBadge != DockBadgeWaiting {
		t.Errorf("a bad dock-badge changed the setting: %q", s.DockBadge)
	}
	if len(probs) != 1 || !strings.Contains(probs[0], "dock-badge") {
		t.Errorf("problems %q", probs)
	}
	// The JSON settings kero kept before the configuration file hold the
	// booleans too, as migrate reads them: a whole Settings in one
	// json.Unmarshal, where a string field given true would fail it.
	for _, tt := range []struct {
		in   string
		want DockBadge
	}{
		{`{"dockBadge": true}`, DockBadgeWaiting},
		{`{"dockBadge": false}`, DockBadgeOff},
		{`{"dockBadge": "waiting-and-unread"}`, DockBadgeWaitingUnread},
		{`{}`, DockBadgeWaiting},
	} {
		old := struct{ Settings }{Settings: Default()}
		if err := json.Unmarshal([]byte(tt.in), &old); err != nil {
			t.Errorf("%s: %s", tt.in, err)
		} else if old.Settings.DockBadge != tt.want {
			t.Errorf("%s: dockBadge %q, want %q", tt.in, old.Settings.DockBadge, tt.want)
		}
	}
}

// A configuration that is there but cannot be read is said, and never
// replaced with what it never held: the user's own lines would be lost.
func TestUnreadableConfigIsSaidAndKept(t *testing.T) {
	t.Run("a directory", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "config")
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
		t.Setenv("KERO_HOME", dir)
		t.Setenv("KERO_CONFIG", path)
		mu.Lock()
		cache = nil
		mu.Unlock()
		Load()
		if got := Problems(); len(got) == 0 {
			t.Fatal("a configuration that could not be read is said as the defaults, with nothing said")
		}
		s := Load()
		if err := Save(s); err == nil {
			t.Error("a save over a configuration it could not read")
		}
	})

	t.Run("no read permission", func(t *testing.T) {
		if os.Getuid() == 0 {
			t.Skip("root reads a file with no read permission")
		}
		if runtime.GOOS == "windows" {
			t.Skip("Windows reads a file with no read permission")
		}
		dir := t.TempDir()
		path := filepath.Join(dir, "config")
		if err := os.WriteFile(path, []byte("# mine\nfont-size = 14\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("KERO_HOME", dir)
		t.Setenv("KERO_CONFIG", path)
		mu.Lock()
		cache = nil
		mu.Unlock()

		// The file is there, but reading it is refused.
		if err := os.Chmod(path, 0o000); err != nil {
			t.Fatal(err)
		}
		s := Load()
		if got := Problems(); len(got) == 0 {
			t.Fatal("a configuration that could not be read is said as the defaults, with nothing said")
		}
		// A save must not replace it with what it never held.
		if err := Save(s); err == nil {
			t.Error("a save over a configuration it could not read")
		}
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(b), "# mine") {
			t.Errorf("the user's own lines are gone:\n%s", b)
		}
	})
}

// A configuration that is there but cannot be read is not a configuration
// that says nothing: the settings as they were last read stand, so that
// what the user set is not forgotten by a reader that could not read the
// file.
func TestUnreadableConfigKeepsTheLastSettings(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	if err := os.WriteFile(path, []byte("font-size = 21\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", path)
	mu.Lock()
	cache, mtime = nil, 0
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		cache, mtime = nil, 0
		mu.Unlock()
	})
	if s := Load(); s.FontSize != 21 {
		t.Fatalf("loaded %v, want 21", s.FontSize)
	}
	// The file is there, and cannot be read: a directory where it was.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	// Its own time, so that the file that was read is not taken for the
	// one that is there.
	at := time.Now().Add(time.Hour)
	if err := os.Chtimes(path, at, at); err != nil {
		t.Fatal(err)
	}
	s := Load()
	if got := Problems(); len(got) == 0 {
		t.Fatal("a configuration that could not be read is said as nothing")
	}
	if s.FontSize != 21 {
		t.Errorf("the settings as they were last read: %v, want 21", s.FontSize)
	}
}

// A configuration that could not be read is said while it cannot be;
// when it can be read again the trouble is over, though the file did not
// change under it — the cache hit takes the problems of the read it
// holds, not the ones the failed look left.
func TestUnreadableConfigProblemGoesWhenAccessReturns(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root enters a directory with no search permission")
	}
	if runtime.GOOS == "windows" {
		t.Skip("Windows enters a directory with no search permission")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	if err := os.WriteFile(path, []byte("font-size = 14\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", path)
	mu.Lock()
	cache, cacheProblems, problems = nil, nil, nil
	mu.Unlock()
	Load()
	if got := Problems(); len(got) != 0 {
		t.Fatalf("a configuration that reads says %v", got)
	}
	// The folder cannot be entered, so the look at the file fails for a
	// reason that is not "there is none".
	if err := os.Chmod(dir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })
	Load()
	if got := Problems(); len(got) == 0 {
		t.Fatal("a configuration that could not be read is said")
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	Load()
	if got := Problems(); len(got) != 0 {
		t.Errorf("the configuration reads again, and still says %v", got)
	}
}

// A value with a line break in it cannot be written: the file is read a
// line at a time, so it would be two lines, and the second one would set
// a setting of its own — the font size, say, where the user asked for an
// environment variable.
func TestSaveRefusesAValueWithALineBreak(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", path)
	mu.Lock()
	cache, cacheProblems, problems = nil, nil, nil
	mu.Unlock()

	s := Default()
	s.Env = []string{"A=1\nfont-size = 20"}
	if err := Save(s); err == nil {
		t.Fatal("a value with a line break in it was saved")
	}
	if b, _ := os.ReadFile(path); len(b) != 0 {
		t.Errorf("the configuration was written anyway:\n%s", b)
	}
	// The setting the second line would have set is not set.
	back := Load()
	if back.FontSize != s.FontSize {
		t.Errorf("the font size = %v, want %v", back.FontSize, s.FontSize)
	}
	if len(back.Env) != 0 {
		t.Errorf("the environment = %q, want none", back.Env)
	}
}
