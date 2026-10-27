// Kero-server is the server build of Kero: kerod and the kero CLI,
// without the app, for a machine whose sessions Kero on another one shows
// (Settings › Hosts), as a Linux box with no display. It installs in
// ~/.local with install-server.sh, which runs kerod as a service, and
// updates itself (kero daemon update, or the app's Update Kero).
//
// Its version comes with the build:
//
//	go build -ldflags "-X main.version=2.1.0 -X github.com/egoist/mygo.production=1" -o kero ./cmd/kero-server
package main

import (
	"fmt"
	"os"

	"github.com/egoist/mygo"

	"kero/internal/build"
	"kero/internal/cli"
	"kero/internal/daemon"
)

// version is the version of Kero this build is of, set with -ldflags.
var version = "dev"

func main() {
	build.Server = true
	mygo.App.SetVersion(version)
	if len(os.Args) > 1 && os.Args[1] == "__kerod" {
		if err := daemon.Run(daemon.Options{}); err != nil {
			fmt.Fprintln(os.Stderr, "kerod:", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) < 2 {
		os.Exit(cli.Run([]string{"help"}))
	}
	if !cli.IsCommand(os.Args[1]) {
		fmt.Fprintf(os.Stderr, "kero: unknown command %q (see kero help)\n", os.Args[1])
		os.Exit(2)
	}
	os.Exit(cli.Run(os.Args[1:]))
}
