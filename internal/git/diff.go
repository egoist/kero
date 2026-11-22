package git

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
)

// maxText is the size of the largest file shown whole: larger ones show
// as their patch.
const maxText = 1 << 20

// Snapshot writes a tree of the working tree as it is, its tracked files
// and its untracked ones but those ignored, and returns its id. It goes
// through an index of its own, seeded with a copy of the worktree's so
// that git hashes only what changed, and leaves the worktree's alone. The
// tree and its blobs are loose objects nothing refers to, which git's gc
// prunes once they are old.
func (r Repo) Snapshot(ctx context.Context) (string, error) {
	dir, err := os.MkdirTemp("", "kero-index-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	index := filepath.Join(dir, "index")
	if b, err := os.ReadFile(filepath.Join(r.GitDir, "index")); err == nil {
		if err := os.WriteFile(index, b, 0o600); err != nil {
			return "", err
		}
	}
	env := []string{"GIT_INDEX_FILE=" + index}
	if _, err := run(ctx, r.Root, env, "add", "--all", "--", "."); err != nil {
		return "", err
	}
	out, err := run(ctx, r.Root, env, "write-tree")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// Bases a diff compares the working tree with.
const (
	BaseTurn   = "turn"   // a snapshot: what an agent's turn started from
	BaseHead   = "head"   // HEAD: what isn't committed
	BaseBranch = "branch" // where HEAD left the default branch: a PR's diff
)

// Base returns the tree-ish of a base, and what it is to show: "HEAD", or
// the default branch's name; turn is the snapshot's tree, for BaseTurn.
func (r Repo) Base(ctx context.Context, base, turn string) (rev, name string, err error) {
	switch base {
	case BaseTurn:
		if turn == "" {
			return "", "", errors.New("no turn to compare with")
		}
		return turn, "", nil
	case BaseBranch:
		def := r.DefaultBranch()
		for _, ref := range []string{"refs/remotes/origin/" + def, "refs/heads/" + def} {
			if def == "" {
				break
			}
			if out, err := run(ctx, r.Root, nil, "merge-base", "HEAD", ref); err == nil {
				return strings.TrimSpace(string(out)), def, nil
			}
		}
	}
	if _, err := run(ctx, r.Root, nil, "rev-parse", "--verify", "--quiet", "HEAD"); err != nil {
		// No commit yet: everything is new.
		out, err := r.emptyTree(ctx)
		return out, "HEAD", err
	}
	return "HEAD", "HEAD", nil
}

// emptyTree returns the id of the empty tree, of the repository's hash.
func (r Repo) emptyTree(ctx context.Context) (string, error) {
	cmd := []string{"hash-object", "-t", "tree", "--stdin"}
	git := command()
	if git == "" {
		return "", ErrNoGit
	}
	c := exec.CommandContext(ctx, git, cmd...)
	c.Dir = r.Root
	c.Stdin = strings.NewReader("")
	hide(c)
	out, err := c.Output()
	return strings.TrimSpace(string(out)), err
}

// File is a file changed since a base.
type File struct {
	Path    string // slash-separated, from the worktree's root
	OldPath string // what it was renamed from, else ""
	Status  string // "added", "modified", "deleted", "renamed" or "type"
	Added   int
	Removed int
	Binary  bool
}

// Changes returns the files of the working tree changed since rev: a
// tree-ish, as Base returns. now is a snapshot of the working tree, which
// it takes when "".
func (r Repo) Changes(ctx context.Context, rev, now string) ([]File, error) {
	if now == "" {
		var err error
		if now, err = r.Snapshot(ctx); err != nil {
			return nil, err
		}
	}
	out, err := run(ctx, r.Root, nil, "diff", "--no-ext-diff", "--no-textconv", "-M", "-z", "--name-status", rev, now)
	if err != nil {
		return nil, err
	}
	var files []File
	byPath := map[string]int{}
	fields := strings.Split(string(out), "\x00")
	for i := 0; i+1 < len(fields); i++ {
		code := fields[i]
		if code == "" {
			continue
		}
		f := File{Path: fields[i+1]}
		i++
		switch code[0] {
		case 'A':
			f.Status = "added"
		case 'D':
			f.Status = "deleted"
		case 'R', 'C':
			if i+1 < len(fields) {
				f.OldPath, f.Path = f.Path, fields[i+1]
				i++
			}
			f.Status = "renamed"
			if code[0] == 'C' {
				f.Status, f.OldPath = "added", ""
			}
		case 'T':
			f.Status = "type"
		default:
			f.Status = "modified"
		}
		byPath[f.Path] = len(files)
		files = append(files, f)
	}
	out, err = run(ctx, r.Root, nil, "diff", "--no-ext-diff", "--no-textconv", "-M", "-z", "--numstat", rev, now)
	if err != nil {
		return nil, err
	}
	for _, n := range parseNumstat(out) {
		if i, ok := byPath[n.path]; ok {
			files[i].Added, files[i].Removed, files[i].Binary = n.added, n.removed, n.binary
		}
	}
	return files, nil
}

// Patch returns the working tree's changes since rev as git diff prints
// them, of the files under paths, or all; now is as Changes takes it.
func (r Repo) Patch(ctx context.Context, rev, now string, paths ...string) (string, error) {
	if now == "" {
		var err error
		if now, err = r.Snapshot(ctx); err != nil {
			return "", err
		}
	}
	args := []string{"diff", "--no-ext-diff", "--no-textconv", "-M", rev, now}
	if len(paths) > 0 {
		args = append(append(args, "--"), paths...)
	}
	out, err := run(ctx, r.Root, nil, args...)
	return string(out), err
}

// Text is a changed file's text before and now.
type Text struct {
	Old, New string
	// Hash is the file's on disk, to write it back only as it was
	// (Write).
	Hash string
	// Binary: either side is no text. Large: too large to show whole;
	// Patch is then the change, as git diff prints it.
	Binary bool
	Large  bool
	Patch  string
}

// FileText returns a file's text in rev, from oldPath ("" for path), and
// in the working tree now.
func (r Repo) FileText(ctx context.Context, rev, path, oldPath string) (Text, error) {
	full, err := r.local(path)
	if err != nil {
		return Text{}, err
	}
	if oldPath == "" {
		oldPath = path
	}
	if _, err := r.local(oldPath); err != nil {
		return Text{}, err
	}
	var t Text
	nb, err := readWorking(full)
	if err != nil && !os.IsNotExist(err) {
		return Text{}, err
	}
	t.Hash = Hash(nb)
	// LC_ALL=C: what notInRev reads is git's English message, which a
	// translated git would say otherwise, as run takes the user's.
	ob, err := run(ctx, r.Root, cLocale, "cat-file", "blob", rev+":"+oldPath)
	if err != nil {
		if !notInRev(err) {
			return Text{}, err
		}
		ob = nil // added since
	}
	switch {
	case binary(ob) || binary(nb):
		t.Binary = true
	case len(ob) > maxText || len(nb) > maxText:
		t.Large = true
		// The patch is the diff of a file too big to show whole: a
		// failure to make it is a failure, not an empty patch.
		if t.Patch, err = r.Patch(ctx, rev, "", path); err != nil {
			return Text{}, err
		}
	default:
		t.Old, t.New = string(ob), string(nb)
	}
	return t, nil
}

// readWorking reads a file of the working tree as git sees it: a symbolic
// link is its target's path, not what it points to.
func readWorking(full string) ([]byte, error) {
	fi, err := os.Lstat(full)
	if err != nil {
		return nil, err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(full)
		return []byte(filepath.ToSlash(target)), err
	}
	if !fi.Mode().IsRegular() {
		return nil, nil
	}
	return os.ReadFile(full)
}

// Hash returns the hash Text and Write take of a file's content.
func Hash(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// Changed reports whether a file of the working tree is other than in
// rev, as git keeps it: one that a diff with rev shows.
func (r Repo) Changed(ctx context.Context, rev, path string) (bool, error) {
	full, err := r.local(path)
	if err != nil {
		return false, err
	}
	nb, err := readWorking(full)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	// LC_ALL=C, as FileText's: what notInRev reads is git's English
	// message, which a translated git would say otherwise.
	if _, err := run(ctx, r.Root, cLocale, "cat-file", "blob", rev+":"+path); err != nil {
		if !notInRev(err) {
			return false, err
		}
		return nb != nil, nil // not in rev: changed when it is now
	}
	// The file is in the rev: a diff with it says whether it changed —
	// the mode too, which the blob's bytes alone do not hold, and after
	// the filters a checkout runs, which the bytes alone do not see. The
	// answer is as the diff the user sees: --quiet gives nothing but the
	// exit, 0 for the same and 1 for changed.
	if _, err := run(ctx, r.Root, cLocale, "diff", "--quiet", "--no-ext-diff", "--no-textconv", rev, "--", path); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 1 {
			return true, nil
		}
		return false, err
	}
	return false, nil
}

// notInRev tells whether err says the path is not in the rev, as git
// says it in English, which the call that failed was given LC_ALL=C for:
// "fatal: path 'x' does not exist in 'HEAD'" when the file is not on
// disk either, and "fatal: path 'x' exists on disk, but not in 'HEAD'"
// when it is. Any other failure is a failure and not a file that is not
// there: a timeout, a rev that is gone, a git that is broken.
func notInRev(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "does not exist in") || strings.Contains(msg, "exists on disk, but not in")
}

// cLocale is the environment of the git calls whose words are read: it
// keeps git's messages the English ones, whatever the user's locale is.
var cLocale = []string{"LC_ALL=C"}

// ErrChanged: the file isn't as it was when read.
var ErrChanged = errors.New("the file changed since it was shown")

// Write writes text to a regular file of the working tree, keeping its
// mode, when its content still hashes to hash: one written meanwhile is
// left as it is (ErrChanged).
func (r Repo) Write(path, hash, text string) error {
	full, err := r.local(path)
	if err != nil {
		return err
	}
	return WriteFile(full, hash, text)
}

// WriteFile writes text to a regular file, keeping its mode, when its
// content still hashes to hash: one written meanwhile is left as it is
// (ErrChanged). A file that is not there is the empty content: one
// written over a file that was deleted since it was read does not hash
// to what was read, and is asked about, as one changed is.
func WriteFile(full, hash, text string) error {
	fi, err := os.Lstat(full)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var b []byte
	perm := fs.FileMode(0o644)
	if err == nil {
		if !fi.Mode().IsRegular() {
			return errors.New("not a regular file")
		}
		if b, err = os.ReadFile(full); err != nil {
			return err
		}
		perm = fi.Mode().Perm()
	}
	if Hash(b) != hash {
		return ErrChanged
	}
	tmp, err := os.CreateTemp(filepath.Dir(full), ".kero-*")
	if err != nil {
		return err
	}
	_, err = tmp.WriteString(text)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(tmp.Name(), perm)
	}
	if err == nil {
		err = os.Rename(tmp.Name(), full)
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}

// Mode returns the mode path has in rev, as git's tree holds it: the
// permission bits a regular file of that tree is checked out with, and
// 0 when the rev has no regular file there.
func (r Repo) Mode(ctx context.Context, rev, path string) (fs.FileMode, error) {
	if _, err := r.local(path); err != nil {
		return 0, err
	}
	// "<mode> <type> <object>\t<path>": the mode is the first word of
	// the one line of the file asked for, and there is no line when the
	// rev has no file there.
	out, err := run(ctx, r.Root, cLocale, "ls-tree", rev, "--", path)
	if err != nil {
		return 0, err
	}
	line, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	mode, _, _ := strings.Cut(line, " ")
	switch mode {
	case "100644":
		return 0o644, nil
	case "100755":
		return 0o755, nil
	}
	return 0, nil // not a regular file of the rev: a symlink or a submodule
}

// Revert puts a file back as rev has it: its content as hash says it was
// shown, and its execute bit as the rev's tree holds it — a file made to
// run, and made not to, runs as the rev says again. The rest of the
// mode is not git's to keep, and stays as the file has it. A file the
// rev does not have is taken away; one the worktree does not have, the
// rev's, is written anew.
func (r Repo) Revert(ctx context.Context, rev, path, hash, text string) error {
	full, err := r.local(path)
	if err != nil {
		return err
	}
	// LC_ALL=C, as Changed's: what notInRev reads is git's English
	// message, which a translated git would say otherwise.
	if _, err := run(ctx, r.Root, cLocale, "cat-file", "blob", rev+":"+path); err != nil {
		if !notInRev(err) {
			return err
		}
		// The rev has no file there: the change is the file's
		// existence, and the revert takes the file away — of the
		// content it was shown at, for one changed meanwhile is
		// asked about, as a write is.
		b, rerr := os.ReadFile(full)
		if rerr != nil && !os.IsNotExist(rerr) {
			return rerr
		}
		if Hash(b) != hash {
			return ErrChanged
		}
		if err := os.Remove(full); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	if err := r.Write(path, hash, text); err != nil {
		return err
	}
	mode, err := r.Mode(ctx, rev, path)
	if err != nil || mode == 0 {
		return err
	}
	fi, err := os.Stat(full)
	if err != nil {
		return err
	}
	// Git records only the execute bit: take it from the rev, and leave
	// the rest of the file's mode as it is.
	return os.Chmod(full, fi.Mode().Perm()&^0o111|mode&0o111)
}

// local returns the file of the worktree a slash-separated path names,
// refusing one outside it, through .. or a symbolic link, or in its git
// directory.
func (r Repo) local(p string) (string, error) {
	slashed := p
	if filepath.Separator == '\\' {
		slashed = strings.ReplaceAll(p, `\`, "/")
	}
	clean := path.Clean(slashed)
	if p == "" || path.IsAbs(clean) || filepath.IsAbs(filepath.FromSlash(clean)) || clean == ".." || strings.HasPrefix(clean, "../") ||
		strings.EqualFold(clean, ".git") || strings.HasPrefix(strings.ToLower(clean), ".git/") {
		return "", errors.New("not a path in the worktree: " + p)
	}
	full := filepath.Join(r.Root, filepath.FromSlash(clean))
	// The directory holding it, with its links resolved, must be the
	// worktree's.
	root, err := filepath.EvalSymlinks(r.Root)
	if err != nil {
		return "", err
	}
	dir, err := filepath.EvalSymlinks(filepath.Dir(full))
	if err != nil {
		if os.IsNotExist(err) {
			return full, nil // gone: nothing to read or write through it
		}
		return "", err
	}
	if rel, err := filepath.Rel(root, dir); err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("not a path in the worktree: " + p)
	}
	return full, nil
}

// binary reports whether b looks like no text: a NUL in its first 8 KB,
// as git judges.
func binary(b []byte) bool {
	return bytes.IndexByte(b[:min(len(b), 8000)], 0) >= 0
}
