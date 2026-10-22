---
title: Remote Hosts
description: Run sessions on a Linux box, a cloud VM or another computer, and see them in the same sidebar as your local ones.
---

# Remote Hosts

Kero can show sessions that run on other machines, such as a Linux dev box, a cloud VM, a Mac mini under your desk or a WSL distribution, in the same window as your local ones. They get the same sidebar, statuses, notifications and `kero` command. Each machine runs its own kerod, so closing your laptop or quitting Kero leaves remote agents running, as it does locally.

## Quick start

On the machine, install the server build of Kero. It needs no root or administrator, no display and no GTK. On Linux or macOS:

```sh
curl -fsSL https://github.com/egoist/kero/releases/latest/download/install-server.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://github.com/egoist/kero/releases/latest/download/install-server.ps1 | iex
```

On your computer, open **Settings › Hosts**, type the address you'd give `ssh`, such as `me@devbox`, and press **Add**. The host's projects appear in the sidebar with yours, each tagged with the host's name.

The same from the command line:

```sh
kero hosts add devbox me@devbox
kero -H devbox new -n review -- claude
```

::: tip
If Kero isn't installed on a host you add, the sidebar says so and offers **Install Kero…**, which runs the script above on the host over SSH.
:::

## How Kero reaches a host

An address says how to reach a host. Kero takes the same address in Settings, in the configuration file and after `kero -H`.

| Address | How |
| --- | --- |
| `devbox`, `me@devbox`, `me@devbox:2222`, `ssh://me@devbox` | SSH, with your `~/.ssh/config`, keys and agent |
| `wsl://Ubuntu`, `wsl://` | A WSL distribution of this Windows PC, through `wsl.exe` |
| `http://devbox:7373` | kerod's listener on a tailnet address (see [Tailscale](#tailscale)) |
| `https://devbox.tail1234.ts.net` | kerod behind Tailscale Serve |

Kero opens one connection per host and carries everything over it: the sidebar's state, every pane you look at, and the CLI's commands. The connection is compressed, and a heartbeat notices a dead link within seconds. When a link drops, as when a laptop sleeps, the host's sessions stay in the sidebar, faded, and Kero reconnects on its own, waiting longer between tries up to a minute.

### SSH

Over SSH, Kero runs `kero __bridge` on the host, which starts kerod there if it isn't running and passes the connection to it. There is nothing to set up on the host beyond installing Kero, and nothing listens on the network.

Kero never prompts for anything over SSH, as there's no one to answer in the app:

- **Keys with a passphrase** need your SSH agent.
- **A host you haven't connected to before** needs its key trusted first. Run `ssh me@devbox` once in a terminal.
- **Password logins** aren't supported. Use a key.

Kero looks for `kero` on the host in `~/.local/bin` (on Windows, `%LOCALAPPDATA%\Programs\kero-server`), the desktop app's command line tool and your `PATH`. If yours is elsewhere, name it in the address: `me@devbox?kero=/opt/kero/kero`, or on Windows `me@pc?kero=C:/kero/kero.exe`.

### Windows hosts

Kero reaches a Windows machine over SSH, so turn on its OpenSSH Server first (**Settings › System › Optional features**, as an administrator). Kero works with the server's default shell, cmd, and with PowerShell. It finds out which one the first time it connects, which costs that connection a moment.

The install script runs kerod as a task of yours in Task Scheduler, which starts it as you log on to the machine, in your session. While no one is logged on, kerod starts as Kero connects and keeps running after the connection ends. A kerod started that way runs without your Windows password, as programs do over SSH with a key, so programs in its sessions can't reach network shares or the credentials Windows keeps for you. Log on to the machine once, or restart kerod after you do, to run them with your full account.

### WSL

On Windows, `wsl://Ubuntu` reaches the Kero installed in that WSL distribution, as SSH would. `wsl://` is the default distribution. If Kero isn't installed there, Kero offers to install it, as it does over SSH.

