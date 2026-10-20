# Changelog

## Unreleased

- Panes other than the focused one in a split no longer have to fade:
  `dim-unfocused-panes = false`, or the toggle in Settings › Appearance.

## 2.0.5

- Find in a pane's scrollback with Cmd+F (Ctrl+F on Windows).
- Text stays readable on a light background: colors meant for a dark one,
  as Claude Code's near-white grays, get enough contrast with it. The new
  `minimum-contrast` setting sets how much, as in Ghostty.
- Command-hovering a link in a terminal underlines it.
- A pane shows where its agent works: the worktree Claude Code went into,
  rather than the folder its shell started in. Links, Copy Directory and
  Reveal follow it.
- Codex sessions are told to the pane that runs them, for resuming after
  kerod restarts, rather than to the pane that first started Codex's
  background service.

## 2.0.4

- Terminals show the cursor chosen in Settings, its shape and whether it
  blinks, rather than always a blinking block.

## 2.0.3

- An agent sitting at its prompt no longer shows as needing you, as Claude
  Code did a while after answering. A bell or a program's desktop
  notification leaves its status alone; programs' notifications show as
  they are.

## 2.0.2

- Installing the command line tool on macOS asks for an administrator's
  password instead of failing.

## 2.0.1

- Kero speaks Simplified Chinese; pick the language in Settings.
- Rename a project from its menu in the sidebar.
- `kero skill setup` hooks Claude Code, Codex, Pi and OpenCode into Kero as
  they start: an agent learns its session and pane, names an unnamed session
  after its task, and resumes when kerod restarts.
- `kero new|split --wait` and `kero wait --exit` exit with the command's
  status.
- When kerod runs another version of Kero, a Restart Service chip offers to
  restart it. Settings shows updates on its General page.
- A home directory pane shows `~` once in its header.

## 2.0.0

Kero, rewritten from the ground up: sessions grouped by project in a sidebar
that shows which are working, which need you and which are done. Sessions run
in kerod, a daemon of their own, so quitting Kero leaves them running.

- Runs on macOS, Windows and Linux.
- The `kero` CLI drives sessions from a shell or an agent.
- Updates itself from Kero's releases.
