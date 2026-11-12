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
	"kero/internal/settings"
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

// followRoot makes a folder for a follow test, and home, so that the
// repository a temporary folder may be in doesn't hold what is made in it.
func followRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("HOME", root)
	t.Setenv("USERPROFILE", root)
	return root
}

// repoAt makes the folders, and of the first a repository's root.
func repoAt(t *testing.T, repo string, more ...string) {
	t.Helper()
	for _, dir := range append([]string{filepath.Join(repo, ".git")}, more...) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(repo, ".git", "HEAD"), []byte("ref: refs/heads/main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// projectOf returns the project a session is in.
func projectOf(t *testing.T, d *Daemon, s *session) proto.Project {
	t.Helper()
	for _, p := range d.projects {
		if p.ID == s.project {
			return p
		}
	}
	t.Fatalf("session in no project: %q of %+v", s.project, d.projects)
	return proto.Project{}
}

func TestFollowPutsSessionsInTheirFolderProject(t *testing.T) {
	d := projectDaemon(t)
	root := followRoot(t)
	code, app, other := filepath.Join(root, "code"), filepath.Join(root, "code", "app"), filepath.Join(root, "code", "other")
	lib, loose := filepath.Join(app, "lib"), filepath.Join(code, "loose")
	repoAt(t, app, lib, other, loose)
	d.projects = []proto.Project{{ID: "pcode", Name: "code", Dir: code}, {ID: "pother", Name: "other", Dir: other}}
	term := &pane{info: proto.Pane{ID: "t1", Dir: other}}
	web := &pane{info: proto.Pane{ID: "b1", Dir: code, URL: "https://example.com"}}
	s := &session{id: "s1", project: "pcode", panes: []*pane{web, term}, focus: "b1"}
	d.sessions = []*session{s}

	// Not sorted yet: by the terminal's folder, not the browser's, though
	// the browser has the focus.
	if !d.follow() || s.project != "pother" {
		t.Fatalf("after follow, project = %q, want pother", s.project)
	}
	// Moved by hand: it stays while the folder does.
	s.project = "pcode"
	if d.follow() || s.project != "pcode" {
		t.Fatalf("follow moved a session whose folder stayed: project = %q", s.project)
	}
	// In a repository, its root's project: a new one, not code's above it,
	// and the same from deeper in.
	term.info.Dir = lib
	d.follow()
	if p := projectOf(t, d, s); p.Dir != app || p.Name != "app" || !p.Auto {
		t.Fatalf("after cd into app/lib, project = %+v, want a new one for %s", p, app)
	}
	appID := s.project
	term.info.Dir = app
	if d.follow() || s.project != appID {
		t.Fatalf("after cd into app, project = %+v, want app's", projectOf(t, d, s))
	}
	// Out of a repository, the folder's own, not code's above it; and the
	// project made for app, left with no session, goes.
	term.info.Dir = loose
	d.follow()
	if p := projectOf(t, d, s); p.Dir != loose || p.Name != "loose" {
		t.Fatalf("after cd into a loose folder, project = %+v, want a new one for %s", p, loose)
	}
	if slices.ContainsFunc(d.projects, func(p proto.Project) bool { return p.ID == appID }) {
		t.Fatalf("the project made for app outlived its session: %+v", d.projects)
	}
	// The folder of a project, that project. The user's own stay, empty
	// or not.
	term.info.Dir = code
	if !d.follow() || s.project != "pcode" {
		t.Fatalf("after cd into code, project = %+v, want pcode", projectOf(t, d, s))
	}
	if n := len(d.projects); n != 2 || d.projects[0].ID != "pcode" || d.projects[1].ID != "pother" {
		t.Fatalf("projects %+v, want the two there were", d.projects)
	}
}

// A session of panes in several folders goes where a pane of it went, not
// where the user looks: showing another pane, or splitting one off, moves
// nothing.
func TestFollowMovesOnCdNotOnFocus(t *testing.T) {
	d := projectDaemon(t)
	root := followRoot(t)
	a, b, c := filepath.Join(root, "a"), filepath.Join(root, "b"), filepath.Join(root, "c")
	repoAt(t, a, filepath.Join(a, "src"), c)
	repoAt(t, b, filepath.Join(b, "src"))
	p1 := &pane{info: proto.Pane{ID: "p1", Dir: a}}
	p2 := &pane{info: proto.Pane{ID: "p2", Dir: b}}
	s := &session{id: "s1", panes: []*pane{p1, p2}, focus: "p1"}
	d.sessions = []*session{s}

	if !d.follow() || projectOf(t, d, s).Dir != a {
		t.Fatalf("first sorted into %+v, want a's", d.projects)
	}
	s.focus = "p2"
	if d.follow() || projectOf(t, d, s).Dir != a {
		t.Fatalf("showing the other pane moved the session: %+v", projectOf(t, d, s))
	}
	p3 := &pane{info: proto.Pane{ID: "p3", Dir: c}}
	s.panes, s.focus = append(s.panes, p3), "p3"
	if d.follow() || projectOf(t, d, s).Dir != a {
		t.Fatalf("a pane split off elsewhere moved the session: %+v", projectOf(t, d, s))
	}
	// A pane the user is not in goes elsewhere: the session with it, and
	// a's project, which follow made, goes.
	p2.info.Dir = filepath.Join(b, "src")
	if !d.follow() || projectOf(t, d, s).Dir != b || len(d.projects) != 1 {
		t.Fatalf("after cd in the second pane, projects = %+v, want b's alone", d.projects)
	}
	// Two at once: the one the user is in.
	s.focus = "p1"
	p1.info.Dir, p3.info.Dir = c, filepath.Join(a, "src")
	if !d.follow() || projectOf(t, d, s).Dir != c {
		t.Fatalf("after cd in two panes, project = %+v, want c's", projectOf(t, d, s))
	}
}

// A project follow made is the user's once they name it: it stays when
// its session goes.
func TestFollowKeepsAProjectTheUserNamed(t *testing.T) {
	d := projectDaemon(t)
	root := followRoot(t)
	a, b := filepath.Join(root, "a"), filepath.Join(root, "b")
	repoAt(t, a, b)
	term := &pane{info: proto.Pane{ID: "t1", Dir: a}}
	s := &session{id: "s1", panes: []*pane{term}, focus: "t1"}
	d.sessions = []*session{s}
	d.follow()
	made := projectOf(t, d, s)
	raw, _ := json.Marshal(proto.ProjectParams{ID: made.ID, Name: "mine"})
	if _, err := d.call(nil, "project.rename", raw); err != nil {
		t.Fatal(err)
	}
	term.info.Dir = b
	d.follow()
	if len(d.projects) != 2 || d.projects[0].Name != "mine" || d.projects[0].Auto {
		t.Fatalf("projects %+v, want mine kept beside b's", d.projects)
	}
}

func TestFollowPutsAWorktreeInItsRepositorysProject(t *testing.T) {
	d := projectDaemon(t)
	root := followRoot(t)
	repo, wt := filepath.Join(root, "repo"), filepath.Join(root, "trees", "repo-feature")
	gitdir := filepath.Join(repo, ".git", "worktrees", "repo-feature")
	repoAt(t, repo, gitdir, wt)
	if err := os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: "+gitdir+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitdir, "commondir"), []byte("../..\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.projects = []proto.Project{{ID: "prepo", Name: "repo", Dir: repo}}
	if got := d.folderProject(repoRoot(wt)); got != "prepo" {
		t.Fatalf("folderProject(worktree) = %q (projects %+v), want prepo", got, d.projects)
	}
}

// A folder named .git that holds no repository makes none of the folder
// it is in.
func TestRepoRootWantsARepository(t *testing.T) {
	root := followRoot(t)
	sub := filepath.Join(root, "stray", "sub")
	for _, dir := range []string{filepath.Join(root, "stray", ".git"), sub} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if got := repoRoot(sub); got != sub {
		t.Fatalf("repoRoot under a stray .git = %s, want %s", got, sub)
	}
}

// With sessions-follow-directory, a session starts in its folder's own
// project, whatever project was asked for, and counts as sorted; one that
// names no folder starts in the project asked for.
func TestCreateStartsInTheFolderProject(t *testing.T) {
	d := testDaemon(t)
	root := followRoot(t)
	repo, sub := filepath.Join(root, "repo"), filepath.Join(root, "repo", "sub")
	repoAt(t, repo, sub)
	set := settings.Load()
	set.SessionsFollowDir = true
	if err := settings.Save(set); err != nil {
		t.Fatal(err)
	}
	info, err := d.create(proto.CreateParams{Project: "pr", Dir: sub, URL: "localhost:3000"})
	if err != nil {
		t.Fatal(err)
	}
	s := d.sessions[0]
	if p := projectOf(t, d, s); p.Dir != repo || !p.Auto || info.Project != p.ID {
		t.Fatalf("started in %+v, want a new project for %s", p, repo)
	}
	if s.followed != sub {
		t.Fatalf("followed = %q, want %s", s.followed, sub)
	}
	if d.follow() {
		t.Fatal("follow moved a session just started")
	}
	info, err = d.create(proto.CreateParams{Project: "pr", URL: "localhost:3000"})
	if err != nil {
		t.Fatal(err)
	}
	if info.Project != "pr" {
		t.Fatalf("with no folder, started in %q, want pr", info.Project)
	}
}

// What follow sorted a session by outlives kerod, so that the next one
// doesn't sort again a session the user moved.
func TestFollowedOutlivesKerod(t *testing.T) {
	d := testDaemon(t)
	if _, err := d.create(proto.CreateParams{URL: "localhost:3000"}); err != nil {
		t.Fatal(err)
	}
	d.sessions[0].followed = "/somewhere"
	d.saveState()
	restored := &Daemon{dir: d.dir, log: d.log, panes: map[string]*pane{}}
	restored.viewed.Store(new(string))
	restored.restore()
	if len(restored.sessions) != 1 || restored.sessions[0].followed != "/somewhere" {
		t.Fatalf("restored %+v", restored.sessions)
	}
}

// project.close with Empty leaves a project that holds a session, and
// the session.
func TestProjectCloseEmpty(t *testing.T) {
	d := testDaemon(t)
	d.projects = append(d.projects, proto.Project{ID: "p2", Name: "empty"})
	if _, err := d.create(proto.CreateParams{Project: "pr", URL: "localhost:3000"}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"pr", "p2"} {
		raw, _ := json.Marshal(proto.CloseProjectParams{ID: id, Empty: true})
		if _, err := d.call(nil, "project.close", raw); err != nil {
			t.Fatal(err)
		}
	}
	if len(d.projects) != 1 || d.projects[0].ID != "pr" || len(d.sessions) != 1 {
		t.Fatalf("projects %+v, %d sessions: want pr and its session", d.projects, len(d.sessions))
	}
}

// project.move puts a project at another index, past either end at that
// end, and the order outlives kerod.
func TestProjectMovePersists(t *testing.T) {
	d := projectDaemon(t)
	var ids []string
	for _, name := range []string{"a", "b", "c"} {
		p, err := createProject(t, d, proto.ProjectParams{Name: name})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, p.ID)
	}
	move := func(id string, index int) {
		raw, _ := json.Marshal(proto.MoveProjectParams{ID: id, Index: index})
		if _, err := d.call(nil, "project.move", raw); err != nil {
			t.Fatal(err)
		}
	}
	order := func(st proto.State) []string {
		var got []string
		for _, p := range st.Projects {
			got = append(got, p.Name)
		}
		return got
	}
	move(ids[2], 0)
	if got := order(d.state()); !slices.Equal(got, []string{"c", "a", "b"}) {
		t.Errorf("c to the top: %v", got)
	}
	move(ids[2], 99)
	if got := order(d.state()); !slices.Equal(got, []string{"a", "b", "c"}) {
		t.Errorf("c past the end: %v", got)
	}
	move(ids[0], 1)
	d.saveState()
	restored := &Daemon{dir: d.dir}
	restored.viewed.Store(new(string))
	restored.restore()
	if got := order(restored.state()); !slices.Equal(got, []string{"b", "a", "c"}) {
		t.Errorf("restored order %v, want b a c", got)
	}
}
