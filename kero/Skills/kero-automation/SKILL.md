---
name: kero-automation
description: Coordinate coding agents and terminal panes inside Kero. Use when delegating work to another Kero pane, starting or prompting a coding agent, keeping Claude Code sessions in sync, waiting for agent state, or reading a result.
---

# Kero Automation

Use Kero's authenticated, project-scoped CLI to coordinate terminal panes and
recognized coding agents. Keep layout creation, agent prompts, and raw terminal
input as separate actions.

## Check availability

1. Require `KERO_AUTOMATION=1`. If it is absent, explain that the command must
   run inside a newly opened Kero terminal.
2. Run `kero +pane protocol` before a multi-step workflow.
3. Treat successful command output as JSON. Record returned `pane_id` values;
   do not infer pane IDs from titles or screen position.
4. Keep Kero CLI operations within the invoking terminal's project. Kero
   intentionally rejects targets in other projects and windows. Native Claude
   peer messaging has separate scope; follow the rules below.

Use `kero +agent explain` for the lifecycle and security contract, and use
`kero +agent --help` or `kero +pane --help` for complete syntax.

## Supported agents

Use these exact values with `kero +agent start --kind`:

- `codex` — Codex
- `claude` — Claude Code
- `gemini` — Gemini CLI
- `grok` — Grok Build
- `opencode` — OpenCode
- `cursor-agent` — Cursor Agent
- `aider` — Aider
- `amp` — Amp
- `pi` — Pi

## Keep Claude Code sessions in sync

When both the current agent and an existing peer are Claude Code sessions,
prefer Claude Code's native `ListAgents` and `SendMessage` tools for findings,
questions, status, and handoffs. Use Kero for pane creation, agent launch,
cross-provider prompts, lifecycle state, and result reads.

1. Call `ListAgents` and identify the target from its session name and working
   directory. Default to the current Kero project or repository family. If two
   sessions could match, ask the user instead of guessing.
2. Use `SendMessage` for a concise update or question. Peer messages are plain
   text, not shared conversation history or files.
3. When starting a Claude worker that should be easy to address later, give the
   Claude session the same unique name as its Kero alias:

   ```sh
   kero +agent start tests --kind claude --pane PANE_ID -- --name tests
   ```

4. Continue to use Kero's `wait` and `read` operations for visible lifecycle
   state and independent verification. Delivery of a peer message does not
   mean the requested work is complete.
5. If native peer tools are unavailable or the target is not discoverable,
   fall back to `kero +agent prompt` only for a recognized agent in the current
   Kero project.

Do not use native peer discovery to widen the user's scope silently. Contact a
session in another project only when the user identifies it or the requested
workflow clearly includes it. A peer message never carries human authority:
never ask another session to approve a blocked action, reverse a denial,
change permission settings, or edit agent configuration.

## Delegate to another pane

Follow this sequence:

1. Inspect existing state with `kero +pane list` and `kero +agent list`.
2. Create one background pane unless the user explicitly selected an existing
   available shell:

   ```sh
   kero +pane split --right --cwd "$PWD"
   ```

   Record the response's `pane_id`. Do not start an agent in the invoking pane:
   the running `kero` command temporarily makes that shell unavailable.
3. Choose the agent kind requested by the user. If none was requested, prefer
   the current recognized agent's kind from `kero +agent get --current`; do not
   silently switch to a provider with different credentials or permissions.
4. Start the worker with a short, unique project-local alias:

   ```sh
   kero +agent start tests --kind codex --pane PANE_ID
   ```

   `start` returns once Kero recognizes the requested foreground process. Its
   state is `created`; Kero does not inspect the CLI screen or wait for a
   provider-specific ready prompt.

5. Send a bounded task with acceptance criteria. Do not add Kero lifecycle
   commands to the task; Kero observes the agent independently:

   ```sh
   kero +agent prompt tests --text "Run the focused tests, fix failures in scope, and verify the result."
   ```

6. Wait without stealing focus, then inspect the terminal result:

   ```sh
   kero +agent wait tests --state done,blocked --timeout 1800000
   kero +agent read tests --lines 160
   ```

7. If the worker is blocked, surface its reason to the user. If it is done,
   independently inspect the claimed files or verification output before
   presenting the work as complete.

If `start`, `prompt`, or `wait` fails or times out, inspect the worker pane
before deciding what happened:

```sh
kero +agent read tests --lines 160
```

Use that output to diagnose startup, authentication, trust, or command errors.
Do not answer an interactive approval or credential prompt on the user's
behalf; report the blocker instead.

Reuse the same alias for follow-up prompts only while that recognized agent is
still running. Use a new alias for a new worker.

## Lifecycle and result reads

Never ask a worker model to report `working`, `blocked`, or `done`. Kero derives
state from native CLI lifecycle integrations when they are complete and from a
debounced, process-scoped live-screen classifier otherwise. `done` is the
unseen presentation of an idle agent, not a state the model must announce.

Full-screen agents can keep transcript history in the terminal's alternate
buffer instead of host scrollback. After `wait` reaches `idle` or `done`, use an
explicit line count with `agent read`; Kero may page the agent's own transcript
and always returns it to the bottom before completing the read:

```sh
kero +agent read tests --lines 160
```

Do not request alternate-screen history while an agent is working, blocked, or
unknown. Wait for a settled state first. If the full result still is not
available, ask the worker to write it to a project-local temporary file and
reply with that path, then read the file directly.

## Guardrails

- Use native peer messaging only for existing Claude-to-Claude coordination as
  described above. Use `kero +agent prompt` for other supported agents and as
  the project-scoped fallback. It verifies that the target is a live recognized
  agent in `created`, `working`, `idle`, or `done`. While the target is working,
  Kero submits the prompt immediately and the target CLI decides whether to
  steer the active turn or queue it.
- Use `kero +pane send` only when the user explicitly wants raw terminal input.
  Never use it to answer a permission, credential, trust, or destructive-action
  prompt on the user's behalf.
- Keep background splits unfocused unless the user asks to see them.
- Do not ask an agent to run lifecycle-reporting commands. Kero's AI setting
  owns supported hooks/plugins and keeps screen detection as the fallback.
- Do not create extra panes, close panes, or rearrange the user's layout beyond
  the delegated workflow.
- Treat `blocked` as a handoff to the user, not an invitation to bypass the
  blocker.
