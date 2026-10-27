// Package cli is the kero command: sessions driven from a shell or by an
// agent, through the daemon the app shows.
package cli

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"kero/internal/actions"
	"kero/internal/build"
	"kero/internal/client"
	"kero/internal/proto"
	"kero/internal/service"
	"kero/internal/settings"
	"kero/internal/update"
)

const usage = `kero — terminal sessions that keep running, for you and your agents

Usage:
  kero                          open the app
  kero ls [--json]              list sessions and their panes
  kero new [options] [-- cmd…]  start a session, printing its id
      -p, --project <name|id>     project to put it in (default: by directory)
      -n, --name <name>           name it
      -d, --dir <dir>             start it there (default: here)
      -f, --focus                 show it in the app
      -w, --wait                  wait for cmd to end, exit with its status
      -u, --url <url>             a browser showing url, not a shell
      --worktree <branch>         in a git worktree of its own, on a new
                                  branch from the default branch
      --base <ref>                the branch to start it from instead
  kero split [target] [options] [-- cmd…]
                                start a pane beside a pane, printing its id
      --right (default), --down, --left, --up
      -r, --ratio <0..1>          the new pane's share (default 0.5)
      -d, --dir <dir>             start it there (default: the pane's)
      -w, --wait                  wait for cmd to end, exit with its status
      -u, --url <url>             a browser showing url, not a shell, as
                                  a dev server's page: localhost:3000
  kero send <target> <text…>    type text into a pane
      -e                          interpret \n \r \t \e \xHH escapes
      --enter                     press Enter after it
  kero key <target> <key…>      press keys: enter, tab, escape, up, down,
                                left, right, backspace, ctrl+c, ctrl+d, …
  kero prompt <target> <text…>  send text and Enter, wait until the pane
                                stops working, then print its screen
  kero read [target] [-a] [-n lines]
                                print the screen (-a with the scrollback)
  kero wait [target] [--for idle,waiting,error,exited] [--timeout 10m]
                                wait until the pane stops working (or
                                reaches one of the statuses), print it
      -x, --exit                  instead wait for the command it started
                                  with to end, exit with its status
  kero events [target] [-p project] [--for statuses] [--json]
                                print what happens as it does, a line an
                                event: panes changing status, sessions
                                and panes starting and closing, renames,
                                moves to another project, notifications;
                                until the target closes
      --for <statuses>            only panes going to these: idle,
                                  working, waiting, error, exited
      --once                      exit after the first event (1 if the
                                  target closes or the timeout comes first)
      -t, --timeout <dur>         stop watching after this long
  kero status [target] [--json]
  kero diff [target] [--turn | --branch] [path…]
                                the changes in the pane's git worktree, as
                                git diff prints them: since HEAD, untracked
                                files too; --turn since its agent last
                                started working; --branch since it left
                                the default branch
  kero browser [target] <command> [args…]
                                drive a browser pane's page (needs Remote
                                Control, in Settings › Agents); the target
                                is a browser pane, or a session, for its
                                browser (default: this session's)
      open <url>                  go to a page, and wait for it to load
      back, forward, reload       and wait for the page to load
      text [selector]             print the page's text, or an element's
      html [selector]             print the page's HTML, or an element's
      snapshot [selector]         print what the page shows: roles, names,
                                  and a ref for each element
      click <selector>            click an element
      type <selector> <text…>     type text into a field, in place of what
                                  it holds (--enter: press Enter after it)
      wait [selector] [--text t]  wait for an element to show (or the text
                                  to), or without either, the page to load
      eval <js…>                  run JavaScript, print its value
      screenshot [-o file.png]    save a picture of the page, print where
      cookies save [file]         save the browser's cookies (Playwright's
                                  JSON, or cookies.txt for a .txt file)
      cookies load <file>         load cookies from either
      --ref <ref>                 a snapshot's element, in place of a
                                  selector
      --domain <domain>           cookies of a site and its subdomains
      -t, --timeout <dur>         how long to wait (default 10s)
  kero history [query] [-p project] [-n count] [--json]
                                the agents' conversations panes ran, the
                                last to run first, to resume
  kero resume <conversation> [-f]
                                start a session resuming a conversation
                                (its id, a prefix of it, or its name), or
                                show the one running it, printing its id
  kero rename <session> <name>
  kero focus <target>           show a session (and pane) in the app
  kero close <target>           end a session (or, given a pane, the pane)
      --remove-worktree           remove the session's own worktree too,
                                  and its branch once merged
      --force                     even if that loses changes or commits
  kero restart <target>         start an exited pane's shell again
  kero notify [target] <message>
                                flag the pane as needing you
  kero report <state> [message] [--kind k] [--progress n] [--app a] [--id i]
                                report this program's status (OSC 7501):
                                idle, working, done, blocked, error, clear
  kero do <action> [key=value…]  run an action of the app, as its menus do
                                (needs Remote Control, in Settings › Agents)
  kero actions                  list the actions kero do runs
  kero config path|show|edit|check
                                the configuration file: where it is, every
                                key with its value (--defaults: as kero
                                comes), open it in $EDITOR, check it
  kero projects [--json]
  kero skill setup|status|show|remove
                                teach coding agents to use kero
  kero clients [--json]         list who is connected to kerod
  kero hosts [ls]               the other machines Kero reaches
  kero hosts add <name> <address> [--remote-control]
                                save one: [user@]host or ssh://… over SSH,
                                wsl://distro, http(s)://… for a listener
  kero hosts remove|check <name>
  kero hosts install <name|address> [--version v]
                                install Kero there, over SSH
  kero daemon status|stop|restart
  kero daemon serve [--listen tailnet://:7373]…
                                run kerod in the foreground, never idle,
                                as a service does
  kero daemon install-service|uninstall-service
                                run kerod with the machine (systemd, launchd)
  kero daemon update [version]  update the server build of Kero

Global options:
  -H, --host <name|address>     act on kerod on another machine: a host of
                                kero hosts, or an address ($KERO_HOST)

A target is a session or a pane: an id, a prefix of it, or a session's
name; a session stands for its focused pane. Inside kero, $KERO_PANE and
$KERO_SESSION name the pane and session a command runs in, the default
target.

Exit status: 0 ok, 1 failed, 2 bad usage, 3 no such target (or an
ambiguous one), 4 kerod unreachable.
`