WSL may stop a distribution a while after its last program started from Windows ends, and kerod with it. Keep agents running by keeping the distribution up, for example with [systemd enabled](https://learn.microsoft.com/windows/wsl/systemd) and `kero daemon install-service` inside it.

### Tailscale

kerod can also listen on your tailnet, so that it needs no SSH at all. Tailscale tells kerod who connects, and by default only the Tailscale user who owns the machine gets in. Add these to the configuration on the host:

```ini
# ~/.config/kero/config on the host
listen = tailnet://:7373
```

Then add the host as `http://devbox:7373`. The connection is plain HTTP, which WireGuard encrypts between tailnet devices.

To serve it over HTTPS with Tailscale's certificate instead, let kerod listen on a socket and point Tailscale Serve at it:

```ini
listen = tailnet-serve://
```

```sh
tailscale serve --bg --https=443 unix:$HOME/.config/kero/serve.sock
```

Then add the host as `https://devbox.tail1234.ts.net`. The socket is `serve.sock` in Kero's data folder: `~/.config/kero` on Linux, `~/Library/Application Support/kero` on macOS.

To let others in besides the owner, list them with `listen-allow`: a tailnet login, `tag:ci` for tagged devices, or `*` for anyone on the tailnet. A tagged machine has no owner, so only `listen-allow` lets anyone in to it. Tailscale Serve doesn't tell kerod who tagged devices are: they connect to a `tailnet://` listener.

```ini
listen-allow = alice@example.com
listen-allow = tag:ci
```

kerod reads `listen` and `listen-allow` as it starts, so run `kero daemon restart` after changing them. It listens only when the configuration asks, and only on Tailscale. It refuses requests from web browsers, so a web page you visit can't reach it. Funnel's requests from the internet never get in. To keep it listening with the machine, run it as a service (below).

## Running kerod as a service

On a server, run kerod as a service of your own, so that it starts with the machine and keeps your sessions running while no one is logged in. The install scripts do this for you. On a Mac, the service is a launchd agent, which runs while you're logged in to the Mac, so keep a session logged in there; the script installs it when you are. On Windows, it's a Task Scheduler task, which starts kerod as you log on.

```sh
kero daemon install-service      # a systemd user unit, a launchd agent on macOS, a task on Windows
kero daemon status               # how it runs, and where it listens
kero daemon uninstall-service
```

On Linux this first enables lingering (`loginctl enable-linger`), which keeps your services running after you log out. Without it, a service would stop as your last SSH session ends, which a kerod started on demand outlives, so `install-service` refuses to go on without it. If your system asks an administrator for lingering, ask them to run `sudo loginctl enable-linger <you>`, or install the service anyway with `--no-linger`.

`kero daemon serve` runs kerod in the foreground and logs to its standard error, for a service manager of your own. It never exits for being idle. `--listen` takes the place of the configuration's `listen` keys.

## Working on a host

- **The sidebar.** It lists projects, yours first, then each host's in the order of **Settings › Hosts**. A host's projects carry its name after theirs, as `api` `devbox`, so the same repository on two machines sits side by side. A host gets a row of its own only when it needs you: when Kero can't reach it, wants updating, or isn't installed there. A host with no sessions doesn't show; start one there with Open Project. Right-click one of a host's projects for the host's menu: reconnect, restart kerod, update Kero, its color, its settings.
- **Colors.** Each host has a color, picked from its name: its tag in the sidebar and its name in a pane's header wear it, so a remote pane is plain to see. Pick another from the host's menu, **Color**, or with `color=` after its address (`host = devbox=me@devbox color=teal`).
- **New sessions.** <kbd>⌘</kbd> <kbd>T</kbd> and **New Session** start a session on the host of the session you're looking at. A project's **+** starts one in it, on its machine.
- **Open Project.** With hosts added, <kbd>⌘</kbd> <kbd>O</kbd> lists folders in Kero instead of your computer's dialog, starting on the machine of the session you're looking at; the switch at its top lists another's. Type to filter, or type a path such as `~/code`. <kbd>↩</kbd> goes into a folder, and <kbd>⌘</kbd> <kbd>↩</kbd> or **Open** opens it as a project.
- **Paths.** <kbd>⌘</kbd>-clicking a file path in a remote pane opens the file in the host's `$EDITOR`, in a pane below. A folder opens in a new session there. Kero never opens a file of your computer that happens to have the same path. Hovering an image's path with <kbd>⌘</kbd> previews the host's image.
- **Pasting images and files.** Pasting an image or files into a remote pane copies them to a private temporary folder on the host and pastes their paths there, so agents that read image paths, such as Claude Code, keep working. Dragging files onto a remote pane still pastes your computer's paths.
- **Agents.** Inside a remote pane, `kero` talks to that host's kerod, so the agent skill works there unchanged. Run `kero skill setup` on the host.
- **Notifications.** A host's notifications and the window's title carry the host's name, so a remote program can't pass for a local one.

### Remote Control

`kero focus` and `kero do` let a program drive the app. For a host, that's code on another machine driving your computer's window, so it's off by default. Turn it on per host in **Settings › Hosts**, or with `remote-control` after the address:

```ini
host = devbox=me@devbox remote-control
```

### Settings

Appearance, keyboard and notifications are the app's. A host's shell, `env`, scrollback and session restore come from the configuration on that host, since kerod reads them there. Run `kero config edit` on the host to change them.

## Versions and updates

The app and a host can run different versions of Kero. When the host runs an older release than the app, its first project in the sidebar shows **Update**. It downloads the app's version of Kero onto the host, checks it against the key Kero's own updates are signed with, for that version and platform, and then restarts kerod there. Restarting starts the host's sessions again where they were, with their history, and the programs running in them end, so Kero asks first.

- Kero updates a host only when you ask, never on a reconnect, and never back to an older version.
- When the host runs a newer Kero than the app, update the app instead (**Settings › General**).
- Kero updates only an install of its install scripts. If you installed Kero on the host another way, or it runs the Kero desktop app, update it the way you installed it.

From the command line:

```sh
kero -H devbox version           # this kero's version, and the host's
kero -H devbox daemon status
kero -H devbox daemon update     # to this kero's version
kero -H devbox daemon restart
kero daemon update               # on the host, to the latest release
kero daemon update 2.1.0         # on the host, to a version, older ones too
```

## The command line

`-H` (or `--host`), before the command, points a command that acts on sessions at a host's kerod. It takes a host's name, an address, or `local` for this machine. `$KERO_HOST` does the same, except inside a pane, where `kero` acts on the pane's own machine. Commands of this machine alone, such as `kero config` and `kero hook`, ignore `$KERO_HOST`.

```sh
kero hosts                       # the hosts you added (--json for JSON)
kero hosts add build ci@build.lab --remote-control
kero hosts check build           # connect, and say how it went; a name or an address
kero hosts install build         # install Kero there, over SSH or WSL
kero hosts remove build
kero -H build ls
kero -H build prompt review "run the tests and fix them"
kero clients                     # who is connected to this machine's kerod
```

The app and the CLI share one list of hosts, the configuration's `host` keys:

```ini
host = devbox=me@devbox
host = build=ssh://ci@build.lab:2222 remote-control
host = ubuntu=wsl://Ubuntu
```

| Variable | What it does |
| --- | --- |
| `KERO_HOST` | The host commands act on, as `-H` |
| `KERO_SSH` | The `ssh` program Kero runs, in place of the one on your `PATH` |
| `KERO_RELEASES` | A mirror of Kero's releases, for the install scripts and `kero daemon update` |

## Security

- **A connection can do anything its account can,** including starting programs, as a local one can. Over SSH it's your own account, as SSH logs you in. Over Tailscale, only who the machine's owner lets in.
- **The socket is yours alone.** kerod's socket is created readable by its user only, and kerod refuses connections from other users' processes.
- **Updates are signed.** The server build updates itself only from archives signed with the key of Kero's releases.
- `kero clients` lists who is connected to a kerod, with how they came: `uid 501 over unix`, `me from 10.0.0.5 over ssh`, `alice@example.com over tailnet`.

## Limits

- The server build is for Linux, with glibc 2.28 or later, macOS and Windows 10 (1809) or later, on x86-64 and ARM64. On a Mac with the Kero app, the app's own kerod serves as a host too.
- Dragging files onto a remote pane pastes your computer's paths. Paste them instead.
- One host has one account. Login servers, where several people reach their own accounts on one machine, are planned.
