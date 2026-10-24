package main

import (
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/proto"

	"kero/locales"
)

// A file pane shows a file of its host in MyGo's editor, colored by its
// language, as a terminal shows a program's cells: the daemon keeps the
// path, and the app reads the file through fs.read as the Files view does.

// filePaneStates are the files shown in file panes, by pane.
type filePaneStates map[string]*filePane

// filePane is a file pane's: its file, as read, and when it was, which a
// pane coming back to view reads again once the file is older.
type filePane struct {
	path   string
	st     *editor.State
	bm     *ui.Bitmap
	busy   bool
	binary bool
	large  bool
	err    string
	gen    uint64
	read   bool // a read was asked for
	mod    int64
}

// filePane returns a pane's file state, made as the pane first shows.
func (a *App) filePaneFor(p *proto.Pane) *filePane {
	if a.files == nil {
		a.files = filePaneStates{}
	}
	f := a.files[p.ID]
	if f == nil || f.path != p.File {
		f = &filePane{path: p.File}
		a.files[p.ID] = f
	}
	return f
}

// filePane shows the file of a file pane, and reads it as it first shows
// or changes on disk.
func (a *App) filePane(c *ui.Context, pal *palette, s *proto.Session, p *proto.Pane) {
	f := a.filePaneFor(p)
	a.readFilePane(p, f)
	ui.Box(c.Key("body")).Grow(1).MinHeight(0).Children(func() {
		switch {
		case f.err != "":
			a.message(c, pal, locales.FilesCantRead(), f.err, "", nil)
		case f.binary:
			a.message(c, pal, locales.FilesBinary(), f.path, "", nil)
		case f.large:
			a.message(c, pal, locales.FilesLarge(), f.path, "", nil)
		case f.busy || f.st == nil && f.bm == nil:
			ui.Column(c).Fill().Center().Children(func() { ui.Spinner(c) })
		case f.bm != nil:
			ui.Column(c.Key("image")).Fill().Padding(8).Center().Children(func() {
				ui.Image(c, f.bm).Shrink(1)
			})
		default:
			st := f.st
			st.ReadOnly = true
			st.SoftWrap = true
			st.LineNumbers = editor.LineNumbersOn
			st.Font = ui.Font{Family: a.termFamily(), Size: max(a.set.FontSize-1, 10)}
			st.Theme = a.codeTheme(c, pal)
			ed := editor.View(c.Key("file-"+p.ID), st).Fill()
			if ed.FocusWithin() && a.focusOf(s) != p.ID {
				a.setFocus(s, p.ID)
			}
		}
	})
}

// readFilePane reads a pane's file, once as it opens: a pane shows what
// the file was then, as a terminal shows what its program printed.
func (a *App) readFilePane(p *proto.Pane, f *filePane) {
	h := a.hostOf(p.ID)
	if h.cl == nil {
		return
	}
	if f.read {
		return
	}
	f.read = true
	f.busy, f.err = true, ""
	f.gen++
	gen, path := f.gen, f.path
	image := peekable[strings.ToLower(filepath.Ext(path))]
	cl := h.cl
	go func() {
		var st proto.FSStat
		var r proto.FSRead
		var bm *ui.Bitmap
		err := cl.Call("fs.stat", proto.FSStatParams{Path: path}, &st)
		large := err == nil && (image && st.Size > maxImage || !image && st.Size > maxText)
		if err == nil && (!st.Exists || st.Dir) {
			err = errFilesGone
		}
		if err == nil && !large {
			err = cl.Call("fs.read", proto.FSReadParams{Path: path, Max: max(maxImage, maxText)}, &r)
		}
		if err == nil && !large && image {
			bm, err = ui.DecodeBitmap(r.Data)
		}
		if err == nil && !large && image && bm == nil {
			// The host's kerod cannot draw it: its bytes are as good a
			// view as a text of them.
			image = false
		}
		a.update(func() {
			if f.gen != gen {
				return
			}
			f.busy = false
			if err != nil {
				f.err = remoteError(err)
				return
			}
			f.err = ""
			f.large, f.binary = large, false
			switch {
			case large:
				f.st, f.bm = nil, nil
			case image && bm != nil:
				f.bm, f.st = bm, nil
			case isBinary(r.Data):
				f.binary, f.st, f.bm = true, nil, nil
			default:
				f.bm = nil
				b := editor.NewBuffer(string(r.Data))
				b.SetLanguage(editor.LanguageFor(filepath.Base(path)))
				f.st = &editor.State{Buffer: b}
			}
		})
	}()
}
