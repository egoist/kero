# Plan: git in Kero

Status: future plan, not started. Written 2026-10-21, after 2.0.9.

## Goal

Answer, at a glance, the two questions you have about an agent's session:
**where is it working, and what has it changed?** Then make the common next
step one click away.

Kero is a terminal for supervising coding agents, so git in Kero is
read-mostly. Not goals: committing, staging, rebasing or pushing from Kero's
own UI. The agents do those, and lazygit or tig do them better in a pane.

## Where we start

kerod already knows most of what's needed:

- Each pane has its shell's directory (`Pane.Dir`), and its foreground
  program's when it differs (`Pane.ProcessDir`), as an agent's that went into
  a worktree (`internal/daemon/session.go`). Both are refreshed at most every
  1.5s.
- kerod sees each pane's status change, so it knows when an agent starts
  working and when it stops.
- Projects are folders. A new session joins the project whose directory holds
  it, or starts one at its repository's root (`projectFor` and `repoRoot` in
  `internal/daemon/daemon.go`).
- `proto.State` goes to clients whole on every change, and new optional
  fields don't need a `proto.Version` bump.

What's missing, or wrong:

- **Nothing reads git.** The only git awareness is `repoRoot` looking for a
  `.git` entry.
- **`repoRoot` misread linked worktrees** (fixed since; see Phase 3). In a
  worktree, `.git` is a file, so `os.Stat` succeeded and the worktree's own
  root counted as a repository's. A worktree inside its repository, such as
  `.claude/worktrees/x`, still landed in the right project, because
  `projectFor` matches the existing project's directory first. A worktree
  elsewhere became a project of its own in the sidebar.
