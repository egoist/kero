package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"kero/locales"
)

// Files and folders dropped from the file manager onto the Files tab are
// copied into the folder under the pointer: a folder's row, the folder of
// a file's row, else the root. A name the folder holds already asks
// first, to replace it or skip it. Only this machine's folders take them:
// a remote host's would need the files uploaded there.

// dropInto copies files dropped on the Files tab into dir, a folder of
// the host of pane, asking first about names it holds already.
func (a *App) dropInto(pane, dir string, files []string) {
	h := a.hostOf(pane)
	if h.remote() {
		a.toast(locales.FilesDropRemote(h.name))
		return
	}
	var clash []string
	for _, f := range files {
		to := filepath.Join(dir, filepath.Base(f))
		if samePath(f, to) {
			continue
		}
		if _, err := os.Lstat(to); err == nil {
			clash = append(clash, filepath.Base(f))
		}
	}
	if len(clash) == 0 {
		a.copyInto(dir, files, true)
		return
	}
	title := locales.FilesReplaceTitle(clash[0])
	if len(clash) > 1 {
		title = locales.FilesReplaceManyTitle(len(clash))
	}
	a.confirm = &confirmation{
		open:    true,
		title:   title,
		detail:  locales.FilesReplaceDetail(len(clash)),
		action:  locales.FilesReplace(),
		destroy: true,
		run:     func() { a.copyInto(dir, files, true) },
		alt:     locales.FilesSkip(),
		altRun:  func() { a.copyInto(dir, files, false) },
	}
}

// copyInto copies files and folders into dir, off the main thread,
// replacing what has their names there with replace, else leaving it,
// then lists the folder anew, unfolded.
func (a *App) copyInto(dir string, files []string, replace bool) {
	h := a.local()
	go func() {
		var failed []string
		for _, f := range files {
			if err := copyEntry(f, filepath.Join(dir, filepath.Base(f)), replace); err != nil {
				failed = append(failed, filepath.Base(f)+": "+err.Error())
			}
		}
		a.update(func() {
			fs := &a.side.files
			fs.gen++
			if fs.open != nil {
				fs.open[filesKey(h, dir)] = true
			}
			if len(failed) > 0 {
				a.toast(locales.FilesCopyFailed(strings.Join(failed, "; ")))
			}
		})
	}()
}

// errIntoItself is a folder dropped into itself, or a folder in it.
var errIntoItself = errors.New("a folder can't go into itself")

// copyEntry copies a file, or a folder with all it holds, from to to.
// What to names already goes first with replace, and stays without.
func copyEntry(from, to string, replace bool) error {
	if samePath(from, to) {
		return nil
	}
	st, err := os.Lstat(from)
	if err != nil {
		return err
	}
	if st.IsDir() && withinDir(filepath.Clean(to), filepath.Clean(from)) {
		return errIntoItself
	}
	if _, err := os.Lstat(to); err == nil && !replace {
		return nil // what to names stays
	}
	// The copy is made whole beside what it lands on, and put in its
	// place only then: a copy that fails leaves what was there.
	switch {
	case st.IsDir():
		tmp, err := freeName(filepath.Dir(to))
		if err != nil {
			return err
		}
		// The folder is made as CopyFS makes it: 0777 and the umask's.
		if err := os.Mkdir(tmp, 0o777); err != nil {
			os.RemoveAll(tmp)
			return err
		}
		if err := os.CopyFS(tmp, os.DirFS(from)); err != nil {
			os.RemoveAll(tmp)
			return err
		}
		return putInPlace(tmp, to, false)
	case st.Mode()&fs.ModeSymlink != 0:
		target, err := os.Readlink(from)
		if err != nil {
			return err
		}
		tmp, err := freeName(filepath.Dir(to))
		if err != nil {
			return err
		}
		if err := os.Symlink(target, tmp); err != nil {
			return err
		}
		return putInPlace(tmp, to, true)
	default:
		tmp, err := freeName(filepath.Dir(to))
		if err != nil {
			return err
		}
		if err := copyFile(from, tmp, st.Mode().Perm()); err != nil {
			os.Remove(tmp)
			return err
		}
		return putInPlace(tmp, to, true)
	}
}

// freeName is a name in dir that nothing holds, for a copy made beside
// what it lands on.
func freeName(dir string) (string, error) {
	f, err := os.CreateTemp(dir, ".kero-copy-*")
	if err != nil {
		return "", err
	}
	name := f.Name()
	f.Close()
	os.Remove(name)
	return name, nil
}

// putInPlace puts what was copied at to, in place of what was there: a
// file over a file by a rename, which the system's own, so that there is
// no moment when neither is there; anything else takes what was there
// away first, as a rename cannot put one over a folder.
func putInPlace(tmp, to string, over bool) error {
	if st, err := os.Lstat(to); err == nil {
		if !over || !st.Mode().IsRegular() {
			if err := os.RemoveAll(to); err != nil {
				// What was there is what it now is — the removal may have
				// taken part of it — and the copy is whole where it is:
				// it is the user's, and the failure names it, as the
				// rename's failure names it.
				return fmt.Errorf("%s: the copy is at %s: %w", to, tmp, err)
			}
		}
	}
	if err := os.Rename(tmp, to); err != nil {
		// The copy is whole and it stays where it is: it is the user's.
		return fmt.Errorf("%s: the copy is at %s: %w", to, tmp, err)
	}
	return nil
}

// copyFile copies a file's bytes and permissions.
func copyFile(from, to string, perm fs.FileMode) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(to)
		return err
	}
	return out.Close()
}

// samePath tells whether two paths name one file.
func samePath(a, b string) bool {
	if filepath.Clean(a) == filepath.Clean(b) {
		return true
	}
	sa, err1 := os.Stat(a)
	sb, err2 := os.Stat(b)
	return err1 == nil && err2 == nil && os.SameFile(sa, sb)
}
