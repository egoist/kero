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
kero rename api backend          # rename a session
kero focus backend               # show it in the app
kero close backend               # end a session (or, given a pane, the pane)
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
```

## Running app actions

`kero do` runs any of the app's actions, the same ones as its menus. It needs Remote Control, which is on by default in **Settings › Agents**.

```sh
kero actions                     # list them
kero do pane.split.right
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