- **No diff view in the app yet,** but MyGo has one: `editor.DiffView` in
  `github.com/egoist/mygo/ui/editor` (MyGo's `docs/ui/diff-viewer.md`). It
  compares two texts as git's histogram diff does, side by side or unified,
  with changed words highlighted, unchanged lines collapsed and expandable,
  and syntax highlighting from the code editor. It can also edit the new side,
  revert or keep a hunk, attach comments under lines, and show a bare
  `git diff` patch (`editor.ParsePatch`, `DiffState.SetPatch`).

## Principles

- **kerod owns the data.** It runs git and puts the results in `proto.State`,
  so the app, `kero status --json` and the agent skill all see the same thing,
  and it carries over to remote hosts (`plans/remote-servers.md`) for free.
- **Run the user's `git`,** not go-git. It honours their config, fsmonitor,
  `core.untrackedCache` and credentials, and go-git's status is slow on large
  repositories.
- **Never get in an agent's way.** Every command kerod runs takes
  `--no-optional-locks`, so a background `git status` never holds
  `index.lock` while an agent commits. kerod never writes to the repository's
  index, and writes to the working tree only when the user reverts a change
  in the panel while no agent is working there (Phase 2).
- **Quiet by default.** The sidebar row stays as it is unless git has
  something worth saying.

## Phase 1: branch and changes on every session

### kerod

- A `GitInfo` per pane, an optional field on `proto.Pane`:

  ```go
  type GitInfo struct {
  	Root     string `json:"root"`               // the worktree's top level
  	Common   string `json:"common"`             // --git-common-dir: one per repository
  	Branch   string `json:"branch,omitempty"`   // "" when detached
  	Head     string `json:"head"`               // short sha
  	Upstream string `json:"upstream,omitempty"`
  	Ahead    int    `json:"ahead,omitempty"`
  	Behind   int    `json:"behind,omitempty"`
  	Added    int    `json:"added,omitempty"`    // lines, working tree against HEAD
  	Removed  int    `json:"removed,omitempty"`
  	Files    int    `json:"files,omitempty"`    // changed, untracked included
  	State    string `json:"state,omitempty"`    // "", "merge", "rebase", "cherry-pick"
  }
  ```

  It describes the pane's working directory: `ProcessDir` when set, else
  `Dir`.
- **One cache per worktree root,** shared by every pane in it. Several
  sessions often sit in one checkout.
- **What runs:**
  - `git status --porcelain=v2 --branch -z` gives the branch, upstream,
    ahead/behind and changed files.
  - `git diff --numstat HEAD` gives the line counts.
  - Both take `--no-optional-locks`, a timeout (2s), and a niced process.
  - On Windows, `git.exe` starts with `CREATE_NO_WINDOW`. kerod has no
    console, so without it every refresh would flash one.
- **When it refreshes,** never on a fast poll:
  - when a pane's directory changes;
  - when a pane's agent goes from working to idle, done or blocked, which is
    when the user looks;
  - when a client views the session;
  - when `HEAD`, `index` or `refs/` change in the git directory (a file
    watcher on those, not on the working tree);
  - otherwise at most every 30s while a pane in the worktree is working.

  Refreshes for one worktree are debounced to one at a time.
- **Backing off:** a worktree whose status runs past the timeout twice, or
  that lies on a network mount, stops refreshing automatically. The tooltip
  says so, and selecting the session retries once.
- **Configuration:** `git-status = true|false` (default `true`) in
  `~/.config/kero/config`. Tests set `KERO_CONFIG` as usual.

### App

- **Session row:** unchanged (name, time, status icon), except for a small,
  muted branch label after the name when the session's branch differs from
  the project's main checkout. "This agent is on `fix-login`" is the case
  worth flagging; "this session is on `main`, like every other" isn't.
- **Tooltip:** adds the branch, ahead/behind and `+42 −7 in 5 files` under
  the directory it already shows.
- **Title bar:** the selected session's branch and diffstat. Clicking it opens
  the changes panel (Phase 2).
- **Project header:** the main checkout's branch, muted.
- A merge or rebase in progress shows in the tooltip and title bar, as
  `rebasing 3/7`.
- Icons come from Framework7 (branch, plus/minus), as elsewhere.

### CLI

- `kero status --json` and `kero ls --json` include `git` per pane.
- `kero status` prints the branch and diffstat on its directory line.

## Phase 2: the changes panel

A drawer on the right of the selected session (⌘⇧G, and the title bar's
branch). It lists changed files, and clicking one shows its diff below or in
place of the list.

### Three tabs

| Tab | Diff of | What it's for |
| --- | --- | --- |
| **Last turn** | the tree when the agent last started working, against the working tree now | "What did it just do?" |
| **Uncommitted** | `HEAD` against the working tree, untracked files included | "What's not committed?" |
| **Branch** | the merge-base with the default branch, against the working tree | "What would the PR contain?" |

The panel opens on **Last turn** when the session's lead pane runs an agent,
and on **Uncommitted** otherwise.

### Snapshots for "Last turn"

This is what no other terminal can offer, because no other terminal knows
when an agent's turn starts.

- When a pane with an agent goes from idle to working, kerod writes a tree of
  the working tree without touching the user's index:

  ```sh
  GIT_INDEX_FILE=$tmp git add -A
  GIT_INDEX_FILE=$tmp git write-tree
  ```

  `$tmp` is seeded by copying the real index first, so `git add -A` only
  hashes what changed, and `.gitignore` applies as it does for the user.
- The tree's id is kept on the pane (in kerod's store, so it survives a
  restart), with the time. Only the latest is kept per pane. The objects are
  loose and unreferenced, so `git gc` prunes them after its grace period
  (two weeks by default), long after they're needed.
- The diff is `git diff <tree>` against the working tree, again through a
  temporary index for untracked files.
- **Cost:** a snapshot runs once per turn, not per frame. On a repository
  where it takes over the timeout, kerod skips snapshots for that worktree,
  and the tab says why.

### Diff view

MyGo's `editor.DiffView`, one `editor.DiffState` per open file.

- **Fed whole texts, not patches.** kerod sends the file's old text (the
  blob in the tab's base: the turn's tree, `HEAD` or the merge-base) and its
  text now. With both, the viewer highlights changed words, lets the user
  expand the lines between changes, and can revert a hunk. `editor.LanguageFor`
  picks the highlighting from the path.
- **Patches for the large.** Above a size limit (1 MB, say), kerod sends the
  file's patch from `git diff` instead, shown with `SetPatch`: the hunks under
  their headers, no expanding. Binary files show a summary.
