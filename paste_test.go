package main

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

// fakePNG is not a picture, and need not be: the paste carries its bytes
// to a file as they are.
var fakePNG = []byte("\x89PNG\r\n\x1a\nnot really a picture")

// sinkConn is a Conn that keeps what the terminal writes to the program.
type sinkConn struct {
	mu     sync.Mutex
	closed chan struct{}
	got    []byte
}

func newSink() *sinkConn { return &sinkConn{closed: make(chan struct{})} }

func (c *sinkConn) Read([]byte) (int, error) {
	<-c.closed
	return 0, os.ErrClosed
}

func (c *sinkConn) Write(b []byte) (int, error) {
	c.mu.Lock()
	c.got = append(c.got, b...)
	c.mu.Unlock()
	return len(b), nil
}

func (c *sinkConn) Close() error {
	select {
	case <-c.closed:
	default:
		close(c.closed)
	}
	return nil
}

// written waits for the terminal to write something, which it does from a
// goroutine of its own, and returns all of it.
func (c *sinkConn) written(t *testing.T) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		s := string(c.got)
		c.mu.Unlock()
		if s != "" {
			return s
		}
		time.Sleep(10 * time.Millisecond)
	}
	return ""
}

// quiet returns what was written once no more comes: for a paste that
// should write nothing.
func (c *sinkConn) quiet() string {
	time.Sleep(200 * time.Millisecond)
	c.mu.Lock()
	defer c.mu.Unlock()
	return string(c.got)
}

func imageData() transfer.Data {
	return transfer.New(transfer.NewItem(transfer.Bytes(transfer.PNG, fakePNG)))
}

// pasteApp is the app with a terminal for pane "a", which writes to the
// sink, and pasted images going to a directory of the test's.
func pasteApp(t *testing.T) (*App, *sinkConn, string) {
	t.Helper()
	if testing.Short() {
		t.Skip("downloads libghostty-vt")
	}
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	a := testApp(t)
	dir := filepath.Join(t.TempDir(), "pasted")
	old := pasteDir
	pasteDir = func() string { return dir }
	t.Cleanup(func() { pasteDir = old })
	sink := newSink()
	term, err := terminal.New(terminal.Options{Conn: sink})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { term.Close() })
	a.terms["a"] = &termEntry{term: term}
	return a, sink, dir
}

// pastedFiles lists the files of the pasted images.
func pastedFiles(t *testing.T, dir string) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(dir, "paste-*"))
	if err != nil {
		t.Fatal(err)
	}
	return files
}

// An image alone on the clipboard pastes as the path of a file with it,
// which a program that takes images attaches: the file holds the image,
// and only the user can enter its directory.
func TestPasteImageAsPath(t *testing.T) {
	a, sink, dir := pasteApp(t)
	if !a.pasteImage("a", imageData()) {
		t.Fatal("the paste of an image was left to the terminal")
	}
	files := pastedFiles(t, dir)
	if len(files) != 1 {
		t.Fatalf("pasted files %q, want one", files)
	}
	if b, err := os.ReadFile(files[0]); err != nil || !bytes.Equal(b, fakePNG) {
		t.Errorf("the file holds %q (%v), want the image", b, err)
	}
	if st, err := os.Stat(dir); err != nil || st.Mode().Perm()&0o077 != 0 {
		t.Errorf("directory %v (%v) is open to others", st, err)
	}
	if got := sink.written(t); got != files[0] {
		t.Errorf("the program got %q, want the path %q", got, files[0])
	}
	if a.pendingToast != "" {
		t.Errorf("toast %q", a.pendingToast)
	}
}

// With the program taking bracketed pastes, as agents do, the path comes
// as a paste, which they take for a file dropped.
func TestPasteImageBracketed(t *testing.T) {
	a, sink, dir := pasteApp(t)
	a.terms["a"].term.Feed([]byte("\x1b[?2004h"))
	if !a.pasteImage("a", imageData()) {
		t.Fatal("the paste of an image was left to the terminal")
	}
	files := pastedFiles(t, dir)
	if len(files) != 1 {
		t.Fatalf("pasted files %q, want one", files)
	}
	if got, want := sink.written(t), "\x1b[200~"+files[0]+"\x1b[201~"; got != want {
		t.Errorf("the program got %q, want %q", got, want)
	}
}

