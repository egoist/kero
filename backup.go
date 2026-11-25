package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/proto"
	"kero/locales"
)

// The viewer's edits not saved outlast the app, as VS Code's hot exit
// keeps them: quitting asks nothing, and the next launch shows them as it
// left them, not saved still. The app writes them, with what each
// session's viewer showed, to unsaved.json, a moment after the user
// pauses typing, so that a crash loses no more than that, and as it
// quits. An edit comes back as its file's text loads, in Files or in a
// diff of Changes, and with the hash of the file it was made on, so that
// saving it over a file changed meanwhile asks first (askOverwrite);
// until then it stays in the file.

// backupDelay is how long the user pauses typing before their edits are
// backed up.
const backupDelay = time.Second

// viewerBackup is unsaved.json: what each session's viewer shows, and the
// edits not saved.
type viewerBackup struct {
	Views   map[string]viewBackup `json:"views,omitempty"`
	Unsaved []unsavedText         `json:"unsaved,omitempty"`
}

// viewBackup is what a session's viewer shows: the diffs of Changes, or a
// file of Files.
type viewBackup struct {
	Kind string `json:"kind"`
	Pane string `json:"pane,omitempty"` // the file's
	Path string `json:"path,omitempty"`
	Rel  string `json:"rel,omitempty"`
}

// unsavedText is a text the user edited and didn't save: a file of
// Files, or the new side of a diff of Changes (Kind), as its file has it,
// line endings too, and the hash of the file it was made on.
type unsavedText struct {
	Kind string `json:"kind"`
	Host string `json:"host,omitempty"` // "" for this machine
	// Scope is the list of changes a diff's is: a worktree's against a
	// base, or a turn's. Two of them may be of one file, and an edit of
	// one is not the other's.
	Scope string `json:"scope,omitempty"`
	Pane  string `json:"pane,omitempty"`
	Path  string `json:"path"`
	Hash  string `json:"hash"`
	Text  string `json:"text"`
}

func (u unsavedText) key() string { return unsavedKey(u.Kind, u.Host, u.Scope, u.Path) }

// unsavedKey is what an edit is remembered by. A file's has no scope of
// its own, and keeps the key it always had, so an edit backed up before
// scopes were stays the file's.
func unsavedKey(kind, host, scope, path string) string {
	if scope == "" {
		return kind + "\x00" + host + "\x00" + path
	}
	return kind + "\x00" + host + "\x00" + scope + "\x00" + path
}

func backupPath() string { return filepath.Join(proto.Dir(), "unsaved.json") }

// backupState is what the app keeps of its backups.
type backupState struct {
	// unsaved are the edits backed up that no text shows yet, by kind,
	// host, scope and path (unsavedKey).
	unsaved map[string]unsavedText
	// sig is what the backup is of, as last seen, changed when it
	// changed; written what the file has.
	sig, written string
	// said is the failure last said, so that a failure that goes on is
	// said once, not once a second.
	said    string
	changed time.Time
}

// loadBackup reads the viewers and the edits the app left as it last
// quit. A backup that could not be read is said: the edits the user made
// are in it, and the app shows none of them without it. A backup that is
// not there is no news: there was none to restore.
func (a *App) loadBackup() {
	b, err := os.ReadFile(backupPath())
	if err != nil {
		if !os.IsNotExist(err) {
			a.toast(locales.ToastBackupUnreadable(err.Error()))
		}
		return
	}
	var vb viewerBackup
	if err := json.Unmarshal(b, &vb); err != nil {
		a.toast(locales.ToastBackupUnreadable(err.Error()))
		return
	}
	a.side.backup.unsaved = map[string]unsavedText{}
	for _, u := range vb.Unsaved {
		a.side.backup.unsaved[u.key()] = u
	}
	for sid, v := range vb.Views {
		if v.Kind != sideChanges && v.Kind != sideFiles {
			continue
		}
		if a.side.views == nil {
			a.side.views = map[string]*sideView{}
		}
		sv := &sideView{kind: v.Kind}
		if v.Path != "" {
			sv.file = &fileView{pane: v.Pane, path: v.Path, rel: v.Rel}
		}
		if v.Kind == sideFiles && sv.file == nil {
			continue
		}
		a.side.views[sid] = sv
	}
}

// restoreEdit puts back in b, a text just loaded, the edit backed up of
// its file, if any, with the hash of the file it was made on.
func (a *App) restoreEdit(kind string, h *host, scope, path string, b *editor.Buffer, hash *string) {
	key := unsavedKey(kind, h.name, scope, path)
	u, ok := a.side.backup.unsaved[key]
	if !ok {
		return
	}
	delete(a.side.backup.unsaved, key)
	replaceText(b, u.Text)
	*hash = u.Hash
}

