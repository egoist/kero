package daemon

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"kero/internal/git"
	"kero/internal/proto"
)

func TestHostPath(t *testing.T) {
	home := proto.Home()
	abs := filepath.Join(home, "x")
	for in, want := range map[[2]string]string{
		{"", ""}:             home,
		{"~", ""}:            home,
		{"~/code", ""}:       filepath.Join(home, "code"),
		{abs, "/elsewhere"}:  abs,
		{"src/a.go", abs}:    filepath.Join(abs, "src", "a.go"),
		{"src/a.go", ""}:     filepath.Join(home, "src", "a.go"),
		{"../y", abs}:        filepath.Join(home, "y"),
		{"lib", "~/project"}: filepath.Join(home, "project", "lib"),
	} {
		if got := hostPath(in[0], in[1]); got != want {
			t.Errorf("hostPath(%q, %q) = %q, want %q", in[0], in[1], got, want)
		}
	}
}

func TestFSListAndStat(t *testing.T) {
	dir := t.TempDir()
	for _, d := range []string{"b-dir", "A-dir", ".hidden", "repo/.git"} {
		os.MkdirAll(filepath.Join(dir, d), 0o755)
	}
	os.WriteFile(filepath.Join(dir, "file.txt"), []byte("hi"), 0o644)
	l, err := fsList(proto.FSListParams{Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range l.Entries {
		names = append(names, e.Name)
		if e.Name == "repo" && !e.Repo {
			t.Error("repo is not a repository")
		}
	}
	if got := strings.Join(names, ","); got != "A-dir,b-dir,repo,file.txt" {
		t.Errorf("listed %s", got)
	}
	if l.Parent != filepath.Dir(dir) || l.Dir != dir {
		t.Errorf("dir %q, parent %q", l.Dir, l.Parent)
	}
	if l, _ := fsList(proto.FSListParams{Dir: dir, Hidden: true}); len(l.Entries) != 5 {
		t.Errorf("with hidden: %d entries", len(l.Entries))
	}
	if _, err := fsList(proto.FSListParams{Dir: filepath.Join(dir, "none")}); err == nil {
		t.Error("listed a directory that is none")
	}
	st := fsStat(proto.FSStatParams{Path: "file.txt", Base: dir})
	if !st.Exists || st.Dir || st.Size != 2 || st.Path != filepath.Join(dir, "file.txt") {
		t.Errorf("stat %+v", st)
	}
	if st := fsStat(proto.FSStatParams{Path: "nope", Base: dir}); st.Exists {
		t.Errorf("stat of nothing %+v", st)
	}
	if r, err := fsRead(proto.FSReadParams{Path: filepath.Join(dir, "file.txt")}); err != nil || string(r.Data) != "hi" {
		t.Errorf("read %q, %v", r.Data, err)
	}
	if _, err := fsRead(proto.FSReadParams{Path: filepath.Join(dir, "file.txt"), Max: 1}); err == nil {
		t.Error("read past Max")
	}
	if _, err := fsRead(proto.FSReadParams{Path: dir}); err == nil {
		t.Error("read a directory")
	}
}

func TestPasteFile(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	t.Setenv("XDG_RUNTIME_DIR", "")
	if runtime.GOOS == "windows" {
		t.Setenv("TMP", tmp)
		t.Setenv("TEMP", tmp)
	}
	r, err := pasteFile(proto.PasteFileParams{Name: "../../etc/shot one.png", Data: []byte("png")})
	if err != nil {
		t.Fatal(err)
	}
	dir, _ := pasteDir()
	if !strings.HasPrefix(r.Path, dir) || filepath.Base(r.Path) != "shot one.png" {
		t.Errorf("pasted at %s, not in %s", r.Path, dir)
	}
	if b, _ := os.ReadFile(r.Path); string(b) != "png" {
		t.Errorf("pasted %q", b)
	}
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(filepath.Dir(filepath.Dir(r.Path))); st.Mode().Perm() != 0o700 {
			t.Errorf("the paste directory is %v", st.Mode().Perm())
		}
	}
	// Two of one name stay apart.
	r2, _ := pasteFile(proto.PasteFileParams{Name: "shot one.png", Data: []byte("2")})
	if r2.Path == r.Path {
		t.Error("a second paste of a name took the first's place")
	}
	if _, err := pasteFile(proto.PasteFileParams{Name: "big", Data: make([]byte, maxPaste+1)}); err == nil {
		t.Error("pasted a file past the limit")
	}
	if r, _ := pasteFile(proto.PasteFileParams{Name: "", Data: []byte("x")}); filepath.Base(r.Path) != "pasted" {
		t.Errorf("a file of no name pasted as %s", r.Path)
	}
}

// A paste directory someone else could reach is made private, or refused
// when it is not the user's to make so.
func TestPasteDirPrivate(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permissions are Unix's")
	}
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	t.Setenv("XDG_RUNTIME_DIR", "")
	base := filepath.Join(tmp, fmt.Sprintf("kero-%d", os.Getuid()))
	os.Mkdir(base, 0o777)
	os.Chmod(base, 0o777)
	if _, err := pasteDir(); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(base); st.Mode().Perm() != 0o700 {
		t.Errorf("the base is %v", st.Mode().Perm())
	}
	// A link where the directory goes, as another user could plant.
	os.RemoveAll(base)
	os.Symlink(t.TempDir(), base)
	if _, err := pasteDir(); err == nil {
		t.Error("pasted through a link")
	}
}

