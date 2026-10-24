package main

import (
	"bytes"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"

	"kero/internal/proto"

	"kero/locales"
)

// The Files view is the panel's second: a session's folder, a tree of it,
// and under the tree the file chosen in it, its text, or its image. The
// tree lists a folder as it opens it, from the kerod of the pane's host,
// and so it shows a remote host's files as this machine's.

// errFilesGone is a file read that is no longer there.
var errFilesGone = errors.New("no such file")

const (
	// treeShare is the share of the view the tree first takes, above a
	// file.
	treeShare = 0.5
	// maxListed bounds the folders the tree lists at once: the rest come
	// as those answered are.
	maxListed = 4
	// maxText bounds a file shown as text, and maxImage one shown as an
	// image.
	maxText  = 4 << 20
	maxImage = 32 << 20
)

// filesState is the Files view's, kept across the views and the sessions.
type filesState struct {
	trees map[string]*fileTree // by host and folder
	// shown is the tree the view shows, nil while it shows none; share
	// the share of the view the tree takes, and drag where a drag of the
	// edge between them began, 0 while none.
	shown    *fileTree
	share    float32
	drag     float32
	dragging bool
}

// fileTree is a folder's tree, as the user opened it: a folder's listing
// as it came, its choice, the folders open, and the file shown under it.
type fileTree struct {
	pane    string // the pane whose host it is of
	root    string
	dirs    map[string]*fileDir
	isDir   map[string]bool
	outline ui.OutlineState[string]
	chosen  int
	file    *openFile // the file shown under the tree, nil for none
	shown   string    // the file shown, as the tree writes it, "" for none
}

// fileDir is a folder of a tree: its files, as listed, or why it did not
// list.
type fileDir struct {
	paths []string
	busy  bool
	err   string
	// gen is the listing's: an answer to an older one, as of a refresh,
	// is dropped.
	gen     uint64
	fetched time.Time
}

// openFile is the file shown under the tree.
type openFile struct {
	path   string
	st     *editor.State
	bm     *ui.Bitmap
	busy   bool
	binary bool
	large  bool
	err    string
	gen    uint64
}

// filesRoot returns the folder the Files view shows for a session, and the
// pane whose it is: the worktree of the pane the user is in, else its
// folder, else another terminal pane's of the session; "" for none.
func (a *App) filesRoot(s *proto.Session) (pane *proto.Pane, root string) {
	here, turn := a.changesPanes(s)
	for _, p := range []*proto.Pane{here, turn} {
		if p == nil || p.Browser() {
			continue
		}
		if p.Git != nil && p.Git.Root != "" {
			return p, p.Git.Root
		}
		if dir := p.WorkDir(); dir != "" {
			return p, dir
		}
	}
	for i := range s.Panes {
		p := &s.Panes[i]
		if !p.Browser() && p.WorkDir() != "" {
			return p, p.WorkDir()
		}
	}
	return nil, ""
}

// tree returns the tree of a folder of a host, made as the view first
// shows it; the pane that made it is the one the view shows it for now.
func (a *App) tree(pane *proto.Pane, root string) *fileTree {
	fs := &a.side.files
	key := a.hostOf(pane.ID).name + "\x00" + root
	t := fs.trees[key]
	if t == nil {
		if fs.trees == nil {
			fs.trees = map[string]*fileTree{}
		}
		t = &fileTree{root: root, chosen: -1, dirs: map[string]*fileDir{}, isDir: map[string]bool{root: true}}
		t.outline.List.Selected = &t.chosen
		t.outline.Indent = 12
		fs.trees[key] = t
	}
	t.pane = pane.ID
	return t
}

// children returns the paths in a folder of the tree, nil for a file.
func (t *fileTree) children(path string) []string {
	if !t.isDir[path] {
		return nil
	}
	if d := t.dirs[path]; d != nil && d.paths != nil {
		return d.paths
	}
	return []string{}
}

