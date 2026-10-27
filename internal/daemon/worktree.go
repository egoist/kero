package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kero/internal/git"
	"kero/internal/proto"
	"kero/internal/settings"
)

// Sessions in a worktree of their own (plans/git.md, Phase 3): kerod adds
// a linked worktree on a new branch as such a session starts, and removes
// it as the session closes, when the user asks and nothing would be lost
// that they didn't agree to.

// worktreeDir is the folder kero puts a repository's worktrees in, by
// default: inside the repository, which its info/exclude ignores.
const worktreeDir = ".kero/worktrees"

// addWorktree makes a session's own worktree, of the repository holding
// dir, on branch from base ("" the default branch, "HEAD" dir's).
func (d *Daemon) addWorktree(dir, branch, base string) (*proto.Worktree, error) {
	if dir == "" {
		return nil, errors.New("a worktree needs a directory in a git repository")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	r, err := git.Open(ctx, dir)
	if err != nil {
		return nil, fmt.Errorf("%s is in no git repository", proto.ShortDir(dir))
	}
	main := r.Main()
	if main == "" {
		return nil, errors.New("kero makes worktrees of a repository with a main checkout, not a bare one's")
	}
	branch = strings.TrimSpace(branch)
	if err := git.CheckBranch(ctx, main, branch); err != nil {
		return nil, err
	}
	path := worktreePath(main, branch, settings.Load().WorktreeDir)
	if _, err := os.Lstat(path); err == nil {
		return nil, fmt.Errorf("%s is there already", proto.ShortDir(path))
	}
	from := ""
	if !r.HasBranch(branch) {
		switch base {
		case "":
			def := r.DefaultBranch()
			switch {
			case def == "":
				from = "HEAD"
			case r.HasBranch(def):
				from = def
			default:
				from = "origin/" + def
			}
		case "HEAD":
			// dir's own branch, by name when it has one, so that whether
			// the work is merged reads against it.
			if st, err := r.Status(ctx); err == nil && st.Branch != "" {
				from = st.Branch
			} else {
				from = "HEAD"
			}
		default:
			from = base
		}
	}
	if proto.Within(path, main) {
		if err := r.Exclude("/" + strings.SplitN(worktreeDir, "/", 2)[0] + "/"); err != nil {
			d.log.Printf("excluding %s: %v", worktreeDir, err)
		}
	}
	if err := r.AddWorktree(ctx, path, branch, from); err != nil {
		return nil, err
	}
	d.log.Printf("worktree %s added on %s from %q", path, branch, from)
	return &proto.Worktree{Path: path, Branch: branch, Base: from, Main: main}, nil
}

// worktreePath is where a worktree for branch goes: in the repository's
// .kero/worktrees, else in dir (the worktree-dir setting) under the
// repository's name; a branch's slashes become dashes.
func worktreePath(main, branch, dir string) string {
	name := strings.ReplaceAll(branch, "/", "-")
	if dir = strings.TrimSpace(dir); dir != "" {
		dir = expandHome(dir)
		if !filepath.IsAbs(dir) {
			dir = filepath.Join(main, dir)
		}
		return filepath.Join(dir, filepath.Base(main), name)
	}
	return filepath.Join(main, filepath.FromSlash(worktreeDir), name)
}

// checkWorktree tells what removing a session's worktree would lose.
func (d *Daemon) checkWorktree(ref string) (proto.WorktreeCheck, error) {
	d.mu.Lock()
	s := d.findSessionLocked(ref)
	if s == nil {
		d.mu.Unlock()
		return proto.WorktreeCheck{}, fmt.Errorf("no session %q", ref)
	}
	if s.worktree == nil {
		d.mu.Unlock()
		return proto.WorktreeCheck{}, fmt.Errorf("session %s has no worktree of its own", s.id)
	}
	wt := *s.worktree
	shared := d.worktreeSharedLocked(s, wt.Path)
	d.mu.Unlock()
	wc := proto.WorktreeCheck{Worktree: wt, Shared: shared}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	r, err := git.Open(ctx, wt.Path)
	if err != nil {
		return wc, nil // gone already: nothing to lose
	}
	st, err := r.State(ctx, wt.Branch, wt.Base)
	if err != nil {
		return wc, err
	}
	wc.Files, wc.Unpushed, wc.Merged = st.Files, st.Unpushed, st.Merged
	return wc, nil
}

// worktreeSharedLocked reports whether a session besides s works in the
// worktree at path; d.mu is held.
func (d *Daemon) worktreeSharedLocked(s *session, path string) bool {
	for _, o := range d.sessions {
		if o == s {
			continue
		}
		if o.worktree != nil && o.worktree.Path == path {
			return true
		}
		for _, p := range o.panes {
			p.mu.Lock()
			in := proto.Within(p.info.WorkDir(), path)
			p.mu.Unlock()
			if in {
				return true
			}
		}
	}
	return false
}

// closeSession closes a session, and with p.RemoveWorktree its worktree,
// unless another session works in it. Without p.Force it refuses, keeping
// the session, when removing it would lose changes or commits.
func (d *Daemon) closeSession(p proto.CloseParams) error {
	if !p.RemoveWorktree {
		return d.removeSession(p.ID)
	}
	wc, err := d.checkWorktree(p.ID)
	if err != nil {
		return err
	}
	// Its branch stays unless merged, with its commits: only what isn't
	// committed would be lost.
	if !wc.Shared && !p.Force && wc.Files > 0 {
		return fmt.Errorf("the worktree has %s: --force removes it anyway", wc.Losses())
	}
	if err := d.removeSession(p.ID); err != nil {
		return err
	}
	if wc.Shared {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	// The panes' programs end as they close: give them a moment to let
	// go of the worktree, as Windows wants of a folder to remove.
	time.Sleep(200 * time.Millisecond)
	if err := git.RemoveWorktree(ctx, wc.Main, wc.Path, wc.Branch, wc.Base); err != nil {
		return fmt.Errorf("the session closed, but its worktree stays: %w", err)
	}
	d.log.Printf("worktree %s removed", wc.Path)
	return nil
}