// backupNow is the backup of the viewers as they are.
func (a *App) backupNow() viewerBackup {
	vb := viewerBackup{Views: map[string]viewBackup{}}
	for sid, v := range a.side.views {
		if v.kind == "" {
			continue
		}
		b := viewBackup{Kind: v.kind}
		if f := v.file; f != nil {
			b.Pane, b.Path, b.Rel = f.pane, f.path, f.rel
		}
		vb.Views[sid] = b
	}
	for _, t := range a.allTargets() {
		vb.Unsaved = append(vb.Unsaved, a.unsavedOf(t))
	}
	// The edits of panes gone, which are not saved but stay kept: their
	// files are where they were, and the worktree may show them again.
	for _, sf := range a.side.changes.files {
		if t := a.diffTarget(sf); t.gone && t.buf != nil && t.buf.Modified() {
			vb.Unsaved = append(vb.Unsaved, a.unsavedOf(t))
		}
	}
	for _, u := range a.side.backup.unsaved {
		vb.Unsaved = append(vb.Unsaved, u)
	}
	slices.SortFunc(vb.Unsaved, func(x, y unsavedText) int { return strings.Compare(x.key(), y.key()) })
	return vb
}

// unsavedOf is a text the backup keeps, as its file has it.
func (a *App) unsavedOf(t editTarget) unsavedText {
	return unsavedText{Kind: t.kind, Host: t.host, Scope: t.scope, Pane: t.pane, Path: t.path, Hash: *t.hash, Text: bufferText(t.buf)}
}

// backupSig is what the backup is of, cheaply: each viewer's, and each
// text's with edits, at its version. The entries are sorted: the maps
// yield them in any order, and a signature that changed with nothing
// changed would read as the user typing on, and the write would wait
// for a pause that never comes.
func (a *App) backupSig() string {
	var b strings.Builder
	sids := make([]string, 0, len(a.side.views))
	for sid := range a.side.views {
		sids = append(sids, sid)
	}
	slices.Sort(sids)
	for _, sid := range sids {
		if v := a.side.views[sid]; v.kind != "" {
			fmt.Fprint(&b, sid, v.kind)
			if v.file != nil {
				b.WriteString(v.file.path)
			}
			b.WriteByte(0)
		}
	}
	ts := a.allTargets()
	slices.SortFunc(ts, func(x, y editTarget) int {
		return strings.Compare(x.kind+"\x00"+x.scope+"\x00"+x.path, y.kind+"\x00"+y.scope+"\x00"+y.path)
	})
	for _, t := range ts {
		fmt.Fprint(&b, t.kind, t.scope, t.path, t.buf.Version(), *t.hash, "\x00")
	}
	fmt.Fprint(&b, len(a.side.backup.unsaved))
	return b.String()
}

// backupEdits writes the backup once what it is of changed, and the user
// paused for backupDelay.
func (a *App) backupEdits(c *ui.Context) {
	bs := &a.side.backup
	sig := a.backupSig()
	if sig != bs.sig {
		bs.sig, bs.changed = sig, c.Now()
	}
	if sig == bs.written {
		return
	}
	if wait := backupDelay - c.Now().Sub(bs.changed); wait > 0 {
		c.After(wait)
		return
	}
	if err := writeBackup(a.backupNow()); err != nil {
		// Nothing was written, so the backup is still owed: another
		// moment on, and it tries again — not as though it were done.
		// The user's edits are not backed up: say it, once per trouble,
		// and not once a second.
		if err.Error() != bs.said {
			bs.said = err.Error()
			a.toast(locales.ToastBackupFailed(err.Error()))
		}
		c.After(backupDelay)
		return
	}
	bs.said = ""
	bs.written = sig
}

// writeBackup writes the backup: small, the texts the user edited alone,
// and written as they pause, so at once. It says whether it was written,
// so that one that was not is tried again.
func writeBackup(vb viewerBackup) error {
	path := backupPath()
	if len(vb.Views) == 0 && len(vb.Unsaved) == 0 {
		// Nothing of the user's to keep; a file that isn't there is
		// the answer already. One that is there but cannot be taken
		// away is a failure to say, not "the backup is gone": the stale
		// edits it holds would come back after the next start, as though
		// they had never been saved and closed.
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		return nil
	}
	b, err := json.Marshal(vb)
	if err != nil {
		return err
	}
	// Private: it holds what the user typed.
	if err := os.MkdirAll(proto.Dir(), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// backupOnQuit writes the backup as the app quits: nothing retries this
// one, and there is nowhere to say it failed.
func (a *App) backupOnQuit() {
	_ = writeBackup(a.backupNow())
}
