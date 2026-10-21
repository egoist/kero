package daemon

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"kero/internal/git"
	"kero/internal/proto"
	"kero/internal/settings"
)

// gitFollow follows the git worktrees the panes work in: each one's
// branch and changes (proto.Pane.Git), and the snapshots of agents' turns
// (proto.Pane.Turn). It looks once a second, at the files of each
// worktree's git directory alone, and runs git status only when one of
// them changed, when a pane's status did, while an agent works there
// (every few seconds), and now and then besides; never on a fast poll.
type gitFollow struct {
	d    *Daemon
	wake chan struct{}

	mu    sync.Mutex
	poked map[string]bool        // directories whose worktree to refresh now
	dirs  map[string]dirRepo     // the worktree of each directory, as last found
	repos map[string]*repoStatus // by root
}

// dirRepo is the worktree holding a directory, and when that was found.
type dirRepo struct {
	repo git.Repo // Root "" for none
	at   time.Time
}

// repoStatus is a worktree's status as last found.
type repoStatus struct {
	repo  git.Repo
	info  *proto.GitInfo // replaced whole on a change, never changed
	stamp string
	at    time.Time
	// slow counts the refreshes in a row that ran out of time, past two
	// of which only a poke refreshes it: a huge repository, or one on a
	// network's disk.
	slow int
}

const (
	gitTimeout     = 3 * time.Second  // a refresh's git status
	gitWorkingStep = 4 * time.Second  // between refreshes while an agent works there
	gitIdleStep    = 30 * time.Second // between refreshes otherwise
)

func newGitFollow(d *Daemon) *gitFollow {
	return &gitFollow{d: d, wake: make(chan struct{}, 1), poked: map[string]bool{}, dirs: map[string]dirRepo{}, repos: map[string]*repoStatus{}}
}

// poke asks for the worktree of dir to be refreshed at once, as when a
// pane's status changed.
func (g *gitFollow) poke(dir string) {
	if g == nil || dir == "" {
		return
	}
	g.mu.Lock()
	g.poked[dir] = true
	g.mu.Unlock()
	select {
	case g.wake <- struct{}{}:
	default:
	}
}

func (g *gitFollow) loop() {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-t.C:
		case <-g.wake:
		case <-g.d.quit:
			return
		}
		g.look(time.Now())
	}
}

// look refreshes the worktrees that may have changed, and gives the panes
// theirs.
func (g *gitFollow) look(now time.Time) {
	on := settings.Load().GitStatus
	type paneDir struct {
		p       *pane
		dir     string
		working bool
	}
	g.d.mu.Lock()
	panes := make([]paneDir, 0, len(g.d.panes))
	for _, p := range g.d.panes {
		panes = append(panes, paneDir{p: p})
	}
	g.d.mu.Unlock()
	for i := range panes {
		p := panes[i].p
		p.mu.Lock()
		if !p.closed && p.info.Status != proto.Exited {
			panes[i].dir = p.info.WorkDir()
			panes[i].working = p.info.Status == proto.Working
		}
		p.mu.Unlock()
	}

	g.mu.Lock()
	poked := g.poked
	g.poked = map[string]bool{}
	g.mu.Unlock()

	// Each pane's worktree, and what each worktree has of the panes.
	roots := map[*pane]string{}
	type use struct{ working, poked bool }
	uses := map[string]*use{}
	if on {
		for _, pd := range panes {
			if pd.dir == "" {
				continue
			}
			r := g.repoOf(pd.dir, now, poked[pd.dir])
			if r.Root == "" {
				continue
			}
			roots[pd.p] = r.Root
			u := uses[r.Root]
			if u == nil {
				u = &use{}
				uses[r.Root] = u
				g.mu.Lock()
				if g.repos[r.Root] == nil {
					g.repos[r.Root] = &repoStatus{repo: r}
				}
				g.mu.Unlock()
			}
			u.working = u.working || pd.working
			u.poked = u.poked || poked[pd.dir]
		}
	}

	g.mu.Lock()
	for root := range g.repos {
		if uses[root] == nil {
			delete(g.repos, root)
		}
	}
	work := make(map[string]*repoStatus, len(g.repos))
	for root, rs := range g.repos {
		work[root] = rs
	}
	g.mu.Unlock()

	for root, rs := range work {
		u := uses[root]
		branch := ""
		if rs.info != nil {
			branch = rs.info.Branch
		}
		stamp := rs.repo.Stamp(branch)
		due := rs.info == nil || u.poked || stamp != rs.stamp ||
			u.working && now.Sub(rs.at) >= gitWorkingStep || now.Sub(rs.at) >= gitIdleStep
		if !due || rs.slow >= 2 && !u.poked {
			continue
		}
		g.refresh(rs, stamp, now)
	}

	changed := false
	for _, pd := range panes {
		var info *proto.GitInfo
		if rs := work[roots[pd.p]]; rs != nil {
			info = rs.info
		}
		pd.p.mu.Lock()
		if pd.p.info.Git != info {
			pd.p.info.Git = info
			changed = true
		}
		pd.p.mu.Unlock()
	}
	if changed {
		g.d.changed()
	}
}

