package main

import (
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/actions"

	"kero/locales"
)

// searchEntry is a setting the Settings window's search finds: its page,
// its label as its row shows it, and words that find it besides, as its
// key in the configuration file.
type searchEntry struct {
	page, label, words string
}

// settingsIndex is the settings the search finds, labelled in the
// language the app shows, as their rows are.
func settingsIndex() []searchEntry {
	return []searchEntry{
		{"general", locales.SetNewSessionsStartIn(), "new-session-directory folder current project home tab"},
		{"general", locales.SetSessionName(), "session-name title sidebar focused lead folder pane"},
		{"general", locales.SetAskBeforeClosing(), "confirm-close quit kill"},
		{"general", locales.SetRestoreSessions(), "restore-sessions reboot persist"},
		{"general", locales.SetResumeAgents(), "resume-agents claude codex pi opencode conversation restore reboot"},
		{"general", locales.SetGitStatus(), "git-status branch changes diff repository worktree"},
		{"general", locales.SetDiffLayout(), "diff-layout diff unified split side by side changes"},
		{"general", locales.SetOpenAtLogin(), "startup launch login items"},
		{"general", locales.SetVersion(), "updates check for updates software update about"},
		{"general", locales.SetAutoCheck(), "updates automatic background daily"},
		{"general", locales.SetAutoInstall(), "updates automatic install download"},

		{"appearance", locales.SetAppearance(), "window-theme dark light mode system"},
		{"appearance", locales.SetLanguage(), "language locale translation chinese english 语言 中文"},
		{"appearance", locales.SetTranslucent(), "window-translucent vibrancy blur material transparency"},
		{"appearance", locales.SetBackground(), "background wash petal mist meadow dusk plain gradient color"},

		{"terminal", locales.SetFont(), "font-family typeface jetbrains mono nerd"},
		{"terminal", locales.SetSize(), "font-size zoom bigger smaller text"},
		{"terminal", locales.SetLineHeight(), "line-height spacing leading cell"},
		{"terminal", locales.SetWeight(), "font-weight bold light"},
		{"terminal", locales.SetLigatures(), "font-ligatures calt arrows"},
		{"terminal", locales.SetThicken(), "font-thicken stroke smoothing"},
		{"terminal", locales.SetLightWindows(), "theme colors color scheme ghostty palette"},
		{"terminal", locales.SetDarkWindows(), "theme colors color scheme ghostty palette"},
		{"terminal", locales.SetShape(), "cursor-style cursor block bar underline caret"},
		{"terminal", locales.SetBlink(), "cursor-style-blink cursor caret"},
		{"terminal", locales.SetOptionMeta(), "macos-option-as-alt alt meta emacs readline keyboard"},
		{"terminal", locales.SetCopyOnSelect(), "copy-on-select clipboard selection"},
		{"terminal", locales.SetRightClick(), "right-click-action context menu paste mouse"},
		{"terminal", locales.SetClipboardRead(), "clipboard-read osc 52 paste privacy"},

		{"shell", locales.SetShell(), "command fish zsh bash login"},
		{"shell", locales.SetScrollback(), "scrollback-limit history buffer lines memory"},
		{"shell", locales.SetEnvironment(), "env variables path"},

		{"notifications", locales.SetNotifyWaiting(), "notify-on-waiting attention blocked permission"},
		{"notifications", locales.SetNotifyDone(), "notify-on-done done complete"},
		{"notifications", locales.SetNotifyFailed(), "notify-on-error error"},
		{"notifications", locales.SetPlaySound(), "notify-sound audio"},
		{"notifications", locales.SetDockBadge(), "dock-badge count"},
		{"notifications", locales.SetDockBounce(), "dock-bounce attention"},

		{"agents", locales.SetRemoteControlRow(), "remote-control kero do focus browser automation"},
		{"agents", locales.SetCliRow(), "cli command line tool install path"},
		{"agents", "Claude Code", "skill agents install"},
		{"agents", "Codex, OpenCode, Pi", "skill agents install"},
		{"agents", locales.SetProgramStatus(), "osc 7501 report progress"},

		{"advanced", locales.SetConfigFile(), "configuration ghostty edit file dotfiles"},
		{"advanced", "kerod", "daemon background service restart sessions"},
		{"advanced", locales.SetLog(), "kerod log debug"},
		{"advanced", locales.SetFolder(), "data directory finder"},
		{"advanced", locales.SetReset(), "defaults reset"},
	}
}

// searchEntries are the index and the actions, which the keyboard page
// lists, with the shortcuts they have.
func searchEntries(shortcuts map[string]string) []searchEntry {
	out := settingsIndex()
	for _, act := range actions.All {
		keys := actions.Keys(act, shortcuts)
		out = append(out, searchEntry{"keyboard", strings.TrimSuffix(actionTitle(act.ID), "…"),
			act.ID + " shortcut keybind " + act.Menu + " " + strings.ToLower(keys) + " " + actions.Glyphs(keys) + " " + actionWords[act.ID]})
	}
	return out
}

// actionWords find actions besides their titles: what one looks for an
// action by when its title doesn't say it.
var actionWords = map[string]string{
	"changes.toggle":  "git diff branch panel",
	"pane.browser":    "web page url preview localhost open",
	"browser.address": "web url address go to",
}

// matches reports whether every word of a query is in a text.
func matches(text string, terms []string) bool {
	text = strings.ToLower(text)
	for _, t := range terms {
		if !strings.Contains(text, t) {
			return false
		}
	}
	return len(terms) > 0
}

// searchResults returns what a query finds, by page: the labels of the
// settings it finds, an empty list for a page whose title it is, and
// nothing for the others. It returns nil for an empty query.
func searchResults(query string, shortcuts map[string]string) map[string][]string {
	terms := strings.Fields(strings.ToLower(query))
	if len(terms) == 0 {
		return nil
	}
	out := map[string][]string{}
	for _, p := range settingsPages {
		if matches(p.title(), terms) {
			out[p.id] = []string{}
		}
	}
	for _, e := range searchEntries(shortcuts) {
		if matches(e.label+" "+e.words, terms) {
			out[e.page] = append(out[e.page], e.label)
		}
	}
	return out
}

// The search's finds on the page shown, by label, which settingRow and
// settingsGroup highlight as they build; nil while not searching. The
// Settings window is the only view that builds them, and sets these
// before it does.
var (
	searchHits   map[string]bool
	searchReveal string // the find to scroll to, in this build only
)

// searchHighlight marks a find of the search behind el, a row or a
// title, as a tint wider than it by dx on each side, and taller by dy.
func searchHighlight(c *ui.Context, el ui.Element, label string, pal *palette, dx, dy float32) {
	hit := searchHits[label]
	t := el.Animate("hit", b2f(hit), 180*time.Millisecond)
	if label == searchReveal {
		el.ScrollIntoView()
	}
	if t > 0 {
		ui.Box(c.Key("hit")).Absolute().Top(-dy).Bottom(-dy).Left(-dx).Right(-dx).Radius(8).PassThrough().
			Background(pal.accent.Alpha(0.13*t)).InsetShadow(0, 0, 0, 1, pal.accent.Alpha(0.28*t))
	}
}
