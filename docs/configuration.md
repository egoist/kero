---
title: Configuration
description: Kero's configuration file, its keys and their defaults.
---

# Configuration

Kero keeps its settings in one plain-text file. The Settings window (<kbd>⌘</kbd> <kbd>,</kbd>) edits it for you, keeping your comments and order, and Kero reloads it when you edit it by hand.

## The file

Kero reads, in order of preference:

1. `$KERO_CONFIG`
2. `$XDG_CONFIG_HOME/kero/config`
3. `~/.config/kero/config`

It uses Ghostty's syntax: one `key = value` per line, `#` for comments, and repeated lines for keys that hold lists. Where a key means what it means in Ghostty, it has Ghostty's name.

```ini
# ~/.config/kero/config
font-size = 14
theme = light:GitHub Light Default,dark:Catppuccin Mocha
cursor-style = bar

env = EDITOR=nvim
env = HOMEBREW_NO_AUTO_UPDATE=1

keybind = cmd+shift+d=pane.split.down
```

The file only needs what you change. Everything else keeps its default.

```sh
kero config edit              # open it in $EDITOR
kero config show              # every key with its current value
kero config check             # report unknown keys and bad values
```

## General

| Key                     | Default   | Description                                                   |
| ----------------------- | --------- | ------------------------------------------------------------- |
| `new-session-directory` | `current` | Where a new session starts: `current`, `project` or `home`    |
| `session-name`          | `focused` | What names a session you haven't: `focused`, `lead` or `folder` ([more](./sessions.md#how-an-unnamed-session-is-named)) |
| `focus-follows-mouse`   | `false`   | Focus the pane the pointer moves into                         |
| `confirm-close`         | `true`    | Ask before closing a pane that a program is running in        |
| `restore-sessions`      | `true`    | Start sessions again after kerod restarts, as after a reboot  |
| `resume-agents`         | `true`    | As sessions start again, resume the conversation of the agent each pane ran |
| `macos-show-app-icon`   | `dock-and-menubar` | Where Kero's icon shows on macOS: `dock-and-menubar`, `dock` or `menubar`. While it's in the menu bar, closing the window keeps Kero running there. Windows and Linux always show it in the notification area, where closing the window does the same |

## Appearance

| Key                  | Default  | Description                                                     |
| -------------------- | -------- | --------------------------------------------------------------- |
| `window-theme`       | `system` | The app's appearance: `system`, `light` or `dark`               |
| `language`           | `system` | The app's language: `system`, `en`, `ja` or `zh-Hans`           |
| `background`         | `petal`  | The window's wash: `petal`, `mist`, `meadow`, `dusk` or `plain` |
| `window-translucent` | `true`   | Let the desktop show through the window                         |

## Terminal

| Key                   | Default | Description                                                              |
| --------------------- | ------- | ------------------------------------------------------------------------ |
| `theme`               | `kero`  | Terminal colors: `kero`, any Ghostty theme, or `light:<theme>,dark:<theme>` |
| `font-family`         |         | Empty for JetBrains Mono Nerd Font, which Kero includes; `monospace` for the system's; or any installed family |
| `font-size`           | `13`    | In points                                                                |
| `font-weight`         | `400`   | `100` to `900`                                                           |
| `line-height`         | `1.22`  | A multiple of the font's                                                 |
| `font-ligatures`      | `true`  | Join characters the way the font draws them                              |
| `font-thicken`        | `false` | A heavier stroke, as in Ghostty                                          |
| `minimum-contrast`    | `3`     | The least contrast text keeps with its background, from `1` (none) to `21`, so that colors meant for a dark background stay readable on a light one, as in Ghostty |
| `dim-unfocused-terminals` | `true` | Fade the terminals you're not in, when a session has several panes |
| `cursor-style`        | `block` | `block`, `bar` or `underline`; programs may change it                    |
| `cursor-style-blink`  | `true`  | Blink the cursor                                                         |
| `macos-option-as-alt` | `false` | Option sends Alt (Meta) to programs                                      |
| `copy-on-select`      | `false` | Copy what you select to the clipboard                                    |
| `clipboard-read`      | `ask`   | Programs reading the clipboard (OSC 52): `ask`, `allow` or `deny`        |
| `right-click-action`  | `context-menu` | `context-menu`, `paste` or `copy-or-paste`                        |

