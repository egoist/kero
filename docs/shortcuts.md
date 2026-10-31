---
title: Keyboard Shortcuts
description: Kero's default keyboard shortcuts and the action ids to rebind them.
---

# Keyboard Shortcuts

Rebind any of these in **Settings › Keyboard**, or with `keybind` in the [configuration file](./configuration.md#keyboard).

On Windows and Linux, <kbd>Ctrl</kbd> with a letter belongs to the shell (<kbd>Ctrl</kbd> <kbd>D</kbd>, <kbd>Ctrl</kbd> <kbd>R</kbd>, <kbd>Ctrl</kbd> <kbd>W</kbd>…), so Kero's shortcuts add <kbd>Shift</kbd>, as Windows Terminal's do, or use <kbd>Alt</kbd>. A dash means the action has no shortcut there.

## Kero

| Action                       | macOS                                  | Windows & Linux                               | Action id        |
| ---------------------------- | -------------------------------------- | --------------------------------------------- | ---------------- |
| Settings…                    | <kbd>⌘</kbd> <kbd>,</kbd>              | <kbd>Ctrl</kbd> <kbd>,</kbd>                  | `settings.open`  |
| Quit (sessions keep running) | <kbd>⌘</kbd> <kbd>Q</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>Q</kbd> |                  |
| Quit and End All Sessions…   | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>Q</kbd> | –                                             | `app.quitAll`    |

## Session

| Action                      | macOS                                  | Windows & Linux                               | Action id           |
| --------------------------- | -------------------------------------- | --------------------------------------------- | ------------------- |
| New Session                 | <kbd>⌘</kbd> <kbd>T</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>T</kbd> | `session.new`       |
| New Session in Home         | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>T</kbd> | –                                             | `session.newHome`   |
| New Session in Worktree…     | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>T</kbd> | –                                             | `session.newWorktree` |
| Open Project…               | <kbd>⌘</kbd> <kbd>O</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>O</kbd> | `project.open`      |
| Go to Session…              | <kbd>⌘</kbd> <kbd>P</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>P</kbd> | `palette.open`      |
| Resume Conversation…        | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>O</kbd> | –                                             | `conversation.resume` |
| Jump to Session Needing You | <kbd>⌘</kbd> <kbd>J</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>J</kbd> | `session.attention` |
| Next Session                | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>]</kbd> | <kbd>Ctrl</kbd> <kbd>PgDn</kbd>               | `session.next`      |
| Previous Session            | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>[</kbd> | <kbd>Ctrl</kbd> <kbd>PgUp</kbd>               | `session.previous`  |
| Rename Session              | <kbd>⌘</kbd> <kbd>R</kbd>              | –                                             | `session.rename`    |
| Restart Pane                | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>R</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>R</kbd> | `pane.restart`      |
| Close                       | <kbd>⌘</kbd> <kbd>W</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>W</kbd> | `pane.close`        |
| Close Session               | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>W</kbd> | –                                             | `session.close`     |

<kbd>⌘</kbd> <kbd>1</kbd>–<kbd>9</kbd> (<kbd>Ctrl</kbd> <kbd>1</kbd>–<kbd>9</kbd> on Windows and Linux) go to the sidebar's sessions, and <kbd>Ctrl</kbd> <kbd>Tab</kbd> to the next one.

## Pane

| Action        | macOS                                  | Windows & Linux                                   | Action id          |
| ------------- | -------------------------------------- | ------------------------------------------------- | ------------------ |
| Split Right   | <kbd>⌘</kbd> <kbd>D</kbd>              | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>=</kbd>      | `pane.split.right` |
| Split Down    | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd> | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>-</kbd>      | `pane.split.down`  |
| New Browser Pane | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>B</kbd> | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>B</kbd>   | `pane.browser`     |
| Open Location | <kbd>⌘</kbd> <kbd>L</kbd>              | –                                                 | `browser.address`  |
| Zoom Pane     | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>↩</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>Enter</kbd> | `pane.zoom`        |
| Next Pane     | <kbd>⌘</kbd> <kbd>]</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>]</kbd>     | `pane.next`        |
| Previous Pane | <kbd>⌘</kbd> <kbd>[</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>[</kbd>     | `pane.previous`    |
| Pane Left     | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>←</kbd> | <kbd>Alt</kbd> <kbd>←</kbd>                       | `pane.left`        |
| Pane Right    | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>→</kbd> | <kbd>Alt</kbd> <kbd>→</kbd>                       | `pane.right`       |
| Pane Above    | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>↑</kbd> | <kbd>Alt</kbd> <kbd>↑</kbd>                       | `pane.up`          |
| Pane Below    | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>↓</kbd> | <kbd>Alt</kbd> <kbd>↓</kbd>                       | `pane.down`        |

## View

| Action         | macOS                     | Windows & Linux                               | Action id        |
| -------------- | ------------------------- | --------------------------------------------- | ---------------- |
| Toggle Sidebar | <kbd>⌘</kbd> <kbd>B</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>B</kbd> | `sidebar.toggle` |
| Toggle Right Sidebar | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>B</kbd> | – | `rightSidebar.toggle` |
| Toggle Changes | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>G</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>G</kbd> | `changes.toggle` |
| Toggle Files   | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>E</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>E</kbd> | `files.toggle` |
| Bigger         | <kbd>⌘</kbd> <kbd>=</kbd> | <kbd>Ctrl</kbd> <kbd>=</kbd>                  | `text.bigger`    |
| Smaller        | <kbd>⌘</kbd> <kbd>-</kbd> | <kbd>Ctrl</kbd> <kbd>-</kbd>                  | `text.smaller`   |
| Actual Size    | <kbd>⌘</kbd> <kbd>0</kbd> | <kbd>Ctrl</kbd> <kbd>0</kbd>                  | `text.reset`     |
| Quick Terminal | –                         | –                                             | `quickTerminal.toggle` |

## Quick terminal

The quick terminal drops down from the top of the screen over any app, as Ghostty's quick terminal and Quake-style consoles do, and goes back up when you press its shortcut again or click elsewhere. Its shortcut works in every app, so it has none until you give it one in **Settings › Keyboard**, or in the [configuration file](./configuration.md#keyboard):

```ini
keybind = ctrl+`=quickTerminal.toggle
```

It shows a session of its own, named Quick Terminal, which keeps running while it's hidden and after you quit Kero, and which the sidebar lists with the others. When its shell exits, the next press starts a new one. **View › Quick Terminal** and the menu bar icon's menu open it too, and `kero do quickTerminal.toggle` toggles it from a script.

On Wayland, the desktop binds the shortcut through the XDG desktop portal and may ask you to confirm it; desktops without the portal's global shortcuts can bind `kero do quickTerminal.toggle` to a key in their own keyboard settings.
