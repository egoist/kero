package main

import (
	"errors"
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
	if _, err := os.Lstat(to); err == nil {
		if !replace {
			return nil
		}
		if err := os.RemoveAll(to); err != nil {
			return err
		}
	}
	switch {
	case st.IsDir():
		return os.CopyFS(to, os.DirFS(from))
	case st.Mode()&fs.ModeSymlink != 0:
		target, err := os.Readlink(from)
		if err != nil {
			return err
		}
		return os.Symlink(target, to)
	default:
		return copyFile(from, to, st.Mode().Perm())
	}
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
