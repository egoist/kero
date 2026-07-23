# Changelog

All notable changes to kero. This file is the **source of truth for the release
notes shown in the in-app updater**: [`scripts/release.ts`](scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

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