// Commands lists the subcommands, which main sends here.
var Commands = []string{"ls", "list", "new", "split", "send", "key", "prompt", "read", "capture", "wait", "events", "status", "diff",
	"history", "resume", "rename", "focus", "close", "kill", "restart", "notify", "report", "projects", "skill", "hook", "daemon", "do", "actions", "config",
	"browser", "hosts", "clients", "__bridge", "-H", "--host", "help", "--help", "-h", "version", "--version"}

// IsCommand reports whether an argument starts a command of the CLI, as
// main tells them from the app's.
func IsCommand(arg string) bool {
	return slices.Contains(Commands, arg) || strings.HasPrefix(arg, "--host=") || strings.HasPrefix(arg, "-H") && len(arg) > 2
}

// Errors of exit statuses other than 1.
var (
	errUsage       = errors.New("usage")
	errNotFound    = errors.New("not found")
	errUnreachable = errors.New("unreachable")
)

// exitStatus is a waited-for program's exit status, which kero exits
// with.
type exitStatus int

func (e exitStatus) Error() string { return fmt.Sprintf("exit status %d", int(e)) }

// Run runs a subcommand, returning the exit code.
func Run(args []string) int {
	host, env, args, err := splitHost(args)
	if err == nil && host != "" && len(args) > 0 && localOnly[args[0]] {
		// $KERO_HOST is for what acts on sessions: the rest is of this
		// machine, as an agent's hook in a shell whose profile sets it.
		if env {
			host = ""
		} else {
			err = usageErr("kero %s is of this machine: run it on the host itself, without -H", args[0])
		}
	}
	if err == nil {
		onHost = host
		err = run(args, host)
	}
	if err == nil {
		return 0
	}
	var es exitStatus
	if errors.As(err, &es) {
		return int(es)
	}
	fmt.Fprintln(os.Stderr, "kero:", err)
	switch {
	case errors.Is(err, errUsage):
		return 2
	case errors.Is(err, errNotFound):
		return 3
	case errors.Is(err, errUnreachable):
		return 4
	}
	return 1
}

func usageErr(format string, args ...any) error {
	return fmt.Errorf("%w: "+format, append([]any{errUsage}, args...)...)
}

// flags parses flags anywhere among the arguments: names that take a
// value, and booleans; the rest are positional, all of them after "--".
type flags struct {
	vals map[string]string
	set  map[string]bool
	pos  []string
	rest []string // after --
}

func parse(args []string, valued, boolean map[string]string) (*flags, error) {
	f := &flags{vals: map[string]string{}, set: map[string]bool{}}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			f.rest = args[i+1:]
			break
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			f.pos = append(f.pos, a)
			continue
		}
		name, val, hasVal := strings.Cut(strings.TrimLeft(a, "-"), "=")
		if canon, ok := valued[name]; ok {
			if !hasVal {
				if i+1 >= len(args) {
					return nil, usageErr("%s needs a value", a)
				}
				i++
				val = args[i]
			}
			f.vals[canon] = val
			continue
		}
		if canon, ok := boolean[name]; ok {
			f.set[canon] = true
			continue
		}
		return nil, usageErr("unknown flag %s", a)
	}
	return f, nil
}

