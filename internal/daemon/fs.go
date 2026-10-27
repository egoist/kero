package daemon

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"kero/internal/proto"
)

// The methods a client on another machine sees the host's files through:
// a folder to open a project in, a path a pane printed, an image to
// preview, a file pasted into a pane. They read and write what the user
// kerod runs as can, as the panes' programs do.

// maxEntries bounds a directory's listing.
const maxEntries = 5000

// hostPath makes a path of the host absolute: ~ and ~/… are the home's, a
// relative one is base's (the home's when base is "").
func hostPath(p, base string) string {
	p = strings.TrimSpace(p)
	switch {
	case p == "" || p == "~":
		return proto.Home()
	case strings.HasPrefix(p, "~/") || runtime.GOOS == "windows" && strings.HasPrefix(p, `~\`):
		return filepath.Join(proto.Home(), p[2:])
	case filepath.IsAbs(p):
		return filepath.Clean(p)
	}
	if base == "" {
		base = proto.Home()
	}
	return filepath.Join(hostPath(base, ""), p)
}

func fsList(p proto.FSListParams) (proto.FSList, error) {
	dir := hostPath(p.Dir, "")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return proto.FSList{}, err
	}
	out := proto.FSList{Dir: dir, Home: proto.Home(), Entries: []proto.FSEntry{}}
	if parent := filepath.Dir(dir); parent != dir {
		out.Parent = parent
	}
	repos := 0
	for _, e := range entries {
		name := e.Name()
		if !p.Hidden && strings.HasPrefix(name, ".") {
			continue
		}
		fe := proto.FSEntry{Name: name, Dir: e.IsDir()}
		if e.Type()&os.ModeSymlink != 0 {
			if st, err := os.Stat(filepath.Join(dir, name)); err == nil {
				fe.Dir = st.IsDir()
			}
		}
		if fe.Dir && repos < 500 {
			repos++
			if _, err := os.Stat(filepath.Join(dir, name, ".git")); err == nil {
				fe.Repo = true
			}
		}
		out.Entries = append(out.Entries, fe)
		if len(out.Entries) >= maxEntries {
			break
		}
	}
	slices.SortFunc(out.Entries, func(a, b proto.FSEntry) int {
		if a.Dir != b.Dir {
			if a.Dir {
				return -1
			}
			return 1
		}
		return strings.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name))
	})
	return out, nil
}

func fsStat(p proto.FSStatParams) proto.FSStat {
	path := hostPath(p.Path, p.Base)
	st, err := os.Stat(path)
	if err != nil {
		return proto.FSStat{Path: path}
	}
	return proto.FSStat{Path: path, Exists: true, Dir: st.IsDir(), Size: st.Size()}
}

// maxRead bounds what fs.read reads: an image to preview.
const maxRead = 32 << 20

func fsRead(p proto.FSReadParams) (proto.FSRead, error) {
	limit := p.Max
	if limit <= 0 || limit > maxRead {
		limit = maxRead
	}
	f, err := os.Open(hostPath(p.Path, ""))
	if err != nil {
		return proto.FSRead{}, err
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil || st.IsDir() {
		return proto.FSRead{}, fmt.Errorf("%s is no file", p.Path)
	} else if st.Size() > limit {
		return proto.FSRead{}, fmt.Errorf("%s is larger than %d bytes", p.Path, limit)
	}
	b, err := io.ReadAll(io.LimitReader(f, limit))
	return proto.FSRead{Data: b}, err
}

// maxPaste bounds a pasted file, which comes in a request of a control
// connection, base64 (proto.MaxLine).
const maxPaste = 32 << 20

// pasteDir is where files pasted into panes go: a directory of the
// user's alone, in $XDG_RUNTIME_DIR, else in the temporary directory,
// which the system empties. Each level is made private, or checked to be:
// a directory of the shared temporary one that someone else made, or that
// others may write to, is refused.
func pasteDir() (string, error) {
	base := filepath.Join(os.TempDir(), "kero")
	if uid := os.Getuid(); uid >= 0 {
		base = filepath.Join(os.TempDir(), fmt.Sprintf("kero-%d", uid))
	}
	if rt := os.Getenv("XDG_RUNTIME_DIR"); rt != "" {
		if st, err := os.Stat(rt); err == nil && st.IsDir() {
			base = filepath.Join(rt, "kero")
		}
	}
	dir := filepath.Join(base, "paste")
	for _, d := range []string{base, dir} {
		if err := privateDir(d); err != nil {
			return "", err
		}
	}
	return dir, nil
}

// privateDir makes a directory only its user reaches, or checks that one
// is: never through a link, never one of another user's.
func privateDir(dir string) error {
	st, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		st, err = os.Lstat(dir)
	}
	if err != nil {
		return err
	}
	if !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || !ownedByUser(st) {
		return errors.New("the directory for pasted files is not yours alone: " + dir)
	}
	if runtime.GOOS != "windows" && st.Mode().Perm()&0o077 != 0 {
		return os.Chmod(dir, 0o700)
	}
	return nil
}

// pasteFile puts a file pasted into a pane on this machine, where its
// program reads it, under a name of its own, and lets go of those older
// than a week.
func pasteFile(p proto.PasteFileParams) (proto.PasteFile, error) {
	if len(p.Data) > maxPaste {
		return proto.PasteFile{}, fmt.Errorf("a pasted file is at most %d MB", maxPaste>>20)
	}
	// Its last element, of no directory, with nothing a shell or a system
	// would take otherwise.
	name := path.Base(path.Clean("/" + strings.ReplaceAll(p.Name, `\`, "/")))
	if name == "/" {
		name = "pasted"
	}
	name = strings.Map(func(r rune) rune {
		if r < ' ' || strings.ContainsRune(`/\:*?"<>|`, r) {
			return '_'
		}
		return r
	}, name)
	dir, err := pasteDir()
	if err != nil {
		return proto.PasteFile{}, err
	}
	now := time.Now()
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) > 7*24*time.Hour {
				os.RemoveAll(filepath.Join(dir, e.Name()))
			}
		}
	}
	sub, err := os.MkdirTemp(dir, now.Format("20060102-150405-"))
	if err != nil {
		return proto.PasteFile{}, err
	}
	path := filepath.Join(sub, name)
	if err := os.WriteFile(path, p.Data, 0o600); err != nil {
		return proto.PasteFile{}, err
	}
	return proto.PasteFile{Path: path}, nil
}
