package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"sync"
	"testing"

	"kero/internal/proto"
)

func projectDaemon(t *testing.T) *Daemon {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("KERO_CONFIG", filepath.Join(dir, "config"))
	d := &Daemon{dir: dir, changeCh: make(chan struct{}, 1), saveCh: make(chan struct{}, 1)}
	d.viewed.Store(new(string))
	return d
}

func createProject(t *testing.T, d *Daemon, p proto.ProjectParams) (proto.Project, error) {
	t.Helper()
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	result, err := d.call(nil, "project.create", raw)
	if err != nil {
		return proto.Project{}, err
	}
	return result.(proto.Project), nil
}

func TestProjectCreateRejectsInvalidDirectories(t *testing.T) {
	d := projectDaemon(t)
	file := filepath.Join(t.TempDir(), "file.txt")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{file, filepath.Join(t.TempDir(), "missing")} {
		if p, err := createProject(t, d, proto.ProjectParams{Dir: dir}); err == nil {
			t.Errorf("project.create(%q) = %+v, want an error", dir, p)
		}
	}
	if got := d.state().Projects; len(got) != 0 {
		t.Errorf("projects after invalid drops = %+v, want none", got)
	}
}

func TestProjectCreateMatchesFolderPickerPackages(t *testing.T) {
	for _, tc := range []struct {
		name     string
		packaged bool
	}{
		{"ordinary folder", false},
		{"application.app-sources", false},
		{"Application.app/Contents/project", false},
		{"日本語 Application.app", true},
		{"Application.APP", true},
		{"Plugin.bundle", true},
		{"Document.rtfd", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := projectDaemon(t)
			dir := filepath.Join(t.TempDir(), tc.name)
			if err := os.MkdirAll(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			wantErr := runtime.GOOS == "darwin" && tc.packaged
			first, err := createProject(t, d, proto.ProjectParams{Dir: dir})
			if (err != nil) != wantErr {
				t.Fatalf("project.create(%q) = %+v, %v, want error %t", dir, first, err, wantErr)
			}
			if wantErr && len(d.state().Projects) != 0 {
				t.Fatal("a rejected file package registered a project")
			}
			t.Run("symlink", func(t *testing.T) {
				link := filepath.Join(t.TempDir(), "alias without a package extension")
				if err := os.Symlink(dir, link); err != nil {
					t.Skipf("directory symlinks unavailable: %v", err)
				}
				got, err := createProject(t, d, proto.ProjectParams{Dir: link})
				if (err != nil) != wantErr {
					t.Fatalf("project.create(%q) = %+v, %v, want error %t", link, got, err, wantErr)
				}
				if !wantErr && got != first {
					t.Errorf("symlink project = %+v, want %+v", got, first)
				}
				if wantErr && len(d.state().Projects) != 0 {
					t.Fatal("a symlink to a rejected file package registered a project")
				}
			})
		})
	}
}

func TestProjectCreateReusesDirectoryAliases(t *testing.T) {
	d := projectDaemon(t)
	name := "日本語 # % project"
	if runtime.GOOS != "windows" {
		name += " "
	}
	dir := filepath.Join(t.TempDir(), name)
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	first, err := createProject(t, d, proto.ProjectParams{Dir: dir, Name: "My project"})
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(dir, link); err != nil {
		t.Skipf("directory symlinks unavailable: %v", err)
	}
	for _, alias := range []string{dir, dir + string(os.PathSeparator), link} {
		got, err := createProject(t, d, proto.ProjectParams{Dir: alias})
		if err != nil || got != first {
			t.Errorf("project.create(%q) = %+v, %v, want %+v", alias, got, err, first)
		}
	}
	if got := d.state().Projects; !slices.Equal(got, []proto.Project{first}) {
		t.Errorf("projects after aliases = %+v, want [%+v]", got, first)
	}
}

