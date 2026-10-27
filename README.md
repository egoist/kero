# Kero

A terminal for coding agents, on macOS, Windows and Linux.

Run Claude Code, Codex, a dev server or a test watcher each in its own session. Kero groups sessions by project in a sidebar that shows which are working, which need you and which are done.

- **Sessions outlive the window.** They run in `kerod`, a small daemon, so quitting Kero leaves them running. Reopen it and every pane and its scrollback is back.
- **Status at a glance.** Each pane is working, waiting, idle, error or exited. <kbd>⌘</kbd> <kbd>J</kbd> jumps to the one that needs you, and Kero notifies you when an agent finishes, fails or is blocked.
- **A CLI agents can drive.** `kero` starts sessions, splits panes, types into them, waits on them and reads their screens.
- **Remote hosts.** Run agents on a Linux box, a cloud VM, a Mac, a Windows PC or WSL and see them in the same sidebar, over SSH or Tailscale. They keep running when your laptop sleeps. See [Remote Hosts](docs/remote.md).
- **Ghostty under the hood.** Terminals render with libghostty, so Ghostty themes, fonts and config keys just work.

## Install

Download Kero from the [releases page](https://github.com/egoist/kero/releases), then choose **Kero › Install Command Line Tool…** to put `kero` on your `PATH`.

```sh
kero new -n fix-login -- claude
```

To run sessions on a Linux server, a Mac or a Windows PC, install the server build there, then add the machine in **Settings › Hosts**:

```sh
curl -fsSL https://github.com/egoist/kero/releases/latest/download/install-server.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://github.com/egoist/kero/releases/latest/download/install-server.ps1 | iex
```

See the [docs](docs/index.md) for more.

## Prior art

- [**Rex**](https://www.superlogical.com/rex/docs/installation): Mitchell Hashimoto's terminal and multiplexer in one native app, with sessions that persist through a server and a scriptable CLI.
- [**Herdr**](https://github.com/herdrdev/herdr): a terminal multiplexer for running many coding agents in one terminal, with agent status detection.

## License

MIT