// repoOf returns the worktree holding dir, "" Root for none, asking git
// when it was never asked, or not for a while, or again is set.
func (g *gitFollow) repoOf(dir string, now time.Time, again bool) git.Repo {
	g.mu.Lock()
	dr, ok := g.dirs[dir]
	g.mu.Unlock()
	// A directory comes into a repository by git init, and out of one as
	// a worktree goes: rarely, so it's asked again only now and then.
	stale := now.Sub(dr.at) > 5*time.Minute || dr.repo.Root == "" && now.Sub(dr.at) > 30*time.Second
	if ok && !stale && !again {
		return dr.repo
	}
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	r, err := git.Open(ctx, dir)
	if err != nil {
		r = git.Repo{}
	}
	g.mu.Lock()
	if len(g.dirs) > 512 {
		g.dirs = map[string]dirRepo{}
	}
	g.dirs[dir] = dirRepo{repo: r, at: now}
	g.mu.Unlock()
	return r
}

// refresh finds a worktree's status anew.
func (g *gitFollow) refresh(rs *repoStatus, stamp string, now time.Time) {
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	st, err := rs.repo.Status(ctx)
	rs.at, rs.stamp = now, stamp
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			rs.slow++
			g.d.log.Printf("git status of %s took over %v", rs.repo.Root, gitTimeout)
		}
		return
	}
	rs.slow = 0
	info := &proto.GitInfo{
		Root: rs.repo.Root, Branch: st.Branch, Head: st.Head, Upstream: st.Upstream,
		Ahead: st.Ahead, Behind: st.Behind, Default: rs.repo.DefaultBranch(),
		Files: st.Files, Added: st.Added, Removed: st.Removed, State: st.State,
	}
	if rs.info == nil || *rs.info != *info {
		rs.info = info
	}
	if rs.info.Branch != "" {
		// The branch's ref joins the stamp once the branch is known.
		rs.stamp = rs.repo.Stamp(st.Branch)
	}
}

