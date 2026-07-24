# Changelog

All notable changes to kero. This file is the **source of truth for the release
notes shown in the in-app updater**: [`scripts/release.ts`](scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

## [unreleased]

- Security: stop terminal programs from silently reading your clipboard — an OSC 52 escape sequence (for example from a remote SSH host) could previously read the macOS clipboard without any prompt; kero now asks for confirmation first, matching the Ghostty app default (#8)
- Warn before pasting text that looks like it could execute commands, matching Ghostty's paste protection
- Fix fuzzy-looking terminal text: font thickening was unintentionally always on, making glyphs heavier and softer than stock Ghostty
- Add a "Thicken font strokes" toggle in Settings → Font for those who prefer the heavier rendering

## [0.1.19]

- Fix a releasing signing issue

## [0.1.18]

- Fix max height of settings window

## [0.1.17]

- Add pane zoom: ⇧⌘↩ toggles the focused pane filling the tab, with a header button indicating the state and exiting zoom
- Add shortcuts to cycle pane focus (⌘[ / ⌘]), resize panes (⌃⌘ arrows) and equalize panes (⌃⌘=)

## [0.1.16]

- Tweaks shortcut description for toggling right sidebar

## [0.1.15]

- Fix potential memory leak

## [0.1.14]

- Add theme setting to force light or dark theme

## [0.1.13]

- Make editor full height
- Tweaks sidebar

## [0.1.12]

- Fix TSX highlight

## [0.1.10]

- fix git panel

## [0.1.9]

- Fix CPU usage spike due to libghostty intergration bug

## [0.1.8]

- Use libghostty

## [0.1.7]

- Remove GPU rendering temporarily

## [0.1.6]

- Fix window maximizing
- Shortcut for left sidebar: cmd-b

## [0.1.5]

- Double-click the title bar to zoom the window (honors the system "double-click a window's title bar to" setting)
- fix gpu rendering

## [0.1.4]

- Add "Session Contents Restored" divider to restored terminals
- set TERM_PROGRAM to Kero
- fix embedded language highlighting in markdown

## [0.1]

### Added
- Initial release.