func run(args []string, host string) error {
	cmd, args := args[0], args[1:]
	switch cmd {
	case "__bridge":
		return bridge(args)
	case "hosts":
		return hostsCmd(args)
	case "help", "--help", "-h":
		u := usage
		if build.Server {
			// No app to open.
			u = strings.Replace(u, "  kero                          open the app\n", "", 1)
		}
		fmt.Print(u)
		return nil
	case "version", "--version":
		return versionCmd(host)
	case "daemon":
		return daemonCmd(args, host)
	case "report":
		return report(args)
	case "actions":
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "ACTION\tKEYS\tWHAT")
		for _, a := range actions.All {
			if a.Remote {
				fmt.Fprintf(w, "%s\t%s\t%s\n", a.ID, actions.Glyphs(a.Keys), strings.TrimSuffix(a.Title, "…"))
			}
		}
		return w.Flush()
	case "skill":
		return skillCmd(args)
	case "hook":
		return hookCmd(args)
	case "config":
		return configCmd(args)
	}
	c, done, err := connect(host)
	if err != nil {
		if errors.Is(err, client.ErrVersion) {
			return fmt.Errorf("%w: the running kerod is of another version: run `kero daemon restart` (it restarts sessions)", errUnreachable)
		}
		if errors.Is(err, errUnreachable) || errors.Is(err, errNotFound) {
			return err
		}
		return fmt.Errorf("%w: %v", errUnreachable, err)
	}
	defer done()
	if cmd == "clients" {
		return clientsCmd(c, args)
	}
	var st proto.State
	if err := c.Call("state", nil, &st); err != nil {
		return err
	}

	switch cmd {
	case "ls", "list":
		f, err := parse(args, nil, map[string]string{"json": "json", "j": "json"})
		if err != nil {
			return err
		}
		if f.set["json"] {
			return printJSON(st.Sessions)
		}
		listSessions(st)
		return nil

	case "projects":
		f, err := parse(args, nil, map[string]string{"json": "json"})
		if err != nil {
			return err
		}
		if f.set["json"] {
			return printJSON(st.Projects)
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tNAME\tSESSIONS\tDIR")
		for _, p := range st.Projects {
			n := 0
			for _, s := range st.Sessions {
				if s.Project == p.ID {
					n++
				}
			}
			fmt.Fprintf(w, "%s\t%s\t%d\t%s\n", p.ID, p.Name, n, proto.ShortDir(p.Dir))
		}
		return w.Flush()

	case "new":
		f, err := parse(args,
			map[string]string{"p": "project", "project": "project", "n": "name", "name": "name", "d": "dir", "dir": "dir", "timeout": "timeout", "t": "timeout",
				"u": "url", "url": "url", "worktree": "worktree", "base": "base"},
			map[string]string{"f": "focus", "focus": "focus", "json": "json", "wait": "wait", "w": "wait"})
		if err != nil {
			return err
		}
		command := append(f.pos, f.rest...)
		if f.set["wait"] && len(command) == 0 {
			return usageErr("kero new --wait needs a command: kero new --wait -- cmd…")
		}
		if f.vals["url"] != "" && (len(command) > 0 || f.set["wait"]) {
			return usageErr("kero new --url shows a page, and runs no command")
		}
		if f.vals["base"] != "" && f.vals["worktree"] == "" {
			return usageErr("kero new --base starts a --worktree's branch")
		}
		dir := f.vals["dir"]
		// Here, unless the session is of another machine, whose kerod
		// then starts it in the project's directory, or the home.
		if dir == "" && f.vals["project"] == "" && host == "" {
			dir, _ = os.Getwd()
		}
		var s proto.Session
		if err := c.Call("create", proto.CreateParams{
			Project: f.vals["project"], Name: f.vals["name"], Dir: dir, Command: command, URL: f.vals["url"],
			After: os.Getenv("KERO_SESSION"), Worktree: f.vals["worktree"], Base: f.vals["base"],
		}, &s); err != nil {
			return err
		}
		if f.set["focus"] {
			c.Call("select", proto.FocusParams{Session: s.ID}, nil)
		}
		if f.set["json"] {
			if err := printJSON(s); err != nil {
				return err
			}
		} else {
			fmt.Println(s.ID)
		}
		if f.set["wait"] {
			return waitExit(c, s.Panes[0].ID, f.vals["timeout"])
		}
		return nil

	case "split":
		f, err := parse(args, map[string]string{"r": "ratio", "ratio": "ratio", "d": "dir", "dir": "dir", "timeout": "timeout", "t": "timeout", "u": "url", "url": "url"},
			map[string]string{"right": "right", "down": "down", "left": "left", "up": "up", "json": "json", "f": "focus", "focus": "focus", "wait": "wait", "w": "wait"})
		if err != nil {
			return err
		}
		t, err := findOrCurrent(st, f.pos)
		if err != nil {
			return err
		}
		dir := "right"
		for _, d := range []string{"down", "left", "up"} {
			if f.set[d] {
				dir = d
			}
		}
		ratio, _ := strconv.ParseFloat(f.vals["ratio"], 64)
		command := append(f.pos[min(1, len(f.pos)):], f.rest...)
		if f.set["wait"] && len(command) == 0 {
			return usageErr("kero split --wait needs a command: kero split --wait -- cmd…")
		}
		if f.vals["url"] != "" && (len(command) > 0 || f.set["wait"]) {
			return usageErr("kero split --url shows a page, and runs no command")
		}
		var s proto.Session
		if err := c.Call("split", proto.CreateParams{Split: t.ref(), Direction: dir, Ratio: ratio,
			Dir: f.vals["dir"], Command: command, URL: f.vals["url"]}, &s); err != nil {
			return err
		}
		if f.set["focus"] {
			c.Call("select", proto.FocusParams{Session: s.ID, Pane: s.Focus}, nil)
		}
		if f.set["json"] {
			if err := printJSON(s); err != nil {
				return err
			}
		} else {
			fmt.Println(s.Focus)
		}
		if f.set["wait"] {
			return waitExit(c, s.Focus, f.vals["timeout"])
		}
		return nil

	case "send", "prompt":
		f, err := parse(args, map[string]string{"timeout": "timeout", "t": "timeout"},
			map[string]string{"e": "escapes", "enter": "enter", "E": "enter"})
		if err != nil {
			return err
		}
		if len(f.pos) < 1 {
			return usageErr("kero %s <target> <text…>", cmd)
		}
		t, err := find(st, f.pos[0])
		if err != nil {
			return err
		}
		text := strings.Join(append(f.pos[1:], f.rest...), " ")
		if text == "-" {
			b, err := io.ReadAll(os.Stdin)
			if err != nil {
				return err
			}
			text = string(b)
		}
		if f.set["escapes"] {
			text = unescape(text)
		}
		if text != "" {
			if err := c.Call("send", proto.SendParams{ID: t.ref(), Data: text}, nil); err != nil {
				return err
			}
		}
		if f.set["enter"] || cmd == "prompt" {
			// Apart from the text, which a program could take for a paste
			// of a newline.
			time.Sleep(120 * time.Millisecond)
			if err := c.Call("send", proto.SendParams{ID: t.ref(), Data: "\r"}, nil); err != nil {
				return err
			}
		}
		if cmd == "send" {
			return nil
		}
		timeout, err := parseTimeout(f.vals["timeout"])
		if err != nil {
			return err
		}
		var info proto.Pane
		if err := c.Call("wait", proto.WaitParams{ID: t.ref(), Timeout: timeout}, &info); err != nil {
			return err
		}
		var res proto.ReadResult
		if err := c.Call("read", proto.ReadParams{ID: t.ref()}, &res); err != nil {
			return err
		}
		fmt.Print(res.Text)
		return nil

	case "key":
		if len(args) < 2 {
			return usageErr("kero key <target> <key…>")
		}
		t, err := find(st, args[0])
		if err != nil {
			return err
		}
		var data []byte
		for _, k := range args[1:] {
			b, err := keyBytes(k)
			if err != nil {
				return err
			}
			data = append(data, b...)
		}
		return c.Call("send", proto.SendParams{ID: t.ref(), Data: string(data)}, nil)

	case "read", "capture":
		f, err := parse(args, map[string]string{"n": "lines", "lines": "lines"}, map[string]string{"a": "all", "all": "all"})
		if err != nil {
			return err
		}
		t, err := findOrCurrent(st, f.pos)
		if err != nil {
			return err
		}
		lines, _ := strconv.Atoi(f.vals["lines"])
		var res proto.ReadResult
		if err := c.Call("read", proto.ReadParams{ID: t.ref(), Scrollback: f.set["all"], Lines: lines}, &res); err != nil {
			return err
		}
		fmt.Print(res.Text)
		return nil

	case "wait":
		f, err := parse(args, map[string]string{"for": "for", "timeout": "timeout", "t": "timeout"}, map[string]string{"json": "json", "exit": "exit", "x": "exit"})
		if err != nil {
			return err
		}
		t, err := findOrCurrent(st, f.pos)
		if err != nil {
			return err
		}
		if f.set["exit"] {
			if f.vals["for"] != "" {
				return usageErr("kero wait: --exit or --for, not both")
			}
			return waitExit(c, t.ref(), f.vals["timeout"])
		}
		var want []proto.Status
		for _, w := range strings.Split(f.vals["for"], ",") {
			if w = strings.TrimSpace(w); w != "" {
				want = append(want, proto.Status(w))
			}
		}
		timeout, err := parseTimeout(f.vals["timeout"])
		if err != nil {
			return err
		}
		var info proto.Pane
		if err := c.Call("wait", proto.WaitParams{ID: t.ref(), Status: want, Timeout: timeout}, &info); err != nil {
			return err
		}
		if f.set["json"] {
			err = printJSON(info)
		} else {
			fmt.Println(info.Status)
		}
		if err == nil && info.Status == proto.Exited && info.ExitCode != 0 {
			return exitStatus(info.ExitCode)
		}
		return err

	case "events":
		return eventsCmd(c, st, args)

	case "status":
		f, err := parse(args, nil, map[string]string{"json": "json"})
		if err != nil {
			return err
		}
		t, err := findOrCurrent(st, f.pos)
		if err != nil {
			return err
		}
		if f.set["json"] {
			if t.pane != "" {
				return printJSON(t.s.PaneByID(t.pane))
			}
			return printJSON(t.s)
		}
		p := t.s.Pane
		if t.pane != "" {
			p = *t.s.PaneByID(t.pane)
		}
		line := fmt.Sprintf("%s\t%s\t%s", t.s.ID, p.Status, t.s.DisplayName(settings.Load().SessionName))
		if p.Message != "" {
			line += "\t" + p.Message
		}
		fmt.Println(line)
		return nil

	case "diff":
		f, err := parse(args, nil, map[string]string{"turn": "turn", "branch": "branch", "base": "branch"})
		if err != nil {
			return err
		}
		if f.set["turn"] && f.set["branch"] {
			return usageErr("kero diff: --turn or --branch, not both")
		}
		// A target first, unless it names none: then every argument is a
		// path, of the pane the command runs in.
		var t target
		paths := f.pos
		if len(f.pos) > 0 {
			if t, err = find(st, f.pos[0]); err == nil {
				paths = f.pos[1:]
			} else if current() == "" {
				return err
			}
		}
		if t.s.ID == "" {
			if t, err = findOrCurrent(st, nil); err != nil {
				return err
			}
		}
		base := "head"
		switch {
		case f.set["turn"]:
			base = "turn"
		case f.set["branch"]:
			base = "branch"
		}
		pane := diffPane(t, base == "turn")
		if pane == nil || pane.Git == nil {
			return errors.New("not in a git repository (or git-status is off)")
		}
		var res proto.ReadResult
		if len(paths) == 0 {
			paths = []string{""}
		}
		for _, p := range paths {
			rel, err := repoPath(pane.Git.Root, p, host != "")
			if err != nil {
				return err
			}
			if err := c.Call("git.diff", proto.GitParams{Pane: pane.ID, Base: base, Path: rel}, &res); err != nil {
				return err
			}
			fmt.Print(res.Text)
		}
		return nil

	case "history":
		f, err := parse(args, map[string]string{"p": "project", "project": "project", "n": "count", "count": "count"}, map[string]string{"json": "json", "j": "json"})
		if err != nil {
			return err
		}
		list, err := conversations(c, st, f.vals["project"], strings.Join(f.pos, " "))
		if err != nil {
			return err
		}
		n := 20
		if v := f.vals["count"]; v != "" {
			if n, err = strconv.Atoi(v); err != nil || n < 0 {
				return usageErr("kero history -n takes a count")
			}
		}
		if n > 0 && len(list) > n && !f.set["json"] {
			list = list[:n]
		}
		if f.set["json"] {
			return printJSON(list)
		}
		listConversations(st, list)
		return nil

	case "resume":
		f, err := parse(args, nil, map[string]string{"f": "focus", "focus": "focus", "json": "json"})
		if err != nil {
			return err
		}
		if len(f.pos) == 0 {
			return usageErr("kero resume <conversation> (see kero history)")
		}
		list, err := conversations(c, st, "", "")
		if err != nil {
			return err
		}
		conv, err := findConversation(list, strings.Join(f.pos, " "))
		if err != nil {
			return err
		}
		var s proto.Session
		if err := c.Call("conversation.resume", proto.ConversationParams{Agent: conv.Agent, ID: conv.ID, After: os.Getenv("KERO_SESSION")}, &s); err != nil {
			return err
		}
		if f.set["focus"] {
			c.Call("select", proto.FocusParams{Session: s.ID}, nil)
		}
		if f.set["json"] {
			return printJSON(s)
		}
		fmt.Println(s.ID)
		return nil

	case "rename":
		if len(args) < 2 {
			return usageErr("kero rename <session> <name>")
		}
		t, err := find(st, args[0])
		if err != nil {
			return err
		}
		return c.Call("rename", proto.RenameParams{ID: t.s.ID, Name: strings.Join(args[1:], " "), By: os.Getenv("KERO_PANE")}, nil)

	case "focus":
		if len(args) < 1 {
			return usageErr("kero focus <target>")
		}
		t, err := find(st, args[0])
		if err != nil {
			return err
		}
		var shown bool
		if err := c.Call("select", proto.FocusParams{Session: t.s.ID, Pane: t.pane}, &shown); err != nil {
			return err
		}
		if !shown {
			return errors.New("the app is not open")
		}
		return nil

	case "close", "kill", "restart":
		f, err := parse(args, nil, map[string]string{"remove-worktree": "remove", "force": "force"})
		if err != nil {
			return err
		}
		if len(f.pos) < 1 {
			return usageErr("kero %s <target>", cmd)
		}
		t, err := find(st, f.pos[0])
		if err != nil {
			return err
		}
		remove := f.set["remove"]
		if remove && t.s.Worktree == nil {
			return fmt.Errorf("session %s has no worktree of its own", t.s.ID)
		}
		switch {
		case cmd == "restart":
			return c.Call("restart", proto.IDParams{ID: t.ref()}, nil)
		case t.pane != "" && len(t.s.Panes) > 1 && !remove:
			return c.Call("pane.close", proto.IDParams{ID: t.pane}, nil)
		}
		return c.Call("close", proto.CloseParams{ID: t.s.ID, RemoveWorktree: remove, Force: f.set["force"]}, nil)

	case "do":
		if len(args) < 1 {
			return usageErr("kero do <action> [key=value…] (see kero actions)")
		}
		a, ok := actions.Find(args[0])
		if !ok || !a.Remote {
			return fmt.Errorf("%w: no action %q (see kero actions)", errNotFound, args[0])
		}
		kv := map[string]string{}
		for _, arg := range args[1:] {
			k, v, ok := strings.Cut(arg, "=")
			if !ok {
				return usageErr("%q is not key=value", arg)
			}
			kv[k] = v
		}
		var delivered bool
		if err := c.Call("do", proto.DoParams{Action: a.ID, Args: kv}, &delivered); err != nil {
			return err
		}
		if !delivered {
			return errors.New("the app is not open")
		}
		return nil

	case "browser":
		return browserCmd(c, st, args)

	case "notify":
		f, err := parse(args, map[string]string{"session": "target", "s": "target", "title": "title"}, nil)
		if err != nil {
			return err
		}
		ref := f.vals["target"]
		if ref == "" {
			ref = current()
		}
		if ref == "" {
			return usageErr("which pane? run it in Kero, or give --session")
		}
		t, err := find(st, ref)
		if err != nil {
			return err
		}
		return c.Call("notify", proto.NotifyParams{ID: t.ref(), Title: f.vals["title"], Body: strings.Join(append(f.pos, f.rest...), " ")}, nil)
	}
	return usageErr("unknown command %q (see kero help)", cmd)
}

