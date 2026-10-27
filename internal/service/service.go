// Package service runs kerod as a service of the user's: a systemd user
// unit on Linux, which lingering starts with the machine and keeps running
// with no one logged in, a launchd agent on macOS, which runs while the
// user is logged in, and a task of Task Scheduler on Windows, which does
// too. `kero daemon install-service` installs it, as a server wants: it
// runs `kero daemon serve`, which never exits for being idle, with
// KERO_SERVICE=1 under systemd and launchd, which tells kerod a manager
// starts it again as it exits; Task Scheduler does not.
package service

import (
	"errors"
	"os"
	"strings"

	"kero/internal/proto"
)

// ErrUnsupported: the system runs no services of a user's that Kero knows.
var ErrUnsupported = errors.New("kero runs kerod as a service with systemd (Linux), launchd (macOS) or Task Scheduler (Windows)")

// Name is the service's name: kerod, or kerod-dev for a development
// build (proto.Name), whose kerod is of its own.
func Name() string { return strings.Replace(proto.Name(), "kero", "kerod", 1) }

// Status is how the service stands.
type Status struct {
	Installed bool
	Running   bool
	// File is the unit or the agent's property list; Detail what the
	// system says of it, as systemctl's "active".
	File   string
	Detail string
	// Linger: systemd keeps the user's services running while they are
	// logged out.
	Linger bool
}

// Installed reports whether kerod runs as a service.
func Installed() bool {
	f := file()
	if f == "" {
		return false
	}
	_, err := os.Stat(f)
	return err == nil
}