// A clipboard with text, or with files, pastes as it always did: the image
// a copy of text from a page or of files in the Finder brings along is not
// what is pasted.
func TestPasteImageLeavesTextAndFiles(t *testing.T) {
	a, sink, dir := pasteApp(t)
	text := transfer.New(transfer.NewItem(
		transfer.Bytes(transfer.Text, []byte("hello")),
		transfer.Bytes(transfer.PNG, fakePNG)))
	files, err := transfer.FileData(filepath.Join(t.TempDir(), "a.png"))
	if err != nil {
		t.Fatal(err)
	}
	withImage := transfer.New(append(files.Items(), transfer.NewItem(transfer.Bytes(transfer.PNG, fakePNG)))...)
	for name, d := range map[string]transfer.Data{
		"text and an image":  text,
		"files and an image": withImage,
		"only files":         files,
		"only text":          transfer.TextData("hello"),
		"only html":          transfer.New(transfer.NewItem(transfer.Bytes(transfer.HTML, []byte("<b>x</b>")))),
	} {
		if a.pasteImage("a", d) {
			t.Errorf("%s: the paste was taken", name)
		}
	}
	if got := pastedFiles(t, dir); len(got) != 0 {
		t.Errorf("files %q written for pastes that are not of an image", got)
	}
	if got := sink.quiet(); got != "" {
		t.Errorf("the program got %q", got)
	}
}

// A pane that has no terminal (it is not attached yet) takes no paste.
func TestPasteImageNoTerminal(t *testing.T) {
	a, _, dir := pasteApp(t)
	if a.pasteImage("b", imageData()) {
		t.Error("a pane without a terminal took the paste")
	}
	a.terms["b"] = &termEntry{err: "no session"}
	if a.pasteImage("b", imageData()) {
		t.Error("a pane that failed to attach took the paste")
	}
	if got := pastedFiles(t, dir); len(got) != 0 {
		t.Errorf("files %q written", got)
	}
}

// When the image cannot be written, the paste is still the app's, which
// says so, rather than the terminal's, which would send nothing and
// leave the user guessing.
func TestPasteImageWriteFails(t *testing.T) {
	a, sink, dir := pasteApp(t)
	// A file where the directory should be.
	if err := os.WriteFile(dir, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if !a.pasteImage("a", imageData()) {
		t.Fatal("the paste was left to the terminal")
	}
	if !strings.HasPrefix(a.pendingToast, "Couldn’t paste the image: ") || !strings.Contains(a.pendingToast, "drop the image file") {
		t.Errorf("toast %q", a.pendingToast)
	}
	if got := sink.quiet(); got != "" {
		t.Errorf("the program got %q", got)
	}
}

// Images of earlier pastes go after a week, and nothing else of the
// directory does.
func TestPastedImagesExpire(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, age time.Duration) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		when := time.Now().Add(-age)
		if err := os.Chtimes(p, when, when); err != nil {
			t.Fatal(err)
		}
		return p
	}
	oldJPG := write("paste-old.jpg", pasteKeep+time.Hour)
	old := write("paste-old.png", pasteKeep+time.Hour)
	recent := write("paste-recent.png", pasteKeep-time.Hour)
	other := write("notes.txt", 10*pasteKeep)
	otherPNG := write("shot.png", 10*pasteKeep)
	subdir := filepath.Join(dir, "paste-dir.png")
	if err := os.Mkdir(subdir, 0o700); err != nil {
		t.Fatal(err)
	}
	prunePasted(dir, time.Now().Add(-pasteKeep))
	for p, want := range map[string]bool{oldJPG: false, old: false, recent: true, other: true, otherPNG: true, subdir: true} {
		if _, err := os.Stat(p); (err == nil) != want {
			t.Errorf("%s exists: %v, want %v", filepath.Base(p), err == nil, want)
		}
	}
}

// Each paste has a file of its own: a second image does not replace the
// path the first gave a program.
func TestPasteImageEachItsOwnFile(t *testing.T) {
	a, _, dir := pasteApp(t)
	for range 3 {
		if !a.pasteImage("a", imageData()) {
			t.Fatal("the paste was left to the terminal")
		}
	}
	if got := pastedFiles(t, dir); len(got) != 3 {
		t.Errorf("pasted files %q, want three", got)
	}
}