## Shell

| Key                | Default | Description                                                    |
| ------------------ | ------- | -------------------------------------------------------------- |
| `command`          |         | The shell of new panes; empty for your login shell             |
| `env`              |         | Added to every pane's environment as `NAME=value`; repeat it   |
| `scrollback-limit` | `4`     | The output each pane keeps, in megabytes; `0` for none         |

## Notifications

| Key                 | Default | Description                                    |
| ------------------- | ------- | ---------------------------------------------- |
| `notify-on-waiting` | `true`  | When a session needs you                       |
| `notify-on-done`    | `true`  | When an agent finishes                         |
| `notify-on-error`   | `true`  | When a program reports it failed               |
| `notify-sound`      | `false` | Play a sound with notifications                |
| `dock-badge`        | `true`  | Show how many sessions need you on the Dock icon |
| `dock-bounce`       | `false` | Bounce the Dock icon once when a session comes to need you |

## Agents

| Key              | Default | Description                                         |
| ---------------- | ------- | --------------------------------------------------- |
| `remote-control` | `true`  | Let `kero do` and `kero focus` drive the app        |

## Hosts

Other machines whose sessions the app shows, and `kero -H` reaches. See [Remote Hosts](./remote.md).

| Key            | Default | Description |
| -------------- | ------- | ----------- |
| `host`         |         | A host, as `name=address`: `me@devbox` or `ssh://…` over SSH, `wsl://distro`, `http(s)://…` for kerod's tailnet listener. Add ` remote-control` after it to let its programs drive the app, and ` color=teal` (red, orange, amber, green, teal, blue, purple or pink) to mark its sessions. Repeat it for each host |
| `listen`       |         | Let Kero on other machines reach this one: `tailnet://:7373` on its Tailscale addresses, `tailnet-serve://` for Tailscale Serve. Repeat it for each |
| `listen-allow` |         | Who besides the machine's owner may connect: a tailnet login, `tag:name`, or `*` for anyone on the tailnet. Repeat it for each |
| `remote-updates` | `false` | Let Kero on your other machines update the Kero app here to its version, which relaunches it |

## Git

| Key           | Default | Description                                                                                       |
| ------------- | ------- | ------------------------------------------------------------------------------------------------- |
| `git-status`  | `true`  | Show each session's branch and [changes](./changes.md)                                            |
| `diff-layout` | `auto`  | Diffs in the changes panel: `unified`, `split` (side by side), or `auto`, side by side once it's wide |

## Browser

| Key                   | Default                    | Description                                                                         |
| --------------------- | -------------------------- | ----------------------------------------------------------------------------------- |
| `browser-block-ads`   | `true`                     | [Block ads and trackers](./panes.md#blocking-ads) in browser panes                  |
| `browser-filter-list` | `easylist`, `easyprivacy`  | A filter list to block with. Repeat it for each list; leave it empty for none       |

`browser-filter-list` takes the lists Kero offers by name, or the `https://` URL of any list in Adblock Plus syntax:

| Name               | List                                                                |
| ------------------ | ------------------------------------------------------------------- |
| `easylist`         | EasyList: ads                                                       |
| `easyprivacy`      | EasyPrivacy: trackers and analytics                                 |
| `peter-lowe`       | Peter Lowe's list: ad and tracker servers                           |
| `easylist-china`   | EasyList China: ads on Chinese sites                                |
| `fanboy-cookie`    | EasyList Cookie List: cookie notices and consent banners            |
| `fanboy-social`    | Fanboy's Social Blocking List: social media buttons and embeds      |
| `fanboy-annoyance` | Fanboy's Annoyance List: pop-ups and prompts, with the two above    |

```ini
browser-filter-list = easylist
browser-filter-list = easyprivacy
browser-filter-list = fanboy-cookie
browser-filter-list = https://example.com/my-filters.txt
```

## Keyboard

`keybind` rebinds an action, as `<keys>=<action>`. Repeat it for each binding. Use `unbind` as the action to free keys.

```ini
keybind = cmd+shift+d=pane.split.down
keybind = cmd+k=palette.open
keybind = cmd+b=unbind
```

Run `kero actions` for every action id, and see [Keyboard Shortcuts](./shortcuts.md) for the defaults.
