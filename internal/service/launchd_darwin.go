package service

import (
	"fmt"
	"html"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"kero/internal/proto"
)

// label is the agent's: sh.kero.kerod, after the app's identifier.
func label() string { return "sh.kero." + Name() }

func file() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", label()+".plist")
}

func domain() string { return fmt.Sprintf("gui/%d", os.Getuid()) }

// plist is the agent that runs exe's kerod, at login and whenever it
// ends. kerod logs to kerod.log itself.
func plist(exe string) string {
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Kero's daemon, which runs the sessions: written by kero daemon install-service. -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>daemon</string>
		<string>serve</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>WorkingDirectory</key>
	<string>%s</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>KERO_SERVICE</key>
		<string>1</string>
	</dict>
</dict>
</plist>
`, label(), html.EscapeString(exe), html.EscapeString(proto.Home()))
}

func launchctl(args ...string) error {
	out, err := exec.Command("/bin/launchctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl %s: %s", strings.Join(args, " "), strings.TrimSpace(string(out)))
	}
	return nil
}

// Install writes the agent for exe and loads it. A kerod already running,
// which the app or a bridge started, is stopped first (stop): the
// agent's starts its sessions again.
func Install(exe string, stop func() error) error {
	if err := os.MkdirAll(filepath.Dir(file()), 0o755); err != nil {
		return err
	}
	launchctl("bootout", domain()+"/"+label())
	if err := os.WriteFile(file(), []byte(plist(exe)), 0o644); err != nil {
		return err
	}
	if stop != nil {
		// A daemon that did not stop keeps running, and the agent's
		// kerod cannot take its place: the install did not work, and
		// says so — as systemd's install says it too.
		if err := stop(); err != nil {
			return err
		}
	}
	return launchctl("bootstrap", domain(), file())
}

// EnableLinger does nothing on macOS: an agent runs while its user is
// logged in.
func EnableLinger() error { return nil }

// Uninstall stops and removes the agent. An agent launchd keeps, as one
// whose bootout was denied — over SSH, with no session to unload from —
// is not said gone with its property list taken away: the uninstall did
// not happen, and says so, and the plist stays — as systemd's uninstall
// keeps the unit it could not stop. Whether the agent is still loaded is
// asked, not read from launchctl's words, which the machine may say in
// its own language.
func Uninstall() error {
	// A plist that is not there is none; one that is there but cannot be
	// read is not known to be none — systemd's uninstall rule.
	if _, err := os.Stat(file()); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if launchctl("print", domain()+"/"+label()) == nil {
		if err := launchctl("bootout", domain()+"/"+label()); err != nil {
			return err
		}
	}
	return os.Remove(file())
}

// Start starts the agent's kerod, loading it again after a Stop.
func Start() error {
	if launchctl("kickstart", domain()+"/"+label()) == nil {
		return nil
	}
	return launchctl("bootstrap", domain(), file())
}

// Restart restarts the agent's kerod: SIGTERM, on which it saves its
// sessions and ends, which the agent's KeepAlive starts again.
func Restart() error { return launchctl("kill", "SIGTERM", domain()+"/"+label()) }

// Get tells how the agent stands.
func Get() Status {
	st := Status{File: file(), Installed: Installed(), Linger: true}
	if !st.Installed {
		return st
	}
	out, err := exec.Command("/bin/launchctl", "print", domain()+"/"+label()).Output()
	if err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			if k, v, ok := strings.Cut(strings.TrimSpace(l), " = "); ok && k == "state" {
				st.Detail = v
				st.Running = v == "running"
			}
		}
	}
	return st
}

// Stop stops the agent's kerod, until it is started again.
func Stop() error { return launchctl("bootout", domain()+"/"+label()) }