// The paste keys take the app's paste, through the terminal's Options: the
// image is not offered to the program, nor pasted as nothing.
func TestPasteImageByKeys(t *testing.T) {
	a, sink, dir := pasteApp(t)
	term := a.terms["a"].term
	// A terminal of the app's options, as the app makes them.
	term.Close()
	sink = newSink()
	o := a.termOptions("a", nil)
	o.Conn = sink
	o.ResizeByConn = false
	var err error
	term, err = terminal.New(o)
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	a.terms["a"] = &termEntry{term: term}
	tt := ui.NewTester(func(c *ui.Context) { terminal.View(c, term).Fill().AutoFocus() }, 400, 200)
	tt.Frame()
	term.Feed([]byte("\x1b[?2004h"))
	// The platform's paste keys.
	name, mods := "control+shift", ui.Ctrl|ui.Shift
	if runtime.GOOS == "darwin" {
		name, mods = "command", ui.Super
	}
	tt.SetClipboardData(imageData())
	tt.Frame()
	tt.Key(mods, ui.KeyV)
	tt.Frame()
	files := pastedFiles(t, dir)
	if len(files) != 1 {
		t.Fatalf("%s+V: pasted files %q, want one", name, files)
	}
	if got, want := sink.written(t), "\x1b[200~"+files[0]+"\x1b[201~"; got != want {
		t.Errorf("%s+V: the program got %q, want %q", name, got, want)
	}
	// Text still pastes as text.
	sink.mu.Lock()
	sink.got = nil
	sink.mu.Unlock()
	tt.SetClipboard("hello")
	tt.Frame()
	tt.Key(mods, ui.KeyV)
	tt.Frame()
	if got := sink.written(t); got != "\x1b[200~hello\x1b[201~" {
		t.Errorf("a paste of text sent %q", got)
	}
	if got := pastedFiles(t, dir); len(got) != 1 {
		t.Errorf("pasted files %q after a paste of text, want the one", got)
	}
}

func TestQuotePath(t *testing.T) {
	cases := []struct {
		goos, shell, path, want string
	}{
		{"darwin", "zsh", "/tmp/kero-paste/paste-123.png", "/tmp/kero-paste/paste-123.png"},
		{"darwin", "", "/var/folders/ab/T/kero-paste/paste-1.png", "/var/folders/ab/T/kero-paste/paste-1.png"},
		{"linux", "bash", "/tmp/a b.png", "'/tmp/a b.png'"},
		{"darwin", "fish", "/tmp/it's.png", `'/tmp/it'\''s.png'`},
		{"darwin", "zsh", "/tmp/$(id)`id`;x|y*.png", "'/tmp/$(id)`id`;x|y*.png'"},
		{"darwin", "zsh", "/tmp/x\ntouch pwned", "'/tmp/x\ntouch pwned'"},
		{"darwin", "zsh", "/tmp/日本.png", "'/tmp/日本.png'"},
		// A backslash is an escape to POSIX shells.
		{"darwin", "zsh", `/tmp/a\b.png`, `'/tmp/a\b.png'`},
		{"darwin", "zsh", "", "''"},
		{"windows", "pwsh.exe", `C:\Users\me\AppData\Local\Temp\kero-paste\paste-1.png`, `C:\Users\me\AppData\Local\Temp\kero-paste\paste-1.png`},
		{"windows", "pwsh.exe", `C:\Users\my name\paste-1.png`, `'C:\Users\my name\paste-1.png'`},
		{"windows", "powershell", `C:\Users\it's\paste.png`, `'C:\Users\it''s\paste.png'`},
		{"windows", "", `C:\Users\it’s me\paste.png`, `'C:\Users\it’’s me\paste.png'`},
		{"windows", `C:\Windows\System32\cmd.exe`, `C:\Users\my name\paste.png`, `"C:\Users\my name\paste.png"`},
		{"windows", `C:\Program Files\Git\bin\bash.exe`, `C:\Users\my name\paste.png`, `'C:\Users\my name\paste.png'`},
		{"windows", `C:\Program Files\Git\bin\bash.exe`, `C:/Users/me/paste.png`, `C:/Users/me/paste.png`},
	}
	for _, c := range cases {
		if got := quotePath(c.goos, c.shell, c.path); got != c.want {
			t.Errorf("quotePath(%s, %q, %q) = %s, want %s", c.goos, c.shell, c.path, got, c.want)
		}
	}
	// A shell reads the POSIX quoting back as the path.
	for _, name := range []string{"bash", "zsh", "sh"} {
		bin, err := exec.LookPath(name)
		if err != nil {
			continue
		}
		for _, c := range cases {
			if c.goos == "windows" || c.path == "" {
				continue
			}
			out, err := exec.Command(bin, "-c", "printf %s "+c.want).Output()
			if err != nil || string(out) != c.path {
				t.Errorf("%s read %s as %q (%v), want %q", name, c.want, out, err, c.path)
			}
		}
	}
}

// paneShell is the shell of the pane, or of the one in front of a session.
func TestPaneShell(t *testing.T) {
	a := testApp(t)
	for id, want := range map[string]string{"a": "fish", "b": "zsh", "s1": "fish", "nope": ""} {
		if got := a.paneShell(id); got != want {
			t.Errorf("paneShell(%q) = %q, want %q", id, got, want)
		}
	}
}

