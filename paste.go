package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/egoist/mygo/transfer"

	"kero/internal/client"
	"kero/internal/proto"
	"kero/internal/shell"

	"kero/locales"
)

// maxUpload bounds what a paste into a remote pane uploads, and maxFile
// each file of it, as kerod takes them (paste.file).
const (
	maxUpload = 64 << 20
	maxFile   = 32 << 20
)

// remotePaste takes a paste into a pane of another machine, where this
// machine's paths mean nothing: the files and the image it holds go to
// the host (paste.file), and their paths there are pasted, which the
// programs there read, as Claude Code an image's. Text pastes as it is.
func (a *App) remotePaste(id string, d transfer.Data) bool {
	if !a.hostOf(id).remote() {
		return false
	}
	// The terminal asks only for a clipboard that holds something, as a
	// local pane's paste (pasteImage).
	if len(d.Formats()) == 0 {
		a.toast(locales.ToastPasteClipboardUnreadable())
		return true
	}
	files, _ := d.Files()
	if len(files) > 0 {
		a.uploadPaste(id, files, pasteUpload{})
		return true
	}
	// Text, as of cells copied with a picture of them, pastes as text.
	if t, err := d.Read(transfer.Text); err == nil && len(t) > 0 {
		return false
	}
	f, ok := imageToPaste(d)
	if !ok {
		return false
	}
	ext, ok := pasteImageTypes[f]
	if !ok {
		a.toast(locales.ToastPasteImageUnsupported(strings.ToUpper(strings.TrimPrefix(string(f), "image/"))))
		return true
	}
	img, err := d.Read(f)
	if err == nil && len(img) == 0 {
		err = errors.New("the image is empty")
	}
	if err != nil {
		a.toast(locales.ToastPasteImageFailed(err.Error()))
		return true
	}
	a.uploadPaste(id, nil, pasteUpload{name: "pasted-image" + ext, data: img})
	return true
}

// remoteDrop takes files dropped on a pane of another machine, which go
// there as a paste's do (remotePaste).
func (a *App) remoteDrop(id string, paths []string) bool {
	if !a.hostOf(id).remote() {
		return false
	}
	a.uploadPaste(id, paths, pasteUpload{})
	return true
}

// pasteUpload is a file that goes to a host for a paste: an image's
// bytes, or a file of this machine, read off the main thread.
type pasteUpload struct {
	name, file string
	data       []byte
}

// uploadPaste copies files of this machine, and an image (if it has a
// name), to the host of a pane, and pastes their paths there.
func (a *App) uploadPaste(id string, files []string, image pasteUpload) {
	h := a.hostOf(id)
	if h.cl == nil {
		a.toast(locales.HostNotConnected(h.name))
		return
	}
	var ups []pasteUpload
	total := len(image.data)
	if total > maxFile {
		a.toast(locales.PasteTooLarge(maxFile >> 20))
		return
	}
	if image.name != "" {
		ups = append(ups, image)
	}
	for _, f := range files {
		st, err := os.Stat(f)
		if err != nil || st.IsDir() {
			a.toast(locales.PasteNotAFile(filepath.Base(f)))
			return
		}
		total += int(st.Size())
		if total > maxUpload || st.Size() > maxFile {
			a.toast(locales.PasteTooLarge(maxFile >> 20))
			return
		}
		ups = append(ups, pasteUpload{name: filepath.Base(f), file: f})
	}
	if total > 1<<20 {
		a.toast(locales.PasteUploading(h.name))
	}
	dialer := h.dialer()
	go func() {
		paths, err := sendPaste(dialer, ups)
		if err != nil {
			a.update(func() { a.toast(fmt.Sprintf("%s: %v", h.name, err)) })
			return
		}
		quoted := make([]string, len(paths))
		for i, p := range paths {
			quoted[i] = pastedPath(h, p)
		}
		a.update(func() {
			if e := a.terms[id]; e != nil && e.term != nil {
				e.term.Paste(strings.Join(quoted, " "))
			}
		})
	}()
}

// sendPaste puts the uploads on a host, in kerod's paste directory
// (paste.file), and returns their paths there. A var for tests.
var sendPaste = func(dialer client.Dialer, ups []pasteUpload) ([]string, error) {
	// A connection of its own, so that a large file holds up none of the
	// host's other calls, as the sidebar's.
	cl, err := client.ConnectVia(dialer)
	if err != nil {
		return nil, err
	}
	defer cl.Close()
	var paths []string
	for _, u := range ups {
		data := u.data
		if u.file != "" {
			if data, err = os.ReadFile(u.file); err != nil {
				return nil, err
			}
		}
		var r proto.PasteFile
		if err := cl.Call("paste.file", proto.PasteFileParams{Name: u.name, Data: data}, &r); err != nil {
			return nil, err
		}
		paths = append(paths, r.Path)
	}
	return paths, nil
}

