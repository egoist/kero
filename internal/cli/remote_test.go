package cli

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"kero/internal/client"
)

// A host's kerod, whose state could not be read, is said: "0 sessions"
// would tell the user theirs were gone.
func TestHostsCheckSaysAFailedState(t *testing.T) {
	t.Setenv("KERO_CONFIG", filepath.Join(t.TempDir(), "config"))
	sock, _ := fakeDaemon(t)
	t.Setenv("KERO_SOCKET", sock)
	failCall(t, "state", "the state is gone")
	c, err := client.ConnectVia(client.Local{NoStart: true})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	out := captureStdout(t, func() { hostDaemonState(c) })
	if !strings.Contains(out, "the state is gone") {
		t.Errorf("no word of the state that failed:\n%s", out)
	}
	if strings.Contains(out, "sessions") {
		t.Errorf("it counted the sessions it has none of:\n%s", out)
	}
}

func TestSplitHost(t *testing.T) {
	t.Setenv("KERO_HOST", "")
	for _, c := range []struct {
		args []string
		host string
		rest []string
	}{
		{[]string{"ls"}, "", []string{"ls"}},
		{[]string{"-H", "build", "ls", "-j"}, "build", []string{"ls", "-j"}},
		{[]string{"--host", "me@devbox", "new"}, "me@devbox", []string{"new"}},
		{[]string{"--host=wsl://Ubuntu", "ls"}, "wsl://Ubuntu", []string{"ls"}},
		{[]string{"-Hbuild", "ls"}, "build", []string{"ls"}},
		{[]string{"-H", "local", "ls"}, "", []string{"ls"}},
		// A -H after the command is the command's.
		{[]string{"send", "x", "-H"}, "", []string{"send", "x", "-H"}},
	} {
		host, _, rest, err := splitHost(c.args)
		if err != nil || host != c.host || !slices.Equal(rest, c.rest) {
			t.Errorf("%q: %q %q %v", c.args, host, rest, err)
		}
	}
	t.Setenv("KERO_HOST", "build")
	if host, env, _, _ := splitHost([]string{"ls"}); host != "build" || !env {
		t.Errorf("$KERO_HOST: %q", host)
	}
	if host, env, _, _ := splitHost([]string{"-H", "other", "ls"}); host != "other" || env {
		t.Errorf("-H over $KERO_HOST: %q", host)
	}
	for _, bad := range [][]string{{"-H"}, {"-H", "build"}} {
		if _, _, _, err := splitHost(bad); err == nil {
			t.Errorf("%q: no error", bad)
		}
	}
}

func TestIsCommand(t *testing.T) {
	for arg, want := range map[string]bool{"ls": true, "-H": true, "--host=x": true, "-Hbuild": true, "hosts": true, "__bridge": true, "-psn_0_1": false, "": false} {
		if IsCommand(arg) != want {
			t.Errorf("IsCommand(%q) = %v", arg, !want)
		}
	}
}

func TestRemoteRepoPath(t *testing.T) {
	for in, want := range map[string]string{
		"":                  "",
		"src/a.go":          "src/a.go",
		`src\a.go`:          "src/a.go",
		"/srv/app/src/a.go": "src/a.go",
		"../../etc/passwd":  "etc/passwd",
	} {
		got, err := repoPath("/srv/app", in, true)
		if err != nil || got != want {
			t.Errorf("repoPath(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := repoPath("/srv/app", "/etc/passwd", true); err == nil {
		t.Error("a path outside the worktree passes")
	}
	// The worktree itself is every file of it, as it is of this machine.
	for _, root := range []string{"/srv/app", `C:\srv\app`} {
		got, err := repoPath(root, root, true)
		if err != nil || got != "" {
			t.Errorf("repoPath(%q, %q) = %q, %v; want the empty path", root, root, got, err)
		}
	}
	// A Windows host's worktree root has backslashes, and a path given of
	// it may be a Windows one.
	for in, want := range map[string]string{
		`src\a.go`:            "src/a.go",
		`C:\srv\app\src\a.go`: "src/a.go",
		`C:/srv/app/src/a.go`: "src/a.go",
	} {
		got, err := repoPath(`C:\srv\app`, in, true)
		if err != nil || got != want {
			t.Errorf("repoPath(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	// A Windows path of another tree is absolute as any other, and is
	// not of the worktree.
	for _, in := range []string{`C:\etc\passwd`, "C:/etc/passwd", `D:\srv\app\src\a.go`} {
		if got, err := repoPath(`C:\srv\app`, in, true); err == nil {
			t.Errorf("repoPath(%q) = %q, no error; want an error", in, got)
		}
	}
}

// Inside a pane, $KERO_HOST, which a profile may set, gives way to the
// pane's machine; a command of this machine alone ignores it.
func TestKeroHostScope(t *testing.T) {
	t.Setenv("KERO_HOST", "build")
	t.Setenv("KERO_PANE", "p1")
	if host, _, _, _ := splitHost([]string{"ls"}); host != "" {
		t.Errorf("inside a pane: %q", host)
	}
	if host, _, _, _ := splitHost([]string{"-H", "build", "ls"}); host != "build" {
		t.Errorf("-H inside a pane: %q", host)
	}
	t.Setenv("KERO_PANE", "")
	if !localOnly["hook"] || !localOnly["config"] || localOnly["ls"] {
		t.Error("localOnly")
	}
	onHost = "build"
	defer func() { onHost = "" }()
	t.Setenv("KERO_PANE", "p1")
	if current() != "" {
		t.Error("a pane of this machine named on another")
	}
}