// What the toast says depends on why the image could not be saved, and
// each cause the user can mend says how.
func TestPasteImageError(t *testing.T) {
	const dir = "/tmp/kero-paste"
	cases := []struct {
		name string
		err  error
		want []string
	}{
		{"permission", &fs.PathError{Op: "mkdir", Path: dir, Err: syscall.EACCES}, []string{"can’t write to " + dir, "drop the image file"}},
		{"permission wrapped", fmt.Errorf("x: %w", fs.ErrPermission), []string{"can’t write to " + dir}},
		{"disk full", &fs.PathError{Op: "write", Path: dir, Err: syscall.ENOSPC}, []string{"disk is full", "Free some space"}},
		{"other", &fs.PathError{Op: "mkdir", Path: dir, Err: syscall.ENOTDIR}, []string{"not a directory", "drop the image file"}},
	}
	for _, c := range cases {
		got := pasteImageError(c.err, dir)
		for _, w := range c.want {
			if !strings.Contains(got, w) {
				t.Errorf("%s: toast %q lacks %q", c.name, got, w)
			}
		}
		if !strings.HasPrefix(got, "Couldn’t paste the image: ") {
			t.Errorf("%s: toast %q", c.name, got)
		}
	}
	// The disk-full and permission toasts leave the system's wording out.
	if got := pasteImageError(syscall.ENOSPC, dir); strings.Contains(got, "no space left") {
		t.Errorf("toast %q repeats the system's error", got)
	}
}

func jpegData() transfer.Data {
	return transfer.New(transfer.NewItem(transfer.Bytes("image/jpeg", []byte("\xff\xd8JPEG"))))
}

// An image that is not a PNG, as a JPEG some apps copy, pastes as a path
// too, to a file of its own type, and a PNG is preferred to the rest.
func TestPasteImageOtherTypes(t *testing.T) {
	a, sink, dir := pasteApp(t)
	if !a.pasteImage("a", jpegData()) {
		t.Fatal("the paste of a JPEG was left to the terminal")
	}
	files := pastedFiles(t, dir)
	if len(files) != 1 || filepath.Ext(files[0]) != ".jpg" {
		t.Fatalf("pasted files %q, want one .jpg", files)
	}
	if b, _ := os.ReadFile(files[0]); !bytes.Equal(b, []byte("\xff\xd8JPEG")) {
		t.Errorf("the file holds %q", b)
	}
	if got := sink.written(t); got != files[0] {
		t.Errorf("the program got %q, want %q", got, files[0])
	}
	both := transfer.New(transfer.NewItem(
		transfer.Bytes("image/jpeg", []byte("JPEG")), transfer.Bytes(transfer.PNG, fakePNG)))
	if !a.pasteImage("a", both) {
		t.Fatal("the paste was left to the terminal")
	}
	if got := pastedFiles(t, dir); len(got) != 2 || !slices.ContainsFunc(got, func(p string) bool { return filepath.Ext(p) == ".png" }) {
		t.Errorf("pasted files %q, want the PNG too", got)
	}
	if a.pendingToast != "" {
		t.Errorf("toast %q", a.pendingToast)
	}
}

// Every paste of an image that cannot be pasted says why, rather than
// leaving the user with a paste that does nothing.
func TestPasteImageSaysWhyNot(t *testing.T) {
	a, sink, dir := pasteApp(t)
	cases := []struct {
		name string
		d    transfer.Data
		want string
	}{
		{"a clipboard that could not be read", transfer.Data{}, "Couldn’t read the clipboard"},
		{"a type no agent takes", transfer.New(transfer.NewItem(transfer.Bytes("image/avif", []byte("AVIF")))),
			"AVIF isn’t supported. Copy it as PNG or JPEG"},
		{"an image that fails to read", transfer.New(transfer.NewItem(
			transfer.Lazy(transfer.PNG, func() ([]byte, error) { return nil, errors.New("gone") }))), "gone"},
		{"an empty image", transfer.New(transfer.NewItem(transfer.Bytes(transfer.PNG, nil))), "the image is empty"},
	}
	for _, c := range cases {
		a.pendingToast = ""
		if !a.pasteImage("a", c.d) {
			t.Errorf("%s: the paste was left to the terminal", c.name)
		}
		if !strings.Contains(a.pendingToast, c.want) {
			t.Errorf("%s: toast %q lacks %q", c.name, a.pendingToast, c.want)
		}
	}
	if got := pastedFiles(t, dir); len(got) != 0 {
		t.Errorf("files %q written", got)
	}
	if got := sink.quiet(); got != "" {
		t.Errorf("the program got %q", got)
	}
}
