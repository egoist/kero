---
title: Changes
description: See a session's git branch and what its agent changed, file by file, beside its panes.
---

# Changes

When a session works in a git repository, Kero shows its branch and what changed, and lets you review an agent's work beside its panes.

## Branches at a glance

Each pane's title shows the branch it works on, with the lines its changes add and remove since the last commit: `fix-login +40 −2`. A merge or rebase in progress shows there too.

In the sidebar, a session on a branch other than the repository's default one, such as an agent's in a worktree of its own, shows that branch by its name. Hover a session for its branch, how far it is ahead of or behind its upstream, and how many files changed.

## The right sidebar

The sidebar at the right of the window has two tabs, **Changes** and **Files**. Show or hide it with the button at the top right of the window, or press <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>B</kbd>. Drag its edge to resize it. In a window too narrow for it beside your panes, it gets out of their way, and comes back as you widen the window; the button still shows it when you need it. A file you click in either tab opens in a card beside the panes, which you close with its <kbd>×</kbd> or leave with <kbd>Esc</kbd>.

## Changes

Click a pane's branch, or press <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>G</kbd>, to show the Changes tab with the diffs beside the panes. It lists the files that changed, in their folders, with what they add and remove, since one of:

- **Last Turn**: where the session's agent last started working, so you see what it did in its latest turn, and nothing that changed before it. Kero takes a snapshot of the worktree as the agent starts, without touching your index or files.
- **Uncommitted**: the last commit, untracked files included.
- **Branch**: where the branch left the repository's default branch, as a pull request would show it.

Click a file in the tab to show the diffs, scrolled to its own. Each file shows with its diff right below it, one after another, and the diffs follow the files while the agent keeps editing them. The file at the top of the diffs is highlighted in the tab. Scrolled into a long diff, its file's name stays at the top. Click a file's name to fold its diff away, or to unfold it: a binary file and one with very many changed lines start folded. **Collapse All** folds them all. Drag the gap between the panes and the diffs to resize them.

Diffs show unified while their card is narrow and side by side once it's wide. The button at the top of the diffs switches between the two, which the `diff-layout` setting keeps.

### Reviewing a turn

In **Last Turn**, hover a change for two buttons:

- **Revert** puts the old lines back in the file.
- **Keep** marks the change as reviewed, and hides it.

Revert works only while no agent in the session is working, so it never races an agent's edits, and only on a file that's still as the diff shows it. A file that changed meanwhile shows anew instead.

## Files

Press <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>E</kbd> for the Files tab: the folder of the pane you're in, its whole worktree in a git repository. Click a folder to unfold it, and a file to open it beside the panes, where you can find (<kbd>⌘</kbd> <kbd>F</kbd>) in it and edit it. The file follows its changes while you read it. What git ignores shows faded, and `.git` doesn't show.

The buttons above the tree make a new file or folder at its top, and a file's or folder's menu (right-click) makes one in its folder, renames it, or deletes it. Type the name where it will show, and press <kbd>Return</kbd>: a name like `docs/notes.md` makes the folders in it too, and a new file opens beside the panes. Delete asks first, and moves what you delete to the Trash. On a remote host, which has no Trash to move it to, it's deleted for good.

## Editing

A file you open from Files, and the new side of a diff in Changes, edit as in VS Code or Zed. Press <kbd>⌘</kbd> <kbd>S</kbd> to save the file you're in. Until you do, a dot takes the place of the card's <kbd>×</kbd>, and of a diff's file name. Closing the card, or opening another file in its place, asks whether to save your changes first. Quitting Kero doesn't: your unsaved changes are still there, unsaved, when you open it again, with the files they're in.

While you haven't changed a file, it follows its changes on disk. Once you have, your version stays, and if an agent or another program changed the file meanwhile, saving asks whether to overwrite it or to discard your changes for the file as it is now.

<a id="sessions-in-their-own-worktree"></a>

## Sessions in their own worktree

Agents working side by side in one checkout trip over each other's changes. **Session › New Session in Worktree…** (<kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>T</kbd>) asks for a branch name, then starts a session in a git worktree of its own: a folder checking out that new branch, from the repository's default branch.

- The worktree goes in `.kero/worktrees/<branch>` inside the repository, which Kero ignores through `.git/info/exclude`, not your `.gitignore`. Set `worktree-dir` to put worktrees elsewhere.
- Set `worktree-base = current` to branch from the session you're in instead of the default branch.
- The session joins the repository's project, and the sidebar shows its branch.

Closing the session asks whether its worktree goes too:

- **Nothing uncommitted:** Remove Worktree is the default. The branch goes with it once it's merged; otherwise it stays, with its commits.
- **Uncommitted changes:** Kero says how many files would be lost, and Keep Worktree is the default.
- **Another session works in the worktree:** it stays, and Kero doesn't ask.

From the command line:

```sh
kero new --worktree fix-login -- claude   # a session on a new branch, in its own worktree
kero new --worktree fix-login --base dev  # branch from dev
kero close fix-login --remove-worktree    # close it and remove the worktree
kero close fix-login --remove-worktree --force   # even with uncommitted changes
```

## From the command line

`kero diff` prints a pane's changes as `git diff` does, untracked files included:

```sh
kero diff                       # this pane's uncommitted changes
kero diff --turn                # what its agent changed in its last turn
kero diff review --branch       # the review session's changes since the default branch
kero diff src/auth              # just these paths
```

`kero status --json` and `kero ls --json` include each pane's branch and changes as `git`.

## Turning it off

Set `git-status = false`, or turn off **Show git status** in Settings, to stop Kero running git in your repositories.