// rel is a path as it shows in the tree: from its folder.
func (t *fileTree) rel(path string) string {
	return strings.TrimLeft(strings.TrimPrefix(path, t.root), `/\`)
}

// shownPath is a path as the tree showed it: with its folder's separator,
// as a host joining its names does.
func (t *fileTree) shownPath(path string) string {
	if strings.Contains(t.root, `\`) || len(t.root) > 1 && t.root[1] == ':' {
		return strings.ReplaceAll(path, "/", `\`)
	}
	return path
}

// hostJoin joins a name to a folder of a host, with the host's separator,
// which its paths tell: a Windows host's have backslashes, or a drive.
func hostJoin(dir, name string) string {
	sep := "/"
	if strings.Contains(dir, `\`) || len(dir) > 1 && dir[1] == ':' {
		sep = `\`
	}
	if strings.HasSuffix(dir, sep) {
		return dir + name
	}
	return dir + sep + name
}

// filesView is the Files view: the tree, and the file chosen in it below.
func (a *App) filesView(c *ui.Context, pal *palette, s *proto.Session) {
	fs := &a.side.files
	pane, root := a.filesRoot(s)
	if pane == nil {
		fs.shown = nil
		a.sideMessage(c, pal, locales.FilesNoFolder(), locales.FilesNoFolderDetail())
		return
	}
	t := a.tree(pane, root)
	fs.shown = t
	// A host not connected lists nothing: its folders come as it is.
	if h := a.hostOf(pane.ID); h.cl == nil {
		a.sideMessage(c, pal, locales.SideFiles(), locales.HostNotConnected(h.label()))
		return
	}
	a.syncTree(c, t)
	if t.shown != "" {
		share := fs.share
		if share == 0 {
			share = treeShare
		}
		ui.Column(c.Key("files")).Grow(1).MinHeight(0).AlignItems(ui.Stretch).Bind(a.paneRef("files-body")).Children(func() {
			ui.Column(c.Key("tree")).Grow(share).Basis(0).MinHeight(0).AlignItems(ui.Stretch).Children(func() {
				a.treeView(c, pal, t)
			})
			a.filesEdge(c, pal)
			ui.Column(c.Key("file")).Grow(1 - share).Basis(0).MinHeight(0).AlignItems(ui.Stretch).Children(func() {
				a.fileView(c, pal, t)
			})
		})
		return
	}
	ui.Column(c.Key("files")).Grow(1).MinHeight(0).AlignItems(ui.Stretch).Children(func() {
		a.treeView(c, pal, t)
	})
}

// syncTree lists the folders the tree shows that have no listing, a few at
// a time, and those the user asked to refresh.
func (a *App) syncTree(c *ui.Context, t *fileTree) {
	asking := 0
	for _, d := range t.dirs {
		if d.busy {
			asking++
		}
	}
	want := []string{t.root}
	for p := range t.outline.Open.All() {
		if t.isDir[p] && p != t.root {
			want = append(want, p)
		}
	}
	slices.Sort(want)
	for _, p := range want {
		d := t.dirs[p]
		if d != nil && (d.busy || d.paths != nil || d.err != "") {
			continue
		}
		if asking >= maxListed {
			c.After(50 * time.Millisecond)
			return
		}
		asking++
		a.fetchDir(t, p)
	}
}

// fetchDir asks kerod for a folder's listing, dotfiles too, .git aside.
func (a *App) fetchDir(t *fileTree, path string) {
	d := t.dirs[path]
	if d == nil {
		d = &fileDir{}
		t.dirs[path] = d
	}
	cl := a.hostOf(t.pane).cl
	if cl == nil {
		return
	}
	d.busy, d.err = true, ""
	d.gen++
	gen := d.gen
	go func() {
		var l proto.FSList
		err := cl.Call("fs.list", proto.FSListParams{Dir: path, Hidden: true}, &l)
		a.update(func() {
			if d.gen != gen {
				return
			}
			d.busy, d.fetched = false, time.Now()
			if err != nil {
				d.err = remoteError(err)
				return
			}
			d.err = ""
			paths := make([]string, 0, len(l.Entries))
			for _, e := range l.Entries {
				if e.Name == ".git" {
					continue
				}
				p := hostJoin(path, e.Name)
				t.isDir[p] = e.Dir
				paths = append(paths, p)
			}
			d.paths = paths
		})
	}()
}

// treeView is the tree: a folder's folders and files, whose folders open
// on the arrow, a double click or a click on them, and whose files open
// under the tree.
func (a *App) treeView(c *ui.Context, pal *palette, t *fileTree) {
	d := t.dirs[t.root]
	switch {
	case d == nil || d.paths == nil && d.err == "":
		ui.Column(c).Grow(1).Center().Children(func() { ui.Spinner(c) })
		return
	case d.paths == nil:
		a.sideMessage(c, pal, locales.FilesCantList(), d.err)
		return
	case len(d.paths) == 0:
		a.sideMessage(c, pal, locales.FilesEmpty(), "")
		return
	}
	toggle := ""
	tree := ui.Outline(c.Key("outline"), &t.outline, d.paths, t.children, func(path string) {
		dir := t.isDir[path]
		row := ui.Row(c).Grow(1).MinWidth(0).Gap(7).AlignItems(ui.Center)
		// A folder opens or closes on a click on its name; a file opens
		// under the tree.
		if row.Clicked() && row.ClickModifiers() == 0 {
			if dir {
				toggle = path
			} else {
				a.openFile(t, path)
			}
		}
		fg := pal.text
		if t.shown == path {
			fg = pal.attention
		}
		row.Children(func() {
			svg := docIcon
			if dir {
				svg = folderIcon
			}
			ui.Icon(c, svg).Size(14, 14).Shrink(0).TextColor(pal.textFaint)
			ui.Text(c, proto.DirName(path)).FontSize(13).TextColor(fg).SingleLine().Ellipsis("…").MinWidth(0).Shrink(1).Tooltip(t.rel(path))
			// A folder that does not list says why under its name.
			if dir {
				if sub := t.dirs[path]; sub != nil && sub.err != "" {
					ui.Text(c, sub.err).FontSize(11.5).TextColor(pal.danger).SingleLine().Ellipsis("…").MinWidth(0).Shrink(2)
				}
			}
		})
	}).Grow(1).MinHeight(0).Padding(0, 6, 8, 6).FontSize(13)
	if toggle != "" {
		for i := range t.outline.Rows() {
			if t.outline.Item(i) == toggle {
				t.chosen = i
			}
		}
		if t.outline.Open.Has(toggle) {
			t.outline.Open.Remove(toggle)
		} else {
			t.outline.Open.Add(toggle)
		}
		tree.Focus()
	}
	if tree.Submitted() && t.chosen >= 0 && t.chosen < t.outline.Rows() {
		p := t.outline.Item(t.chosen)
		switch {
		case t.isDir[p] && t.outline.Open.Has(p):
			t.outline.Open.Remove(p)
		case t.isDir[p]:
			t.outline.Open.Add(p)
		default:
			a.openFile(t, p)
		}
	}
}

// openFile shows a file of the tree under it, read as it first opens; a
// listing refresh keeps it.
func (a *App) openFile(t *fileTree, path string) {
	if t.shown == path && t.file != nil {
		return
	}
	t.shown = t.shownPath(path)
	f := &openFile{path: path}
	t.file = f
	a.readFile(t, f)
}

// openInPane opens a file of the tree in a file pane beside the pane the
// tree is of: the app's editor shows it, colored by its language, on the
// host it is on.
func (a *App) openInPane(t *fileTree, path string) {
	s := a.sessionOfPane(t.pane)
	if s == nil {
		return
	}
	a.split(s, proto.CreateParams{Split: t.pane, Direction: "right", File: path})
}

// openInEditor opens a file of the tree in the host's editor, in a pane
// of its shell.
func (a *App) openInEditor(t *fileTree, path string) {
	s := a.sessionOfPane(t.pane)
	if s == nil {
		return
	}
	a.split(s, proto.CreateParams{Split: t.pane, Direction: "right", Command: editorCommand(a.hostOf(t.pane), path)})
}

// readFile reads a file from the kerod of the tree's host: an image to
// show, else its text. A file too large, or binary, is told of instead.
func (a *App) readFile(t *fileTree, f *openFile) {
	cl := a.hostOf(t.pane).cl
	if cl == nil {
		return
	}
	f.busy, f.err = true, ""
	f.gen++
	gen, path := f.gen, f.path
	image := peekable[strings.ToLower(filepath.Ext(path))]
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
		a.update(func() {
			if f.gen != gen {
				return
			}
			f.busy = false
			if err != nil {
				f.err = remoteError(err)
				return
			}
			f.large, f.binary = large, false
			switch {
			case large:
				f.st, f.bm = nil, nil
			case image:
				f.bm = bm
				f.st = nil
			case isBinary(r.Data):
				f.binary = true
				f.st, f.bm = nil, nil
			default:
				f.bm = nil
				b := editor.NewBuffer(string(r.Data))
				b.SetLanguage(editor.LanguageFor(filepath.Base(path)))
				if f.st == nil {
					f.st = &editor.State{Buffer: b}
				}
			}
		})
	}()
}

// isBinary tells text from what is not: a NUL in its first bytes, as git
// tells, or bytes that are no UTF-8.
func isBinary(b []byte) bool {
	head := b[:min(len(b), 8000)]
	return bytes.IndexByte(head, 0) >= 0 || !utf8.Valid(b)
}

// remoteError says what a call to a host's kerod came to: a method its
// kerod has not is told to update.
func remoteError(err error) string {
	if strings.Contains(err.Error(), "unknown method") {
		return locales.FilesUpdateHost()
	}
	return err.Error()
}

// filesEdge is the edge between the tree and the file, which a drag
// moves.
func (a *App) filesEdge(c *ui.Context, pal *palette) {
	fs := &a.side.files
	d := ui.Box(c.Key("files-edge")).Height(paneGap).Shrink(0).Cursor(ui.CursorResizeRow).KeepFocus()
	if d.Hovered() || d.Pressed() {
		d.Draw(func(p *ui.Painter, r ui.Rect) {
			p.Fill(ui.Rect{X: r.X + r.W/2 - 18, Y: r.Y + r.H/2 - 1.5, W: 36, H: 3}, pal.textFaint.Alpha(0.7), 1.5)
		})
	}
	if _, dy, ok := d.Dragged(); ok {
		if h := a.paneRef("files-body").Bounds(c).H - paneGap; h > 0 {
			if !fs.dragging {
				fs.drag, fs.dragging = fs.share, true
				if fs.drag == 0 {
					fs.drag = treeShare
				}
			}
			fs.drag += dy / h
			fs.share = min(max(fs.drag, 0.12), 0.88)
		}
	} else if !d.Pressed() {
		fs.dragging = false
	}
	if d.DoubleClicked() {
		fs.share = 0
	}
}

// fileView is the file shown: its name, and its text in its editor, or its
// image, or why it shows neither.
func (a *App) fileView(c *ui.Context, pal *palette, t *fileTree) {
	f := t.file
	ui.Column(c.Key("open-" + f.path)).Grow(1).MinHeight(0).AlignItems(ui.Stretch).Children(func() {
		hdr := ui.Row(c.Key("hdr")).Height(stickyH).Shrink(0).Padding(0, 6, 0, 12).Gap(8).AlignItems(ui.Center).Background(pal.chip)
		hdr.Tooltip(f.path)
		hdr.Children(func() {
			ui.Icon(c, docIcon).Size(13, 13).TextColor(pal.textFaint).Shrink(0)
			ui.Text(c, proto.DirName(f.path)).FontSize(13).FontWeight(600).TextColor(pal.text).SingleLine().Ellipsis("…").Shrink(0).MaxWidth(220)
			ui.Text(c, strings.TrimSuffix(t.rel(f.path), proto.DirName(f.path))).FontSize(12).TextColor(pal.textFaint).
				SingleLine().Ellipsis("…").MinWidth(0).Shrink(1)
			ui.Spacer(c)
			iconButton(c, "files-edit", docIcon, locales.FilesOpenInPane(), pal, func() { a.defer_(func() { a.openInPane(t, f.path) }) })
			iconButton(c, "files-editor", splitRightIcon, locales.FilesOpenInEditor(), pal, func() { a.defer_(func() { a.openInEditor(t, f.path) }) })
			iconButton(c, "files-refresh", reloadIcon, locales.FilesRefresh(), pal, func() { a.defer_(func() { a.readFile(t, f) }) })
			iconButton(c, "files-close", closeIcon, locales.FilesCloseFile(), pal, func() {
				a.defer_(func() {
					t.shown, t.file = "", nil
					a.side.files.share = 0
				})
			})
		})
		switch {
		case f.err != "":
			a.sectionNote(c, pal, locales.FilesCantRead()+": "+f.err)
		case f.binary:
			a.sectionNote(c, pal, locales.FilesBinary())
		case f.large:
			a.sectionNote(c, pal, locales.FilesLarge())
		case f.busy:
			ui.Column(c.Key("loading")).Grow(1).Center().Children(func() { ui.Spinner(c) })
		case f.bm != nil:
			ui.Column(c.Key("image")).Grow(1).MinHeight(0).Padding(8).Center().Children(func() {
				ui.Image(c, f.bm).Shrink(1)
			})
		default:
			st := f.st
			st.ReadOnly = true
			st.SoftWrap = true
			st.LineNumbers = editor.LineNumbersOff
			st.Font = ui.Font{Family: a.termFamily(), Size: max(a.set.FontSize-1, 10)}
			st.Theme = a.codeTheme(c, pal)
			editor.View(c.Key("text"), st).Grow(1).MinHeight(0)
		}
	})
}
