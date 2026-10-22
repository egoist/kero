# Changelog

## Unreleased

- Kero shows sessions that run on other machines, such as a Linux dev box,
  a cloud VM or a WSL distribution, in the same sidebar, tagged with each
  host's name, with their statuses and notifications. Add a host in
  Settings › Hosts by the address you'd give ssh, `me@devbox`: Kero
  reaches it over
  SSH with your keys and agent, or through kerod's listener on your
  tailnet (`listen = tailnet://:7373`), which Tailscale tells who
  connects to. One compressed connection carries all of a host's panes,
  and a host whose link drops shows its sessions faded until Kero
  reconnects on its own.
- On a host, New Session, Open Project (which lists the host's folders),
  Command-clicking a path (which opens it in the host's `$EDITOR`) and
  pasting an image or files (which copies them to the host) all act on
  the host. Its programs drive the app with `kero focus` and `kero do`
  only once you turn on its Remote Control.
- The sidebar stays flat with hosts: their projects follow yours, each
  tagged with its host's name, so the same repository on two machines
  sits side by side. A host has a row of its own only while it needs
  one, as when it can't be reached or has no sessions, and its menu is in
  its projects'. Each host wears a color, picked from its name or set
  with `color=`, on its tag and its name in a pane's header. With hosts,
  Open Project lists any machine's folders in Kero, with a switch
  between them.
- The server build of Kero runs kerod and the CLI on Linux, macOS and
  Windows with no app, display or GTK: `curl -fsSL
  https://github.com/egoist/kero/releases/latest/download/install-server.sh
  | sh`, or on Windows `irm .../install-server.ps1 | iex`. The app offers
  to install it on a host that has no Kero, and to update it to the app's
  version, signed as the app's updates are. Windows hosts are reached
  over OpenSSH, whose shell may be cmd or PowerShell.
- `kero -H <host>` and `$KERO_HOST` run commands on a host's sessions; `kero
  hosts` adds, checks and installs hosts; `kero clients` lists who is
  connected to kerod; `kero daemon install-service` runs kerod as a
  systemd user service, a launchd agent or a Task Scheduler task, and
  `kero daemon serve` in the foreground.
- kerod's socket is its user's from the moment it is made, and kerod
  refuses connections of other users' processes. The login shell is
  looked up through NSS, so LDAP and SSSD accounts get theirs.

## 2.0.11

- The changes panel no longer jumps to the bottom of the list the first
  time a long file's diff scrolls into view, and the header of the file at
  the top of the list stays there as a file is folded, rather than
  vanishing for a moment. Only the diffs in view are built, so a long list
  of changes scrolls as quickly as a short one.
- On Windows 11 24H2 and later, clearing a pane clears the console's screen
  too, so PowerShell's inline predictions no longer draw on the line the
  prompt was on before.

## 2.0.10

- Each pane's title shows the branch it works on and the lines its changes
  add and remove since the last commit, `fix-login +40 −2`, and a merge or
  rebase in progress; click it to open the changes panel. A session on a
  branch other than the repository's default shows that branch in the
  sidebar, and its tooltip how far it is ahead of or behind its upstream
  and how many files changed.
- The changes panel (Option-Command-G, Ctrl+Shift+G on Windows and Linux)
  lists the files a session changed since its agent's last turn, since the
  last commit, or since the branch left the default one, each with its diff
  below it, which follows the file as it changes. Fold a file, resize the
  panel, switch between unified and side-by-side diffs, and in Last Turn
  revert a change or mark it kept.
- `kero diff` prints a pane's changes as `git diff` does, untracked files
  included; `--turn` and `--branch` choose what to compare against. `kero
  status --json` and `kero ls --json` include each pane's branch and
  changes.
- Sessions in a worktree outside its repository join the repository's
  project instead of starting one of their own.
- `git-status = false` stops Kero running git in your repositories, and
  `diff-layout` keeps the changes panel's diffs unified or side by side.

## 2.0.9

- Only agents that show their work with a progress bar, as Kiro and
  Qwen, turn their pane working by it: Neovim's language-server progress
  no longer marks its pane as working.

## 2.0.8

- Agents no longer rename the session they start in: an unnamed session
  keeps showing its agent's own title, as "Duplicate spinner in pane
  header", not a name in words joined by dashes.
- Files dropped on a pane paste their paths quoted for the program's
  shell, newlines and PowerShell's included.
- Find in a pane highlights a match that wraps in from above the view.
- A pane's scrollback stays whole as it reaches its limit, and a restored
  pane keeps the blank rows at the bottom of its screen.

## 2.0.7

- A split pane's title leads with its program's logo: Claude Code's,
  Codex's and other agents', Node.js's for a script node runs, as vite,
  and those of bun, deno, python, vim, git and docker; a shell's is a
  bolder terminal icon.
- A split pane shows its status once, by its title, not again in the
  chip beside it.
- An unnamed session takes its name from the program in the pane you're
  in, else in the one that most needs you; `session-name` chooses
  between these and the first pane's folder.
- Clear Scrollback in a pane's context menu clears as Cmd+K does, the
  screen too, and works on a full-screen program's.

## 2.0.6

- Images programs show appear in their panes, as grok's preview of a
  pasted image, through the Kitty graphics protocol, as in Ghostty.
- Command-hovering an image's path in a pane previews the image.
- Files dropped on a pane paste their paths, escaped for the shell, as in
  Ghostty: an agent takes a dropped image as a file it attaches.
- The mouse lands where it points in programs that take it in pixels:
  Claude Code's "Jump to bottom" lights up and takes a click, and dragging
  selects its text again.
- Programs asking the terminal's colors get the theme's: Copilot CLI's
  input box is light on a light theme. Colors a program sets for the
  terminal show, and programs that follow the appearance, as Claude Code
  and Copilot CLI, change with it when it goes from light to dark.
- Box drawing and blocks keep their colors under `minimum-contrast`, and
  only rows a program fills extend into a pane's padding, as in Ghostty:
  Copilot CLI's input box and tabs draw as they should.
- A name an agent gave its session with `kero rename` goes when a new
  conversation starts in the session's first pane.
- After updating, Kero asks to restart kerod, whose sessions restore as
  after a restart of the Mac.

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