// shellEscape writes a path as one word of a POSIX shell, as dropped
// files' are: a backslash before what the shell would read otherwise.
func shellEscape(p string) string {
	var b strings.Builder
	for _, r := range p {
		safe := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("/._-+@%:,=", r) || r > 0x7f
		if !safe {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// pastedPath writes a path of a host as one word of its shells: of a
// POSIX shell, else, on Windows, of PowerShell, the shell of its panes:
// in single quotes, in which nothing expands, unless it is all letters,
// digits and . _ - : \ /.
func pastedPath(h *host, p string) string {
	if !h.windows() {
		return shellEscape(p)
	}
	for _, r := range p {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune(`._-:\/`, r)) {
			return shell.PSQuote(p)
		}
	}
	return p
}

// pasteDir is where the images pasted into panes are kept, as files a
// program takes by their paths. A var for tests.
var pasteDir = func() string { return filepath.Join(os.TempDir(), "kero-paste") }

// pasteKeep is how long a pasted image's file stays: an agent may come
// back to the path long after the paste.
const pasteKeep = 7 * 24 * time.Hour

// pasteImageTypes are the images a paste saves for a program, by the
// extension of their file: those coding agents take.
var pasteImageTypes = map[transfer.Format]string{
	transfer.PNG: ".png",
	"image/jpeg": ".jpg",
	"image/gif":  ".gif",
	"image/webp": ".webp",
}

// pasteImage takes a paste of the clipboard that holds an image and no
// text, as a screenshot copied to the clipboard does, and pastes the path
// of a file with the image instead, as dropping the file on the pane
// would: coding agents take the path as an image they attach.
//
// The terminal's own paste cannot carry the image to the program. The
// program runs in kerod's terminal, where a Kitty clipboard protocol paste
// event (mode 5522) cannot go, since the frames kerod sends do not carry
// the mode and kerod refuses such reads (ClipboardForward); and a paste of
// an image alone sends nothing, or an empty bracketed paste, which the
// user sees as a paste that did nothing. So every paste of an image ends
// in a path or in a toast that says why not.
//
// It runs on the main thread, as Options.OnPaste does, with what the
// clipboard holds, and reports whether it took the paste: it takes none
// that has text, which pastes as it is, or neither files nor an image.
// Files with no text paste as their paths.
func (a *App) pasteImage(id string, d transfer.Data) bool {
	t := a.termFor(id)
	if t == nil {
		return false
	}
	// The terminal asks only for a clipboard that holds something, so
	// nothing here is a clipboard that could not be read, as when it
	// changed meanwhile or an image is too big to convert.
	if len(d.Formats()) == 0 {
		a.toast(locales.ToastPasteClipboardUnreadable())
		return true
	}
	if text, _ := d.Read(transfer.Text); len(text) > 0 {
		return false
	}
	if files, _ := d.Files(); len(files) > 0 {
		// Files copied in Finder, or an image copied with its file, as
		// some apps do, offer no text: the terminal's paste would send
		// nothing, so their paths go, as a drop of them sends.
		quoted := make([]string, len(files))
		for i, f := range files {
			quoted[i] = quotePath(runtime.GOOS, a.paneShell(id), f)
		}
		t.Paste(strings.Join(quoted, " "))
		return true
	}
	f, ok := imageToPaste(d)
	if !ok {
		return false
	}
	ext, ok := pasteImageTypes[f]
	if !ok {
		a.toast(locales.ToastPasteImageUnsupported(strings.ToUpper(strings.TrimPrefix(string(f), "image/"))))
		return true
	}
	img, err := d.Read(f)
	if err == nil && len(img) == 0 {
		err = errors.New("the image is empty")
	}
	var path string
	if err == nil {
		path, err = savePastedImage(img, ext)
	}
	if err != nil {
		a.toast(pasteImageError(err, pasteDir()))
		return true
	}
	t.Paste(quotePath(runtime.GOOS, a.paneShell(id), path))
	return true
}

// imageToPaste returns the image format of d to paste: PNG if it has it,
// else the first of its image formats.
func imageToPaste(d transfer.Data) (transfer.Format, bool) {
	formats := d.Formats()
	if slices.Contains(formats, transfer.PNG) {
		return transfer.PNG, true
	}
	for _, f := range formats {
		if strings.HasPrefix(string(f), "image/") {
			return f, true
		}
	}
	return "", false
}

// pasteImageError says why an image could not be saved for a paste, and
// what the user can do: the toast is all they see, so the system's error
// is told alone only for what is not one of the causes they can mend.
func pasteImageError(err error, dir string) string {
	switch {
	case errors.Is(err, fs.ErrPermission):
		return locales.ToastPasteImageDenied(dir)
	case errors.Is(err, syscall.ENOSPC):
		return locales.ToastPasteImageDiskFull()
	}
	return locales.ToastPasteImageFailed(err.Error())
}

// paneShell returns the name of the shell of a pane, or of the pane in
// front of a session, by id.
func (a *App) paneShell(id string) string {
	for i := range a.st.Sessions {
		if p := a.st.Sessions[i].PaneByID(id); p != nil {
			return p.Shell
		}
	}
	if s := a.session(id); s != nil {
		if p := s.FocusPane(); p != nil {
			return p.Shell
		}
	}
	return ""
}

// savePastedImage writes an image to a file of its own, with the extension,
// in pasteDir, which only the user can enter, and returns its path. Images kept longer than
// pasteKeep go.
func savePastedImage(img []byte, ext string) (string, error) {
	dir := pasteDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	prunePasted(dir, time.Now().Add(-pasteKeep))
	f, err := os.CreateTemp(dir, "paste-*"+ext)
	if err != nil {
		return "", err
	}
	_, err = f.Write(img)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

// prunePasted removes the images of earlier pastes last written before
// the time, and nothing else.
func prunePasted(dir string, before time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasPrefix(name, "paste-") || !isPasteExt(filepath.Ext(name)) {
			continue
		}
		if info, err := e.Info(); err == nil && info.ModTime().Before(before) {
			os.Remove(filepath.Join(dir, name))
		}
	}
}

// isPasteExt reports whether ext is the extension of a pasted image's file.
func isPasteExt(ext string) bool {
	for _, e := range pasteImageTypes {
		if e == ext {
			return true
		}
	}
	return false
}

// quotePath quotes a path for the shell a pane runs, so that the shell
// takes it as one argument whatever it holds: as it is when it holds
// nothing a shell reads otherwise, else in single quotes, in which POSIX
// shells and PowerShell expand nothing. cmd.exe has double quotes only.
// shell is the shell's name or path, "" for the platform's default.
func quotePath(goos, shell, path string) string {
	safe := "._-/"
	if goos == "windows" {
		safe += `:\`
	}
	if path != "" && !strings.ContainsFunc(path, func(r rune) bool {
		return !('a' <= r && r <= 'z' || 'A' <= r && r <= 'Z' || '0' <= r && r <= '9' || strings.ContainsRune(safe, r))
	}) {
		return path
	}
	name := strings.ToLower(shell[strings.LastIndexAny(shell, `/\`)+1:])
	name = strings.TrimSuffix(name, ".exe")
	posix := slices.Contains([]string{"sh", "bash", "zsh", "fish", "dash", "ksh", "mksh"}, name)
	switch {
	case name == "cmd" && goos == "windows":
		return `"` + path + `"`
	case name == "pwsh" || name == "powershell" || goos == "windows" && !posix:
		// A single quote is doubled, and so are the curly ones, which
		// PowerShell reads as one.
		var b strings.Builder
		b.WriteByte('\'')
		for _, r := range path {
			b.WriteRune(r)
			if strings.ContainsRune("'‘’‚‛", r) {
				b.WriteRune(r)
			}
		}
		b.WriteByte('\'')
		return b.String()
	}
	return "'" + strings.ReplaceAll(path, "'", `'\''`) + "'"
}

// insertPath types the path of a file or folder dragged from the Files
// tab into a pane, quoted for its shell, and puts the keyboard there.
func (a *App) insertPath(sid, id string, d fileDrag) {
	e := a.terms[id]
	if e == nil || e.term == nil || a.hostOf(id).name != d.host {
		return
	}
	q := quotePath(runtime.GOOS, a.paneShell(id), d.path)
	if h := a.hostOf(id); h.remote() {
		q = pastedPath(h, d.path)
	}
	e.term.Paste(q)
	if s := a.session(sid); s != nil {
		a.setFocus(s, id)
		a.paneRef(id).Focus()
	}
}