// target is what a command acts on: a session, or one of its panes.
type target struct {
	s    proto.Session
	pane string // "" for the session, which stands for its focused pane
}

func (t target) ref() string {
	if t.pane != "" {
		return t.pane
	}
	return t.s.ID
}

func find(st proto.State, ref string) (target, error) {
	for _, s := range st.Sessions {
		if s.ID == ref {
			return target{s: s}, nil
		}
		for _, p := range s.Panes {
			if p.ID == ref {
				return target{s: s, pane: p.ID}, nil
			}
		}
	}
	var matches []target
	for _, s := range st.Sessions {
		if strings.HasPrefix(s.ID, ref) || strings.EqualFold(s.Name, ref) || strings.EqualFold(s.DisplayName(settings.Load().SessionName), ref) {
			matches = append(matches, target{s: s})
			continue
		}
		for _, p := range s.Panes {
			if strings.HasPrefix(p.ID, ref) {
				matches = append(matches, target{s: s, pane: p.ID})
			}
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return target{}, fmt.Errorf("%w: no session or pane %q", errNotFound, ref)
	}
	ids := make([]string, len(matches))
	for i, m := range matches {
		ids[i] = m.ref()
	}
	slices.Sort(ids)
	return target{}, fmt.Errorf("%w: %q names several: %s", errNotFound, ref, strings.Join(ids, ", "))
}

// diffPane is the pane whose worktree kero diff shows: the target's, or
// for a turn, the pane of its session whose agent started one, the
// target first.
func diffPane(t target, turn bool) *proto.Pane {
	p := t.s.PaneByID(t.pane)
	if p == nil {
		p = t.s.FocusPane()
	}
	if !turn || p == nil || p.Turn != nil {
		return p
	}
	for i := range t.s.Panes {
		if t.s.Panes[i].Turn != nil {
			return &t.s.Panes[i]
		}
	}
	return p
}

// repoPath writes a path given on the command line, relative to the
// current directory, as one from a worktree's root, slash-separated; ""
// stays "", for every file. A path of another machine's worktree
// (remote) is from its root already, unless absolute.
func repoPath(root, p string, remote bool) (string, error) {
	if p == "" {
		return "", nil
	}
	if remote {
		p = strings.ReplaceAll(p, `\`, "/")
		if strings.HasPrefix(p, "/") {
			rel, ok := strings.CutPrefix(p, strings.TrimSuffix(root, "/")+"/")
			if !ok {
				return "", fmt.Errorf("%s is not in the worktree %s", p, root)
			}
			p = rel
		}
		return strings.TrimPrefix(path.Clean("/"+p), "/"), nil
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(root, abs)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("%s is not in the worktree %s", p, proto.ShortDir(root))
	}
	if rel == "." {
		return "", nil
	}
	return filepath.ToSlash(rel), nil
}

// current is the pane a command runs in, inside kero.
func current() string {
	// A pane of this machine names nothing on another.
	if onHost != "" {
		return ""
	}
	if p := os.Getenv("KERO_PANE"); p != "" {
		return p
	}
	return os.Getenv("KERO_SESSION")
}

func findOrCurrent(st proto.State, pos []string) (target, error) {
	if len(pos) > 0 {
		return find(st, pos[0])
	}
	if ref := current(); ref != "" {
		return find(st, ref)
	}
	return target{}, usageErr("which session? (outside kero, name one)")
}

func daemonCmd(args []string, host string) error {
	sub := "status"
	if len(args) > 0 {
		sub = args[0]
	}
	if host != "" {
		return remoteDaemonCmd(sub, args[min(1, len(args)):], host)
	}
	switch sub {
	case "status":
		svc := service.Get()
		c, err := client.Connect(true)
		if err != nil {
			fmt.Println("kerod is not running")
		} else {
			defer c.Close()
			var st proto.State
			c.Call("state", nil, &st)
			panes := 0
			for _, s := range st.Sessions {
				panes += len(s.Panes)
			}
			fmt.Printf("kerod %d running (Kero %s, pid %d) for %s: %d sessions, %d panes\n", c.Welcome.Version, orDash(c.Welcome.App), c.Welcome.PID,
				time.Since(time.UnixMilli(c.Welcome.Started)).Round(time.Second), len(st.Sessions), panes)
		}
		fmt.Println("socket:", proto.SocketPath())
		if svc.Installed {
			fmt.Printf("service: %s (%s)\n", orDash(svc.Detail), svc.File)
			if !svc.Linger {
				fmt.Println("  it stops as you log out: loginctl enable-linger keeps it running")
			}
		}
		if l := settings.Load().Listen; len(l) > 0 {
			fmt.Println("listening:", strings.Join(l, ", "))
		}
		return nil
	case "stop", "restart":
		// The service's manager stops and restarts it, but Task
		// Scheduler, whose kerod stops as any, and starts with the task.
		if service.Installed() {
			var err error
			if sub == "stop" {
				err = service.Stop()
			} else {
				err = service.Restart()
			}
			if !errors.Is(err, service.ErrUnsupported) {
				if err == nil && sub == "restart" {
					fmt.Println("kerod restarted")
				}
				return err
			}
		}
		if err := StopDaemon(); err != nil {
			return err
		}
		if sub == "restart" {
			c, err := client.Connect(false)
			if err != nil {
				return err
			}
			c.Close()
			fmt.Println("kerod restarted")
		}
		return nil
	case "serve":
		return serveCmd(args[1:])
	case "install-service":
		f, err := parse(args[1:], nil, map[string]string{"no-linger": "no-linger"})
		if err != nil {
			return err
		}
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		// A user's services stop as they log out, unless they linger: a
		// service would then end kerod as an SSH bridge does, which a kerod
		// of its own outlives. --no-linger takes it as it is.
		if !f.set["no-linger"] {
			if err := service.EnableLinger(); err != nil {
				return fmt.Errorf("%v; without it kerod would stop as you log out (kero daemon install-service --no-linger installs it all the same)", err)
			}
		}
		if err := service.Install(exe, StopDaemon); err != nil {
			return err
		}
		fmt.Printf("kerod runs as a service: %s\n", service.Get().File)
		return nil
	case "uninstall-service":
		if err := service.Uninstall(); err != nil {
			return err
		}
		fmt.Println("kerod no longer runs as a service: the app, or a bridge, starts it")
		return nil
	case "update":
		if !build.Server {
			return errors.New("this is Kero's desktop app, which updates itself: kero daemon update is of the server build")
		}
		version := ""
		if len(args) > 1 {
			version = args[1]
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()
		if version == "" {
			v, err := update.Latest(ctx)
			if err != nil {
				return err
			}
			version = v
		}
		if strings.TrimPrefix(version, "v") == build.Version() {
			fmt.Printf("Kero %s is installed\n", build.Version())
			return nil
		}
		// A version named is the user's to go back to.
		if err := update.Install(ctx, version, update.InstallDir(), build.Version(), len(args) > 1); err != nil {
			return err
		}
		fmt.Printf("installed Kero %s: kerod runs it as it restarts (kero daemon restart), its sessions with it\n", strings.TrimPrefix(version, "v"))
		return nil
	}
	return usageErr("unknown daemon command %q", sub)
}

// remoteDaemonCmd is kero -H <host> daemon …: how kerod on the host is,
// and restarting it, or updating Kero there, as the app does.
func remoteDaemonCmd(sub string, args []string, host string) error {
	rc, err := dialHost(host)
	if err != nil {
		return err
	}
	defer rc.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	switch sub {
	case "status":
		h := rc.Welcome.Host
		fmt.Printf("%s: %s (%s/%s), Kero %s (protocol %d)\n", host, h.Hostname, h.OS, h.Arch, orDash(h.Kero), h.Version)
		c, err := client.ConnectVia(rc)
		if err != nil {
			fmt.Println("kerod:", err)
			return nil
		}
		defer c.Close()
		var st proto.State
		c.Call("state", nil, &st)
		fmt.Printf("kerod %d running (Kero %s, pid %d) for %s: %d sessions\n", c.Welcome.Version, orDash(c.Welcome.App), c.Welcome.PID,
			time.Since(time.UnixMilli(c.Welcome.Started)).Round(time.Second), len(st.Sessions))
		return nil
	case "restart":
		if err := rc.Host(ctx, proto.HostRequest{Kind: proto.KindRestart}); err != nil {
			return err
		}
		fmt.Printf("kerod on %s restarted\n", host)
		return nil
	case "update":
		version := releasedVersion()
		if len(args) > 0 {
			version = strings.TrimPrefix(args[0], "v")
		}
		if version == "" {
			v, err := update.Latest(ctx)
			if err != nil {
				return err
			}
			version = v
		}
		fmt.Printf("updating Kero on %s to %s…\n", host, version)
		if err := rc.Host(ctx, proto.HostRequest{Kind: proto.KindUpdate, App: version}); err != nil {
			return err
		}
		fmt.Printf("installed: kerod on %s runs it as it restarts (kero -H %s daemon restart), its sessions with it\n", host, host)
		return nil
	}
	return usageErr("kero -H <host> daemon status|restart|update [version]")
}

// StopDaemon stops the running daemon, which saves its sessions to start
// them again, whatever its version.
func StopDaemon() error {
	pid := client.DaemonPID()
	if pid == 0 {
		return nil
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	if client.Interrupt(p) != nil {
		p.Kill()
	}
	for range 100 {
		if client.DaemonPID() == 0 {
			return nil
		}
		time.Sleep(30 * time.Millisecond)
	}
	return errors.New("kerod did not stop")
}

// conversations lists the conversations kerod remembers, of a project
// (by id or name) when one is named, matching query when there is one.
func conversations(c *client.Client, st proto.State, project, query string) ([]proto.Conversation, error) {
	var list []proto.Conversation
	if err := c.Call("conversations", nil, &list); err != nil {
		if strings.Contains(err.Error(), "unknown method") {
			return nil, errors.New("this kerod remembers no conversations: update it, or run `kero daemon restart`")
		}
		return nil, err
	}
	if project != "" {
		id := ""
		for _, p := range st.Projects {
			if p.ID == project || strings.EqualFold(p.Name, project) {
				id = p.ID
			}
		}
		if id == "" {
			return nil, fmt.Errorf("no project %q", project)
		}
		list = slices.DeleteFunc(list, func(cv proto.Conversation) bool { return cv.Project != id })
	}
	if q := strings.ToLower(strings.TrimSpace(query)); q != "" {
		list = slices.DeleteFunc(list, func(cv proto.Conversation) bool {
			for _, w := range strings.Fields(q) {
				if !strings.Contains(strings.ToLower(cv.Name+" "+cv.Title+" "+cv.Dir+" "+cv.Agent+" "+cv.ID), w) {
					return true
				}
			}
			return false
		})
	}
	return list, nil
}

// findConversation finds a conversation by its id, a unique prefix of
// it, or its name.
func findConversation(list []proto.Conversation, ref string) (proto.Conversation, error) {
	var found []proto.Conversation
	for _, cv := range list {
		if cv.ID == ref {
			return cv, nil
		}
		if strings.HasPrefix(cv.ID, ref) || strings.EqualFold(cv.Label(), ref) {
			found = append(found, cv)
		}
	}
	switch len(found) {
	case 0:
		return proto.Conversation{}, fmt.Errorf("%w: no conversation %q (see kero history)", errNotFound, ref)
	case 1:
		return found[0], nil
	}
	return proto.Conversation{}, fmt.Errorf("%q could be %d conversations: give more of its id (see kero history)", ref, len(found))
}

func listConversations(st proto.State, list []proto.Conversation) {
	if len(list) == 0 {
		fmt.Println("no conversations yet (agents' conversations show here once Kero's skill is set up: kero skill setup)")
		return
	}
	names := map[string]string{}
	for _, p := range st.Projects {
		names[p.ID] = p.Name
	}
	now := time.Now()
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tAGENT\tPROJECT\tNAME\tLAST RAN\tDIR")
	for _, cv := range list {
		when := proto.Ago(cv.Updated, now)
		if cv.Session != "" {
			when = "running in " + cv.Session
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", cv.ID, cv.Agent, orDash(names[cv.Project]), cv.Label(), when, proto.ShortDir(cv.Dir))
	}
	w.Flush()
}

func listSessions(st proto.State) {
	if len(st.Sessions) == 0 {
		fmt.Println("no sessions (start one with kero new)")
		return
	}
	names := map[string]string{}
	for _, p := range st.Projects {
		names[p.ID] = p.Name
	}
	now := time.Now()
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tPROJECT\tNAME\tSTATUS\tPROGRAM\tSINCE\tDIR")
	status := func(p proto.Pane) string {
		s := string(p.Status)
		if p.Progress >= 0 {
			s += fmt.Sprintf(" %d%%", p.Progress)
		}
		if p.Unread {
			s += "*"
		}
		return s
	}
	// A browser's program is the browser, and its place its page.
	program := func(p proto.Pane) string {
		if p.Browser() {
			return "browser"
		}
		return orDash(p.Process)
	}
	where := func(p proto.Pane) string {
		if p.Browser() {
			return p.URL
		}
		return proto.ShortDir(p.WorkDir())
	}
	for _, s := range st.Sessions {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s.ID, names[s.Project], s.DisplayName(settings.Load().SessionName), status(s.Pane),
			program(s.Pane), proto.Ago(s.Since, now), where(s.Pane))
		if len(s.Panes) > 1 {
			for _, p := range s.Panes {
				mark := " "
				if p.ID == s.Focus {
					mark = "›"
				}
				fmt.Fprintf(w, "  %s %s\t\t%s\t%s\t%s\t%s\t%s\n", mark, p.ID, p.PaneName(), status(p),
					program(p), proto.Ago(p.Since, now), where(p))
			}
		}
	}
	w.Flush()
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func parseTimeout(s string) (int64, error) {
	if s == "" {
		return 0, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		n, err2 := strconv.Atoi(s)
		if err2 != nil {
			return 0, usageErr("bad timeout %q", s)
		}
		d = time.Duration(n) * time.Second
	}
	return d.Milliseconds(), nil
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

// keys are the names kero key takes, as the bytes a terminal sends.
var keys = map[string]string{
	"enter": "\r", "return": "\r", "tab": "\t", "escape": "\x1b", "esc": "\x1b", "space": " ",
	"backspace": "\x7f", "delete": "\x1b[3~", "up": "\x1b[A", "down": "\x1b[B", "right": "\x1b[C",
	"left": "\x1b[D", "home": "\x1b[H", "end": "\x1b[F", "pageup": "\x1b[5~", "pagedown": "\x1b[6~",
	"shift+tab": "\x1b[Z",
}

func keyBytes(name string) ([]byte, error) {
	n := strings.ToLower(name)
	if b, ok := keys[n]; ok {
		return []byte(b), nil
	}
	if rest, ok := strings.CutPrefix(n, "ctrl+"); ok && len(rest) == 1 {
		c := rest[0]
		switch {
		case c >= 'a' && c <= 'z':
			return []byte{c - 'a' + 1}, nil
		case c >= '@' && c <= '_':
			return []byte{c - '@'}, nil
		}
	}
	if rest, ok := strings.CutPrefix(n, "alt+"); ok {
		b, err := keyBytes(rest)
		if err != nil {
			return nil, err
		}
		return append([]byte{0x1b}, b...), nil
	}
	if len([]rune(name)) == 1 {
		return []byte(name), nil
	}
	return nil, usageErr("unknown key %q", name)
}

// waitExit waits for the command a pane started with to end, and exits
// with its status: or its shell's, if that ended first.
func waitExit(c *client.Client, pane, timeout string) error {
	ms, err := parseTimeout(timeout)
	if err != nil {
		return err
	}
	var info proto.Pane
	if err := c.Call("wait", proto.WaitParams{ID: pane, Exit: true, Timeout: ms}, &info); err != nil {
		return err
	}
	code := info.ExitCode
	if info.CommandExit != nil {
		code = *info.CommandExit
	}
	if code != 0 {
		return exitStatus(code)
	}
	return nil
}

// report writes an OSC 7501 report of the program's status to the
// terminal, as a script reports what it does: kero shows it, and so do
// other terminals that read the protocol.
func report(args []string) error {
	f, err := parse(args, map[string]string{"kind": "kind", "progress": "progress", "app": "app", "id": "id", "title": "title"}, nil)
	if err != nil {
		return err
	}
	if len(f.pos) < 1 {
		return usageErr("kero report <idle|working|done|blocked|error|clear> [message]")
	}
	state := f.pos[0]
	if !slices.Contains([]string{"idle", "working", "done", "blocked", "error", "clear"}, state) {
		return usageErr("unknown state %q", state)
	}
	pairs := []string{"state=" + state}
	for _, k := range []string{"id", "kind", "progress", "app"} {
		if v := f.vals[k]; v != "" {
			pairs = append(pairs, k+"="+v)
		}
	}
	if t := f.vals["title"]; t != "" {
		pairs = append(pairs, "title="+base64.StdEncoding.EncodeToString([]byte(t)))
	}
	if msg := strings.Join(append(f.pos[1:], f.rest...), " "); msg != "" {
		pairs = append(pairs, "msg="+base64.StdEncoding.EncodeToString([]byte(msg)))
	}
	seq := "\x1b]7501;" + strings.Join(pairs, ":") + "\x1b\\"
	// To the terminal, even when the output goes elsewhere.
	if tty, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0); err == nil {
		defer tty.Close()
		_, err = tty.WriteString(seq)
		return err
	}
	_, err = os.Stdout.WriteString(seq)
	return err
}

// unescape interprets the escapes of echo -e: \n \r \t \e \a \b \\ \xHH.
func unescape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 'r':
			b.WriteByte('\r')
		case 't':
			b.WriteByte('\t')
		case 'e':
			b.WriteByte(0x1b)
		case 'a':
			b.WriteByte(7)
		case 'b':
			b.WriteByte(8)
		case '\\':
			b.WriteByte('\\')
		case 'x':
			if i+2 < len(s) {
				if v, err := strconv.ParseUint(s[i+1:i+3], 16, 8); err == nil {
					b.WriteByte(byte(v))
					i += 2
					continue
				}
			}
			b.WriteString(`\x`)
		default:
			b.WriteByte('\\')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}