- **It follows the agent.** While a diff is open, kerod's watcher (Phase 1)
  tells the app when the file changes, and the app replaces `New`'s text. The
  viewer diffs again only around the edit, so a working agent's changes show
  as it makes them.
- **Layout:** unified (`DiffUnified`) while the drawer is narrow, side by side
  (`DiffSplit`) once it's widened past a width, unless the user picked one.
  `diff-layout = auto|unified|split` sets it.
- **Navigation:** the file list says "2 of 5" for the current change (`Hunks`,
  `CurrentHunk`), and ⌘F8 / ⇧⌘F8 step through changes, as the viewer's keys
  do. ⌘-click a line to open the file there in `$EDITOR`, as ⌘-clicking a path
  in a pane does.
- **Looks:** the `Theme` comes from the app's palette, light and dark. Its
  `Added`, `Deleted` and `Modified` take the terminal theme's green, red and
  yellow, so the diff matches the pane beside it. Separators and hunk actions
  are Kero's own (`RenderSeparator`, `RenderHunkActions`): no borders in light
  mode, Framework7 icons.
- **Read-only to start** (`Editable` off). Editing in the panel would make it
  an editor, and `$EDITOR` is one click away.

### Reviewing a turn, hunk by hunk

The viewer's `HunkActions` give each change Revert and Keep, which suit the
**Last turn** tab: review what the agent just did, one change at a time.

- **Revert** puts the old lines back. kerod writes the file, and only when:
  - no agent in the worktree is working, since writing under a working agent
    races its edits;
  - the file on disk is still the text the viewer showed (compared by hash),
    or the revert is refused and the diff reloads.
- **Keep** marks the change as seen (`Accept`): it leaves the diff, and the
  file's entry shows how many changes are left. Kept changes are kept in the
  app's memory for that turn only. The next turn's snapshot starts the
  review afresh anyway.
- **Uncommitted** and **Branch** show no hunk actions. Reverting there means
  undoing commits or the user's own edits, which is git's job, not the
  panel's.

### Protocol

- `git.changes {pane, against: "turn"|"head"|"base"}` returns the changed
  files, each with its status (added, modified, deleted, renamed) and line
  counts. It's fetched when the panel opens or the tab changes, never put in
  `proto.State`.
- `git.file {pane, against, path}` returns the file's old and new text, or
  its patch when large, or that it's binary.
- `git.revert {pane, path, hash, text}` writes `text` to the file when its
  content still hashes to `hash` and no agent in the worktree is working.
- `kero diff <target> [--turn|--base] [path]` prints the changes as `git diff`
  would, for agents and scripts.

## Phase 3: sessions in their own worktree

### Starting one

- **New Session in Worktree… (⌘⌥T),** and `kero new --worktree <branch>`.
  Kero asks for a branch name, suggesting one from the session's name.
- kerod runs `git worktree add -b <branch> <path> <base>`:
  - `<base>` is the default branch's tip, or the current branch, as a setting
    picks (`worktree-base = default|current`).
  - `<path>` is `<repo>/.kero/worktrees/<branch>` by default, so worktrees
    stay inside their project. Setting `worktree-dir` moves them elsewhere.
    Kero adds `.kero/` to the repository's `.git/info/exclude`, not to its
    `.gitignore`.
- The session records `Worktree{Path, Branch, Base}` and starts in it. The
  sidebar shows it under its repository's project with its branch label.

### Closing one

When a worktree session closes, kerod checks the worktree before anything
else:

- **Clean, and its commits are on the base branch or pushed:** "Remove the
  worktree too?" with Remove as the default. The branch is deleted only if
  it's merged.
- **Uncommitted changes, or commits not pushed anywhere:** say exactly what
  would be lost (`3 files changed, 2 commits not pushed`), and offer Keep
  Worktree (default) or Remove Anyway.
- Another session still in the worktree: close this one and keep the
  worktree, without asking.

`kero close --remove-worktree` does the same from the CLI, and refuses
without `--force` where the dialog would warn.

### Fixing `repoRoot`

Done. When `.git` is a file, `repoRoot` follows it to the worktree's git
directory, then that directory's `commondir` to the repository's. When that
is a `.git` directory, its parent is the main checkout. It reads the two
files rather than running `git`, so it holds `d.mu` for no subprocess and
opens no console window on Windows. A submodule, or a bare repository's
worktree, stays a root of its own.

