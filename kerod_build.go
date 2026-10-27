package main

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
	"go/build/constraint"
	"io/fs"
	"path"
	"runtime"
	"runtime/debug"
	"slices"
	"strings"

	"github.com/egoist/mygo"

	"kero/internal/build"
)

// kerodSource is the code of Kero's packages that kerod runs (go list
// -deps ./internal/daemon), which TestKerodSource keeps whole.
//
//go:embed internal/actions internal/adblock internal/build internal/clilink internal/daemon internal/detach internal/detect internal/git internal/proto internal/remote internal/settings internal/shell internal/tailscale internal/update
var kerodSource embed.FS

// kerodModules are the other modules whose code kerod runs, which
// TestKerodSource keeps whole too.
var kerodModules = []string{
	"github.com/BurntSushi/toml",
	"github.com/coder/websocket",
	"github.com/ebitengine/purego",
	"github.com/egoist/mygo",
	"github.com/go-text/typesetting",
	"github.com/hashicorp/yamux",
	"golang.org/x/image",
	"golang.org/x/net",
	"golang.org/x/sys",
	"golang.org/x/text",
}

func init() { build.Daemon = kerodBuild() }

// kerodBuild fingerprints the code kerod runs on this platform: its
// packages' files, less tests and files of other platforms, the versions
// of its modules, and Go's.
func kerodBuild() string {
	h := sha256.New()
	fmt.Fprintln(h, runtime.Version())
	fs.WalkDir(kerodSource, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "testdata" {
				return fs.SkipDir
			}
			return nil
		}
		b, err := kerodSource.ReadFile(p)
		if err != nil || !builds(p, b) {
			return err
		}
		fmt.Fprintln(h, p, len(b))
		h.Write(b)
		return nil
	})
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, m := range bi.Deps {
			if slices.Contains(kerodModules, m.Path) {
				if m.Replace != nil {
					m = m.Replace
				}
				fmt.Fprintln(h, m.Path, m.Version, m.Sum)
			}
		}
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// goos are the platforms a file's name or build constraint can name, and
// the ones of them that the unix constraint means.
var (
	goos     = []string{"aix", "android", "darwin", "dragonfly", "freebsd", "illumos", "ios", "js", "linux", "netbsd", "openbsd", "plan9", "solaris", "wasip1", "windows"}
	unixGoos = []string{"aix", "android", "darwin", "dragonfly", "freebsd", "illumos", "ios", "linux", "netbsd", "openbsd", "solaris"}
)

// builds reports whether a file of kerodSource is code built on this
// platform: no test, and of no other platform by its name or its
// constraint. Files that are no Go count, as code may embed them.
func builds(p string, b []byte) bool {
	if !strings.HasSuffix(p, ".go") {
		return true
	}
	name := strings.TrimSuffix(path.Base(p), ".go")
	if strings.HasSuffix(name, "_test") {
		return false
	}
	// name_GOOS, name_GOARCH or name_GOOS_GOARCH.
	parts := strings.Split(name, "_")
	for i := max(1, len(parts)-2); i < len(parts); i++ {
		if slices.Contains(goos, parts[i]) && parts[i] != runtime.GOOS {
			return false
		}
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "package ") {
			break
		}
		if constraint.IsGoBuild(line) {
			if expr, err := constraint.Parse(line); err == nil {
				return expr.Eval(func(tag string) bool {
					return tag == runtime.GOOS || tag == runtime.GOARCH ||
						tag == "unix" && slices.Contains(unixGoos, runtime.GOOS)
				})
			}
		}
	}
	return true
}

// kerodStale reports whether kerod, of the version and fingerprint its
// Welcome tells, runs other code than this app's, as after an update that
// changed it: an earlier kerod, which tells no fingerprint, of another
// version.
func kerodStale(app, fp string) bool {
	if fp != "" {
		return fp != build.Daemon
	}
	return app != mygo.App.Version()
}
