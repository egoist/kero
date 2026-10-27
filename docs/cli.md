---
title: Command Line
description: Drive Kero sessions and panes from a shell or a script with the kero CLI.
---

# Command Line

The `kero` command drives sessions from any shell: yours, a script's or an agent's. Install it with **Kero › Install Command Line Tool…**.

## Targets

Most commands take a **target**: a session or a pane. A target can be:

- an id, or any unique prefix of it
- a session's name
- a session, which stands for its focused pane

Inside Kero, `$KERO_SESSION` and `$KERO_PANE` name the session and pane a command runs in, and they're the default target.

## Sessions and panes

```sh
kero ls                          # every session and its panes
kero new -n api -d ~/code/api    # start a session, print its id
kero new -- npm run dev          # start one running a command
kero split --down -- npm test    # a pane beside this one
kero split --url localhost:3000  # a browser pane showing a page
kero rename api backend          # rename a session
kero focus backend               # show it in the app
kero close backend               # end a session (or, given a pane, the pane)
kero close fix-login --remove-worktree   # and remove its own worktree
kero restart <pane>              # start an exited pane's shell again
```

`kero new` options:

| Flag                        | Meaning                                         |
| --------------------------- | ----------------------------------------------- |
| `-p`, `--project <name\|id>` | The project to put it in (default: by directory) |
| `-n`, `--name <name>`       | Name the session                                |
| `-d`, `--dir <dir>`         | Start it there (default: the current directory) |
| `-f`, `--focus`             | Show it in the app                              |
| `-w`, `--wait`              | Wait for its command to end, and exit with its status |
| `-u`, `--url <url>`         | Open a browser showing the page instead of a shell |
| `--worktree <branch>`       | Start it in a git worktree of its own, on a new branch ([more](./changes.md#sessions-in-their-own-worktree)) |
| `--base <ref>`              | The branch the worktree's starts from (default: the default branch) |

## Typing and reading

```sh
kero send api "npm run migrate" --enter   # type text, then press Enter
kero send api -e 'y\n'                    # interpret \n \r \t \e \xHH escapes
kero key api ctrl+c                       # press keys
kero read api -n 40                       # the last 40 lines on screen
kero read api -a                          # the screen with its scrollback
```

`kero key` understands `enter`, `tab`, `escape`, `up`, `down`, `left`, `right`, `backspace`, and modifiers such as `ctrl+c` or `ctrl+d`.

## Waiting

```sh
kero wait api                             # until it stops working
kero wait api --for waiting,error --timeout 10m
kero prompt review "summarize the diff"   # send + Enter, wait, print the screen
```

`kero wait` prints the pane's status when it returns. `kero prompt` sends text and Enter, waits until the pane stops working, then prints its screen. It's the quickest way to ask another agent something.

### Waiting for a command

A command such as `make test` doesn't show as *working*, so to wait for one to finish, start it with `--wait`. `kero` then exits with the command's own status:

```sh
if kero split --down --wait -- make test; then
  echo "tests passed"
fi
```

`kero wait --exit` does the same for a pane that is already running a command it started with:

```sh
pane=$(kero split --down -- go test ./...)
# … do other things …
kero wait "$pane" --exit --timeout 10m
echo "go test exited with $?"
```

The pane stays open after the command, with its output, so you can `kero read` it. Waiting for a command doesn't work with `cmd` as the shell, which can't tell when one ends.

## Watching

`kero events` prints what happens to sessions and panes as it happens, one line per event, until you stop it. A script can follow every agent at once this way, without polling `kero status`.

```sh
kero events                               # every session
kero events api                           # one session, or one pane
kero events -p kero                       # one project's sessions
kero events --for waiting,error           # only panes going to these statuses
kero events --json | jq -r .name          # one JSON object per line
kero events --for waiting --once          # exit after the first one
```

```
12:04:31  api x78n9ss  working → waiting  Allow Bash: rm -rf dist?
12:04:40  api  renamed api → backend
```

| Event | When | Fields |
| --- | --- | --- |
| `pane.status` | A pane's status changes | `pane`, `from`, `to`, `message`, `kind`, `agent`; `exitCode` when it goes to exited |
| `command.exited` | The command a pane started with ends, and its shell goes on | `pane`, `exitCode` |
| `pane.created`, `pane.closed` | A pane starts or closes | `pane` |
| `session.created`, `session.closed` | A session starts or closes | |
| `session.renamed` | A session's name changes | `from`, `to` |
| `session.moved` | A session moves to another project | `from`, `to`, the projects' ids |
| `notice` | A program in a session sends a desktop notification | `pane`, `title`, `body` |

With `--json`, every event also has `event`, `time` (unix ms), `session`, `project` and `name`, the session's name as the sidebar shows it.

`kero events` reports what changes from now on: for what is there already, use `kero ls --json`. Given a target, it stops when the target closes. `--once` exits after the first event that matches, with `1` if the target closes first or `--timeout` passes. kerod sends its state when it settles, so a status that lasts only a moment, such as a blip of working, may not show.

## Browsing

`kero browser` drives a browser pane's page the way `kero send` and `kero read` drive a terminal: it clicks, types, reads the page and takes pictures of it. Its target is a browser pane, or a session, for its browser. With no target, it drives the browser of the session it runs in.

```sh
kero split --url localhost:3000            # open the page, print the pane's id
kero browser open localhost:3000/todos     # go to a page, and wait for it to load
kero browser snapshot                      # what's on the page, each element with a ref
kero browser type --ref e3 "Buy milk" --enter
kero browser click --ref e5
kero browser wait '.todo-list li'          # until an element shows
kero browser wait --text "1 item left"     # until the text shows
kero browser text                          # the page's text
kero browser text h1                       # an element's
kero browser click 'button[type=submit]'
kero browser screenshot -o page.png
kero browser eval 'document.title'
```

| Command                         | What it does |
| ------------------------------- | ------------ |
| `open <url>`                    | Go to a page, and wait for it to load |
| `back`, `forward`, `reload`     | Go back or forward, or load the page again, and wait for it |
| `text [selector]`               | Print the page's visible text, or the first matching element's |
| `html [selector]`               | Print the page's HTML, or the element's |
| `snapshot [selector]`           | Print what the page shows as a tree of roles and names (`button "Add"`, `textbox "Email"`), each element with a ref, or the element's part of it |
| `click <selector>`              | Click the element, as a mouse does |
| `type <selector> <text…>`       | Type text into a field, in place of what it holds; `--enter` presses Enter after it, which submits its form |
| `wait [selector] [--text text]` | Wait until the element shows, or the text does; with neither, until the page loads |
| `eval <js…>`                    | Run JavaScript in the page and print its value: a string as it is, anything else as JSON |
| `screenshot [-o file.png]`      | Save a picture of the page, and print where; `-o -` writes it to stdout |
| `cookies save [file]`           | Save the browser's cookies to a file, or print them; `--domain` keeps a site's |
| `cookies load <file>`           | Load cookies from a file; `--domain` loads a site's |

Selectors are CSS selectors; quote them in the shell. Anywhere a command takes a selector, `--ref` takes a ref from `snapshot` in its place: `kero browser click --ref e5`. An element keeps its ref until the page goes to another, and a ref whose element is gone fails rather than guess another. Commands that need an element wait for it to appear, and `--timeout` (default `10s`) sets how long they, and the page loads, may take. `type` and `eval` take `-` for text from stdin.

Clicking and typing send the events a real mouse and keyboard would, so pages built with React and other frameworks see them. Every command works on any browser pane, shown or not: a screenshot of a pane not on screen takes no focus from what you are doing.

Browser panes share their cookies, and keep them when Kero restarts. `cookies` saves them in Playwright's storage state, as JSON, or for a file named `.txt`, as a Netscape `cookies.txt`, which curl and browser extensions write; `load` reads either. Cookies sign you in to sites: share their file only with what you'd trust with your logins. They stay on this Mac, so programs on a host can't save or load them.

Like `kero do`, `kero browser` needs Remote Control, in **Settings › Agents**, and the app to be open.

## Past conversations

```sh
kero history                     # agents' conversations panes ran, the last to run first
kero history -p kero -n 50       # one project's, up to 50
kero history login --json        # those matching "login", as JSON
kero resume 13b9                 # resume one: its id, a prefix of it, or its name
kero resume fix-login -f         # and show it in the app
```

`kero resume` starts a session that resumes the conversation, in its directory and project, and prints the session's id. A conversation a pane still runs gives that session instead. See [Past conversations](./sessions.md#past-conversations).

## Status

```sh
kero status api --json                    # status, program, directory
kero report working "Running migrations"  # report your own status
kero notify "Need your input"             # flag this pane as needing you
```

See [Status & Notifications](./status.md) for the states.

## Changes

```sh
kero diff                                 # the pane's uncommitted changes, as git diff prints them
kero diff --turn                          # what its agent changed in its last turn
kero diff review --branch                 # since the default branch
```

See [Changes](./changes.md).

## Configuration and setup

```sh
kero config path                 # where the configuration file is
kero config show                 # every key with its value
kero config show --defaults      # every key as kero comes
kero config edit                 # open it in $EDITOR
kero config check                # report unknown keys and bad values
kero projects                    # list projects
kero skill setup                 # teach coding agents to use kero
kero daemon status|stop|restart  # manage kerod
kero daemon install-service      # run kerod with the machine (systemd, launchd)
kero daemon serve                # run kerod in the foreground, for a service manager
kero clients                     # who is connected to kerod
```

## Other machines

`-H <host>` before the command, or `$KERO_HOST`, points a command that acts on sessions at kerod on another machine: a host you added, or an address such as `me@devbox` or `wsl://Ubuntu`. See [Remote Hosts](./remote.md).

```sh
kero hosts                       # the hosts you added
kero hosts add devbox me@devbox  # add one, which the app shows too
kero hosts check devbox          # connect, and say how it went
kero hosts install devbox        # install Kero there, over SSH
kero -H devbox ls
kero -H devbox new -n review -- claude
kero -H devbox daemon update     # update Kero there to this one's version
```

Inside a pane, `kero` talks to the kerod of the machine the pane runs on, wherever the app is.

## Running app actions

`kero do` runs any of the app's actions, the same ones as its menus. It needs Remote Control, which is on by default in **Settings › Agents**.

```sh
kero actions                     # list them
kero do pane.split.right
kero do pane.browser url=localhost:3000
kero do sidebar.toggle
```

## Exit status

| Code | Meaning                              |
| ---- | ------------------------------------ |
| `0`  | OK                                   |
| `1`  | Failed                               |
| `2`  | Bad usage                            |
| `3`  | No such target, or an ambiguous one  |
| `4`  | kerod is unreachable                 |

Commands that wait for a program, `kero wait --exit` and `--wait`, exit with the program's status instead, as does `kero wait` when the pane's shell exits with an error. A wait that times out exits with `1`.

Add `--json` to `ls`, `status` and `projects` for machine-readable output.
