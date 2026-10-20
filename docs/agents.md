---
title: Coding Agents
description: Teach Claude Code, Codex and other agents to run work beside themselves and report their progress in Kero.
---

# Coding Agents

Agents running in Kero can use the `kero` command like you do: start a dev server in a pane below them, hand a review to a second agent, wait for tests, and tell you when they're blocked.

## Install the skill

```sh
kero skill setup
```

This installs two things:

- A **skill** that teaches agents the CLI. Claude Code reads it from `~/.claude/skills/kero`; Codex, OpenCode and other agents from `~/.agents/skills/kero`.
- A **hook** that runs as an agent starts a session. It tells the agent which Kero session and pane it's in, so it doesn't spend time finding out, and has it name an unnamed session after its task, such as `fix-login-redirect`, so you don't have to. It also tells Kero the agent's own session, so that after kerod restarts, as after a reboot, the agent [picks up its conversation](./sessions.md#kerod).

The hook goes where each agent looks for one, for the agents you have installed:

| Agent       | Where the hook goes                                   |
| ----------- | ----------------------------------------------------- |
| Claude Code | A `SessionStart` hook in `~/.claude/settings.json`     |
| Codex       | A `SessionStart` hook in `~/.codex/hooks.json`         |
| Pi          | An extension, `~/.pi/agent/extensions/kero.ts`         |
| OpenCode    | A plugin, `~/.config/opencode/plugins/kero`            |

Kero follows `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `PI_CODING_AGENT_DIR` and `XDG_CONFIG_HOME` when they move an agent's files, and leaves the rest of each settings file as it was.

Pass `--agent` with `claude`, `codex`, `pi`, `opencode` or `vibe` to set up one agent only. The skill comes from your Kero binary, so run `kero skill setup` again after updating Kero. `kero skill status` tells you whether each part is current.

```sh
kero skill status    # what's installed, and whether it's current
kero skill show      # print the skill
kero skill remove    # uninstall the skill and the hooks
```

The hook works only in agent sessions started after setup, and agents may ask first:

- **Claude Code** runs hooks only in folders you trust.
- **Codex** asks you to approve a new hook: approve Kero's with `/hooks`.
- **OpenCode** loads plugins as its background service starts: run `opencode service restart` once, when no session is busy.

OpenCode runs an agent's commands in its background service rather than in the pane, so they don't have `KERO_SESSION` and `KERO_PANE`. Kero tells the agent its pane instead, for it to name as the target. For the same reason, `kero report` from an OpenCode agent doesn't reach its pane.

Outside Kero, the hook does nothing.

## What agents can do

Run something beside themselves:

```sh
kero split --down -- npm run dev
kero new -n review -- claude
```

Drive it and read the result:

```sh
kero prompt review "review the changes in src/auth"
kero wait tests --for idle,error --timeout 10m
kero read tests -n 60
```

Run tests beside themselves and read what failed:

```sh
pane=$(kero split --down -- go test ./...)
kero wait "$pane" --exit || kero read "$pane" -n 80
```

Tell you what's going on:

```sh
kero rename $KERO_SESSION fix-login-redirect
kero report working "Migrating the database" --progress 40
kero report blocked "Approve the production deploy?"
kero report done "Deployed to staging"
```

A `blocked` report turns the session to *waiting* and notifies you, so agents should use it only when they can't continue without you.

## Remote Control

With **Remote Control** on (the default, in **Settings › Agents**), agents can also drive the app itself: show a session with `kero focus`, or run menu actions with `kero do`. Turn it off with `remote-control = false` to keep agents to their own sessions.

## Environment

Every pane gets:

| Variable       | Value                          |
| -------------- | ------------------------------ |
| `KERO_SESSION` | The id of the pane's session   |
| `KERO_PANE`    | The id of the pane             |

Check `$KERO_PANE` to tell whether a script runs inside Kero.