func TestProjectCreateConcurrentAliases(t *testing.T) {
	d := projectDaemon(t)
	dir := t.TempDir()
	link := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(dir, link); err != nil {
		t.Logf("directory symlinks unavailable; using a trailing separator: %v", err)
		link = dir + string(os.PathSeparator)
	}
	ids := make([]string, 24)
	var wg sync.WaitGroup
	for i := range ids {
		path := dir
		if i%2 != 0 {
			path = link
		}
		raw, err := json.Marshal(proto.ProjectParams{Dir: path})
		if err != nil {
			t.Fatal(err)
		}
		wg.Go(func() {
			p, err := d.call(nil, "project.create", raw)
			if err != nil {
				t.Errorf("concurrent project.create(%q): %v", path, err)
				return
			}
			ids[i] = p.(proto.Project).ID
		})
	}
	wg.Wait()
	for _, id := range ids {
		if id == "" || id != ids[0] {
			t.Errorf("concurrent project IDs = %v, want one nonempty ID", ids)
			break
		}
	}
	if got := d.state().Projects; len(got) != 1 {
		t.Errorf("projects after concurrent aliases = %+v, want one", got)
	}
}

func TestProjectCreateRejectsInaccessibleDirectories(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("requires Unix directory permissions without root privileges")
	}
	for _, mode := range []os.FileMode{0, 0o400, 0o100} {
		t.Run(mode.String(), func(t *testing.T) {
			d := projectDaemon(t)
			dir := t.TempDir()
			if err := os.Chmod(dir, mode); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { os.Chmod(dir, 0o700) })
			if p, err := createProject(t, d, proto.ProjectParams{Dir: dir}); err == nil {
				t.Errorf("project.create(%q, mode %v) = %+v, want an error", dir, mode, p)
			}
			if got := d.state().Projects; len(got) != 0 {
				t.Errorf("projects after inaccessible drop = %+v, want none", got)
			}
		})
	}
}

func TestProjectCreateRejectsInvalidSymlinks(t *testing.T) {
	d := projectDaemon(t)
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{file, filepath.Join(t.TempDir(), "missing")} {
		link := filepath.Join(t.TempDir(), "alias")
		if err := os.Symlink(target, link); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		if p, err := createProject(t, d, proto.ProjectParams{Dir: link}); err == nil {
			t.Errorf("project.create(symlink to %q) = %+v, want an error", target, p)
		}
	}
}

func TestProjectCreateNormalizesRelativeDirectory(t *testing.T) {
	d := projectDaemon(t)
	dir := t.TempDir()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	rel, err := filepath.Rel(cwd, dir)
	if err != nil {
		t.Fatal(err)
	}
	p, err := createProject(t, d, proto.ProjectParams{Dir: rel})
	if err != nil || p.Dir != dir {
		t.Errorf("project.create(%q) = %+v, %v, want directory %q", rel, p, err, dir)
	}
}

func TestProjectCreateKeepsDistinctDirectories(t *testing.T) {
	d := projectDaemon(t)
	var ids []string
	for range 2 {
		dir := filepath.Join(t.TempDir(), "same-name")
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		p, err := createProject(t, d, proto.ProjectParams{Dir: dir})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, p.ID)
	}
	if ids[0] == ids[1] || len(d.state().Projects) != 2 {
		t.Errorf("distinct directories with the same name have IDs %v, want two projects", ids)
	}
}

func TestProjectCreateReusesDirectoryCase(t *testing.T) {
	d := projectDaemon(t)
	parent := t.TempDir()
	dir, alias := filepath.Join(parent, "Project"), filepath.Join(parent, "project")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(alias); os.IsNotExist(err) {
		t.Skip("case-sensitive filesystem")
	} else if err != nil {
		t.Fatal(err)
	}
	first, err := createProject(t, d, proto.ProjectParams{Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	got, err := createProject(t, d, proto.ProjectParams{Dir: alias})
	if err != nil || got != first {
		t.Errorf("project.create(%q) = %+v, %v, want %+v", alias, got, err, first)
	}
}

func TestProjectCreateNameOnly(t *testing.T) {
	d := projectDaemon(t)
	p, err := createProject(t, d, proto.ProjectParams{Name: "Named project"})
	if err != nil || p.ID == "" || p.Name != "Named project" || p.Dir != "" {
		t.Errorf("name-only project.create = %+v, %v, want a named project without a directory", p, err)
	}
}

func TestProjectCreatePersists(t *testing.T) {
	d := projectDaemon(t)
	first, err := createProject(t, d, proto.ProjectParams{Dir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	d.saveState()
	restored := &Daemon{dir: d.dir}
	restored.viewed.Store(new(string))
	restored.restore()
	if got := restored.state().Projects; !slices.Equal(got, []proto.Project{first}) {
		t.Errorf("restored projects = %+v, want [%+v]", got, first)
	}
}