## Phase 4: a few actions

In the changes panel's menu, the title bar's branch menu, and `kero do`:

- **Copy Branch Name.**
- **Open Pull Request:** `gh pr view --web` when `gh` is installed and a PR
  exists; otherwise the forge's compare page, from the upstream's URL
  (GitHub, GitLab and Bitbucket formats).
- **Open in lazygit / tig:** a split pane running the first one installed, in
  the session's worktree.
- **Ask the Agent to Commit / Open a PR:** types a prompt into the agent's
  pane, through what `kero prompt` uses, and lets the agent do it its way. The
  prompt text is a setting.
- **Comment on lines, then send the comments to the agent,** as a code review
  does:
  - The diff's gutter button (`OnGutterButton`) adds a comment under a line,
    and dragging over line numbers (`LineSelection`) comments on a range.
    Comments show under their lines (`Annotations`, `RenderAnnotation`).
  - **Send to Agent** types them into the agent's pane as one prompt, each as
    `path:line: comment`, through what `kero prompt` uses.
  - Comments live in the app until sent or discarded. They're dropped when
    their file changes under them.

Nothing here writes to the repository from Kero itself, except Phase 3's
worktree add and remove. The only other write is Phase 2's Revert.

## Security notes

- **Branch names, commit subjects and file paths come from the repository,**
  which may be untrusted. They're shown as plain text, never as markup, and
  never typed into a pane.
- **kerod runs `git` in directories the user's shells are already in,** as
  the user. Repository config can run programs (`core.fsmonitor`, filters,
  `diff.external`), as it does when the user's own prompt runs `git status`.
  - Pass `-c core.fsmonitor=false` only if a hook turns out to be slow or
    hostile in practice; dropping it costs speed on large repositories.
  - Always pass `--no-ext-diff` and `--no-textconv` to `git diff`, so a
    repository can't run a program just by being looked at in the panel.
- **Snapshots stay local:** they are loose objects in the repository, never
  referenced, never pushed.
- **`git.file` and `git.revert` take a path from the client.** kerod accepts
  it only when git lists it as changed in that tab, and only inside the pane's
  worktree once symbolic links are resolved, so neither reads nor writes any
  other file.

## Order and rough size

1. **`repoRoot` fix:** done.
2. **Phase 1, branch and changes:** small to medium. kerod's watcher and
   cache, the proto field, the row label, tooltip, title bar and CLI.
3. **Phase 2, changes panel:** medium. MyGo's `editor.DiffView` does the
   diffing and drawing. The work is the drawer and file list, the snapshots,
   the `git.*` RPCs, live updates, and guarding reverts.
4. **Phase 3, worktree sessions:** medium. Creating, the close dialog, and
   the settings.
5. **Phase 4, actions:** small to medium. Mostly the review comments; the
   viewer already has the gutter button and the room under lines.

## Open questions

- **Which branch is "the project's main checkout"** when the user works in
  several worktrees and none on the default branch? Probably the default
  branch's name (`origin/HEAD`), not whatever the root checkout happens to be
  on.
- **Should the row show the diffstat,** not only the branch? It's what you'd
  scan for across ten agents, but the row is already full. Try it behind a
  setting with real sessions before deciding.
- **Does the Last turn snapshot need to be per turn, or per agent
  conversation?** Per turn answers "what did it just do"; per conversation
  answers "what has this task done". Branch covers much of the second.
- **How do Windows paths and `git.exe` behave** with `GIT_INDEX_FILE` and the
  watcher? kerod runs on Windows, so check there before Phase 2.
- **Remote hosts:** everything runs in kerod, so it should just work there.
  Check that opening a file from the diff resolves on the host, as
  `plans/remote-servers.md` requires for ⌘-clicked paths.
- **Should Keep outlive the app's memory?** Persisting it means a baseline
  per file in kerod beside the turn's tree. Try the review with in-memory Keep
  first.
- **Agents that already make worktrees,** such as Claude Code under
  `.claude/worktrees`: should Kero offer to remove those on close too, or only
  its own?