// Asked, fs.list marks what git ignores in a worktree, and nothing
// outside one.
func TestFSListIgnored(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	dir := t.TempDir()
	if out, err := exec.Command("git", "init", "-q", dir).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, out)
	}
	os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("node_modules/\n*.log\n"), 0o644)
	os.MkdirAll(filepath.Join(dir, "node_modules", "x"), 0o755)
	os.MkdirAll(filepath.Join(dir, "src"), 0o755)
	os.WriteFile(filepath.Join(dir, "debug.log"), nil, 0o644)
	os.WriteFile(filepath.Join(dir, "main.go"), nil, 0o644)
	l, err := fsList(proto.FSListParams{Dir: dir, Hidden: true, Ignored: true})
	if err != nil {
		t.Fatal(err)
	}
	var ignored []string
	for _, e := range l.Entries {
		if e.Ignored {
			ignored = append(ignored, e.Name)
		}
	}
	if got := strings.Join(ignored, ","); got != "node_modules,debug.log" {
		t.Errorf("ignored %q, want node_modules,debug.log", got)
	}
	if l, err := fsList(proto.FSListParams{Dir: t.TempDir(), Ignored: true}); err != nil || len(l.Entries) != 0 {
		t.Errorf("outside a worktree: %v, %v", l.Entries, err)
	}
}

// fs.write writes a file as it was read, keeping its mode, but not one
// changed meanwhile, unless forced.
func TestFSWrite(t *testing.T) {
	p := testPane(t)
	d := p.d
	dir := t.TempDir()
	file := filepath.Join(dir, "a.sh")
	os.WriteFile(file, []byte("echo a\n"), 0o755)
	d.panes = map[string]*pane{"p": p}
	p.info.Dir = dir

	h, err := d.fsWrite(proto.FSWriteParams{Path: file, Hash: git.Hash([]byte("echo a\n")), Text: "echo b\n"})
	if b, _ := os.ReadFile(file); err != nil || string(b) != "echo b\n" || h != git.Hash(b) {
		t.Fatalf("wrote %q, %q, %v", b, h, err)
	}
	if st, _ := os.Stat(file); st.Mode().Perm() != 0o755 {
		t.Errorf("the mode is %v", st.Mode().Perm())
	}
	if _, err := d.fsWrite(proto.FSWriteParams{Path: file, Hash: git.Hash([]byte("echo a\n")), Text: "echo c\n"}); !errors.Is(err, git.ErrChanged) {
		t.Errorf("wrote over a file changed meanwhile: %v", err)
	}
	if b, _ := os.ReadFile(file); string(b) != "echo b\n" {
		t.Errorf("the file is %q", b)
	}
	if _, err := d.fsWrite(proto.FSWriteParams{Path: file, Hash: "stale", Text: "echo c\n", Force: true}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(file); string(b) != "echo c\n" {
		t.Errorf("forced, the file is %q", b)
	}
	_ = h
}

// fs.create makes a file or a folder, with the folders it is in, but none
// there already; fs.rename moves one where nothing is, or to another case
// of its name; fs.delete deletes one and what is in it; none of the three
// touches a volume's root or the home.
func TestFSCreateRenameDelete(t *testing.T) {
	d := testPane(t).d
	dir := t.TempDir()
	file := filepath.Join(dir, "src", "a.go")
	if err := d.fsCreate(proto.FSCreateParams{Path: file}); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(file); err != nil || st.Size() != 0 || st.IsDir() {
		t.Fatalf("made %v, %v", st, err)
	}
	if err := d.fsCreate(proto.FSCreateParams{Path: file}); err == nil {
		t.Error("made a file over one there")
	}
	if err := d.fsCreate(proto.FSCreateParams{Path: filepath.Join(dir, "docs"), Dir: true}); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(filepath.Join(dir, "docs")); err != nil || !st.IsDir() {
		t.Errorf("made %v, %v", st, err)
	}

	os.WriteFile(filepath.Join(dir, "b.go"), []byte("b"), 0o644)
	if err := d.fsRename(proto.FSRenameParams{From: file, To: filepath.Join(dir, "b.go")}); err == nil {
		t.Error("renamed over a file there")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "b.go")); string(b) != "b" {
		t.Error("renaming over b.go changed it")
	}
	moved := filepath.Join(dir, "docs", "c.go")
	if err := d.fsRename(proto.FSRenameParams{From: file, To: moved}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(moved); err != nil {
		t.Error(err)
	}
	if err := d.fsRename(proto.FSRenameParams{From: moved, To: filepath.Join(dir, "docs", "C.go")}); err != nil {
		t.Errorf("renaming to another case: %v", err)
	}

	if err := d.fsDelete(proto.FSDeleteParams{Path: filepath.Join(dir, "docs")}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "docs")); !os.IsNotExist(err) {
		t.Error("the folder stayed")
	}
	for _, p := range []string{"/", proto.Home(), "relative/x"} {
		if err := d.fsDelete(proto.FSDeleteParams{Path: p}); err == nil {
			t.Errorf("deleted %q", p)
		}
	}
}
