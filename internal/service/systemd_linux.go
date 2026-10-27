package service

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
)

// file is the unit, of the user's systemd: $XDG_CONFIG_HOME/systemd/user.
func file() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "systemd", "user", Name()+".service")
}

// unit is the unit that runs exe's kerod. It starts kerod again whenever
// it ends, as after the restart an update asks for (host.restart).
func unit(exe string) string {
	return fmt.Sprintf(`# Kero's daemon, which runs the sessions: written by kero daemon install-service.
[Unit]
Description=Kero sessions (kerod)
Documentation=https://github.com/egoist/kero/blob/main/docs/remote.md

[Service]
Type=simple
ExecStart=%s daemon serve
Environment=KERO_SERVICE=1
Restart=always
RestartSec=2
# kerod saves its sessions as it stops, to start them again
# (restore-sessions); their programs end with it.
KillMode=mixed
TimeoutStopSec=15

[Install]
WantedBy=default.target
`, systemdQuote(exe))
}

// systemdQuote quotes a path for ExecStart.
func systemdQuote(s string) string {
	if !strings.ContainsAny(s, " \t\"'\\%$") {
		return s
	}
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, `%`, `%%`, `$`, `$$`)
	return `"` + r.Replace(s) + `"`
}

func systemctl(args ...string) (string, error) {
	out, err := exec.Command("systemctl", append([]string{"--user"}, args...)...).CombinedOutput()
	s := strings.TrimSpace(string(out))
	if err != nil && s != "" {
		return s, fmt.Errorf("systemctl --user %s: %s", strings.Join(args, " "), s)
	}
	return s, err
}

// Install writes the unit for exe, enables it and starts it. A kerod
// already running, which the app or a bridge started, is stopped first
// (stop): the service's starts its sessions again.
func Install(exe string, stop func() error) error {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return ErrUnsupported
	}
	if _, err := systemctl("show-environment"); err != nil {
		return fmt.Errorf("no systemd user session to run kerod in: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(file()), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(file(), []byte(unit(exe)), 0o644); err != nil {
		return err
	}
	// A unit that does not run is none: Installed would tell otherwise.
	undo := func(err error) error {
		systemctl("disable", Name()+".service")
		os.Remove(file())
		systemctl("daemon-reload")
		return err
	}
	if _, err := systemctl("daemon-reload"); err != nil {
		return undo(err)
	}
	if _, err := systemctl("enable", Name()+".service"); err != nil {
		return undo(err)
	}
	if stop != nil {
		stop()
	}
	if _, err := systemctl("restart", Name()+".service"); err != nil {
		return undo(err)
	}
	return nil
}

// EnableLinger keeps the user's services running while they are logged
// out, and starts them with the machine: what a server needs.
func EnableLinger() error {
	u, err := user.Current()
	if err != nil {
		return err
	}
	if lingering(u.Username) {
		return nil
	}
	out, err := exec.Command("loginctl", "enable-linger", u.Username).CombinedOutput()
	if err != nil {
		return fmt.Errorf("loginctl enable-linger %s: %s (an administrator can run it: sudo loginctl enable-linger %s)",
			u.Username, strings.TrimSpace(string(out)), u.Username)
	}
	return nil
}

func lingering(name string) bool {
	_, err := os.Stat(filepath.Join("/var/lib/systemd/linger", name))
	return err == nil
}

// Uninstall stops and removes the service.
func Uninstall() error {
	if !Installed() {
		return nil
	}
	systemctl("disable", "--now", Name()+".service")
	if err := os.Remove(file()); err != nil {
		return err
	}
	systemctl("daemon-reload")
	return nil
}

// Start starts the service.
func Start() error {
	_, err := systemctl("start", Name()+".service")
	return err
}

// Restart restarts the service: kerod saves its sessions and starts them
// again.
func Restart() error {
	_, err := systemctl("restart", Name()+".service")
	return err
}

// Get tells how the service stands.
func Get() Status {
	st := Status{File: file(), Installed: Installed()}
	if u, err := user.Current(); err == nil {
		st.Linger = lingering(u.Username)
	}
	if !st.Installed {
		return st
	}
	out, _ := systemctl("is-active", Name()+".service")
	st.Detail = out
	st.Running = out == "active"
	return st
}

// Stop stops the service, until it is started again.
func Stop() error {
	_, err := systemctl("stop", Name()+".service")
	return err
}