// snapshot starts a pane's turn: a snapshot of its worktree as its agent
// starts working, which its changes since are of. A turn that started
// later stands.
func (g *gitFollow) snapshot(p *pane, dir string, at time.Time) {
	if g == nil || dir == "" || !settings.Load().GitStatus {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	r, err := git.Open(ctx, dir)
	if err != nil {
		return
	}
	tree, err := r.Snapshot(ctx)
	if err != nil {
		g.d.log.Printf("snapshot of %s: %v", r.Root, err)
		return
	}
	p.mu.Lock()
	if p.info.Turn == nil || p.info.Turn.At < at.UnixMilli() {
		p.info.Turn = &proto.Turn{Tree: tree, Root: r.Root, At: at.UnixMilli()}
	}
	p.mu.Unlock()
	g.d.changed()
}

// gitOf returns a pane's worktree and the revision of a base in it, with
// what it is to show (git.Repo.Base).
func (d *Daemon) gitOf(ctx context.Context, ref, base string) (*pane, git.Repo, string, string, error) {
	pn := d.findPane(ref)
	if pn == nil {
		return nil, git.Repo{}, "", "", fmt.Errorf("no session or pane %q", ref)
	}
	pn.mu.Lock()
	dir, turn := pn.info.WorkDir(), pn.info.Turn
	pn.mu.Unlock()
	tree := ""
	if base == git.BaseTurn {
		if turn == nil {
			return nil, git.Repo{}, "", "", errors.New("the pane's agent hasn't started a turn")
		}
		// The turn's worktree, where the agent worked then.
		dir, tree = turn.Root, turn.Tree
	}
	r, err := git.Open(ctx, dir)
	if err != nil {
		return nil, git.Repo{}, "", "", err
	}
	rev, name, err := r.Base(ctx, base, tree)
	return pn, r, rev, name, err
}

// gitChanges returns the files changed in a pane's worktree since a base.
func (d *Daemon) gitChanges(p proto.GitParams) (proto.GitChanges, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, r, rev, name, err := d.gitOf(ctx, p.Pane, p.Base)
	if err != nil {
		return proto.GitChanges{}, err
	}
	files, err := r.Changes(ctx, rev, "")
	if err != nil {
		return proto.GitChanges{}, err
	}
	res := proto.GitChanges{Root: r.Root, BaseName: name, Files: make([]proto.GitFile, 0, len(files))}
	for _, f := range files {
		res.Files = append(res.Files, proto.GitFile{Path: f.Path, OldPath: f.OldPath, Status: f.Status, Added: f.Added, Removed: f.Removed, Binary: f.Binary})
	}
	return res, nil
}

// gitText returns a file's text in a base and now.
func (d *Daemon) gitText(p proto.GitParams) (proto.GitText, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, r, rev, _, err := d.gitOf(ctx, p.Pane, p.Base)
	if err != nil {
		return proto.GitText{}, err
	}
	t, err := r.FileText(ctx, rev, p.Path, p.OldPath)
	if err != nil {
		return proto.GitText{}, err
	}
	if p.Known != "" && p.Known == t.Hash {
		return proto.GitText{Hash: t.Hash, Same: true}, nil
	}
	return proto.GitText{Old: t.Old, New: t.New, Hash: t.Hash, Binary: t.Binary, Large: t.Large, Patch: t.Patch}, nil
}

// gitRevert writes a file changed since a base back as it was in part:
// only while no agent works in its worktree, whose edits it would race,
// and only a file the base's diff shows, as it was when shown. It returns
// the hash of what it wrote.
func (d *Daemon) gitRevert(p proto.GitWriteParams) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, r, rev, _, err := d.gitOf(ctx, p.Pane, p.Base)
	if err != nil {
		return "", err
	}
	d.mu.Lock()
	for _, o := range d.panes {
		o.mu.Lock()
		busy := o.info.Status == proto.Working && proto.Within(o.info.WorkDir(), r.Root)
		o.mu.Unlock()
		if busy {
			d.mu.Unlock()
			return "", errors.New("an agent is working in this worktree: wait for it to finish")
		}
	}
	d.mu.Unlock()
	changed, err := r.Changed(ctx, rev, p.Path)
	if err != nil {
		return "", err
	}
	if !changed {
		return "", fmt.Errorf("%s has no changes to revert", p.Path)
	}
	if err := r.Write(p.Path, p.Hash, p.Text); err != nil {
		return "", err
	}
	d.git.poke(r.Root)
	return git.Hash([]byte(p.Text)), nil
}

// gitPatch returns a pane's worktree's changes since a base as git diff
// prints them.
func (d *Daemon) gitPatch(p proto.GitParams) (proto.ReadResult, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, r, rev, _, err := d.gitOf(ctx, p.Pane, p.Base)
	if err != nil {
		return proto.ReadResult{}, err
	}
	var paths []string
	if p.Path != "" {
		paths = append(paths, strings.TrimPrefix(p.Path, "./"))
	}
	text, err := r.Patch(ctx, rev, "", paths...)
	return proto.ReadResult{Text: text}, err
}
