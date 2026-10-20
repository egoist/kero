package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"kero/internal/proto"
)

// skillGuide teaches a coding agent kero: the skill `kero skill setup`
// installs, from this binary, so that it follows kero's updates.
const skillGuide = `---
name: kero
description: Drive terminal sessions in Kero — start agents and commands in their own sessions or panes, type into them, wait for them, read their screens, and report your own status. Use when running inside Kero ($KERO_PANE is set) and the task needs another terminal, a long-running process, a parallel agent, or the user's attention.
---

# Kero

You run inside Kero, a terminal whose sessions keep running in the
background. $KERO_SESSION is your session and $KERO_PANE your pane; the
` + "`kero`" + ` command drives them. A target is a session or a pane id (a
prefix works), or a session's name; a session stands for its focused pane.

## Run something beside you

    kero split --down -- npm run dev          # a pane under yours; prints its id
    kero new -n review -- claude              # a session of its own
    kero new -n tests -d ~/code/app -- go test ./...

Name a session after its task (` + "`kero rename $KERO_SESSION fix-login-redirect`" + `)
so the user finds it in the sidebar.

## Drive it

    kero send <target> "some text" --enter    # type, then press Enter
    kero key <target> ctrl+c                  # enter, escape, up, tab, ctrl+d…
    kero prompt <target> "run the tests"      # send + Enter, wait, print screen
    kero wait <target> [--for idle,waiting,error,exited] [--timeout 10m]
    kero wait <target> --exit                 # until its command ends; exits with its status
    kero read <target> [-n 40] [-a]           # the screen, or with scrollback
    kero status <target> --json               # status, program, directory
    kero ls                                   # every session and pane

A pane's status is working, waiting (it needs the user), idle, error or
exited. ` + "`kero wait`" + ` with no --for waits until it stops working. A
command such as a test run doesn't show as working: wait for it with --exit,
or start it with --wait, which exits with the command's status:

    pane=$(kero split --down -- go test ./...)
    kero wait "$pane" --exit || kero read "$pane" -n 80
    kero split --down --wait -- make build    # the same, in one step

## Tell the user

    kero report working "Migrating the database" --progress 40
    kero report blocked "Approve the production deploy?" --kind permission
    kero report done "Deployed to staging"
    kero notify "Need your API key to continue"

Reports are OSC 7501 sequences: Kero shows them in its sidebar, and
notifies the user when you are blocked or done while they look elsewhere.
Report blocked only when you truly cannot go on without them.

## Etiquette

- Close what you started when it is done: ` + "`kero close <target>`" + `.
- Never type into a pane you did not start unless the user asked.
- Exit status 3 means no such target, 4 that Kero is not running.
`

func skillCmd(args []string) error {
	f, err := parse(args, map[string]string{"agent": "agent"}, map[string]string{"dry-run": "dry", "n": "dry"})
	if err != nil {
		return err
	}
	sub := "status"
	if len(f.pos) > 0 {
		sub = f.pos[0]
	}
	agent := strings.ToLower(f.vals["agent"])
	dirs, hooks := skillDirs(agent), hooksFor(agent)
	switch sub {
	case "show":
		fmt.Print(skillGuide)
		return nil
	case "status":
		for _, name := range sortedKeys(dirs) {
			fmt.Printf("%-8s skill  %-9s %s\n", name, skillState(dirs[name]), proto.ShortDir(dirs[name]))
		}
		for _, h := range hooks {
			fmt.Printf("%-8s hook   %-9s %s\n", h.name(), h.state(), proto.ShortDir(h.path()))
		}
		return nil
	case "setup", "remove":
		for _, name := range sortedKeys(dirs) {
			dir := dirs[name]
			switch {
			case f.set["dry"]:
				fmt.Printf("would %s %s (%s)\n", sub, proto.ShortDir(dir), name)
			case sub == "remove":
				if err := os.RemoveAll(dir); err != nil {
					return err
				}
				fmt.Printf("removed %s\n", proto.ShortDir(dir))
			default:
				if err := writeSkill(dir); err != nil {
					return err
				}
				fmt.Printf("installed %s (%s)\n", proto.ShortDir(dir), name)
			}
		}
		for _, h := range hooks {
			switch {
			case f.set["dry"]:
				fmt.Printf("would %s the hook in %s (%s)\n", sub, proto.ShortDir(h.path()), h.name())
			case sub == "remove":
				if err := h.remove(); err != nil {
					return err
				}
				fmt.Printf("removed the hook from %s\n", proto.ShortDir(h.path()))
			default:
				if err := h.install(); err != nil {
					return err
				}
				fmt.Printf("installed the hook in %s (%s)\n", proto.ShortDir(h.path()), h.name())
			}
		}
		if sub == "setup" && !f.set["dry"] && len(hooks) > 0 {
			fmt.Println("\nAgents started from now on in Kero learn which session they're in.")
			for _, h := range hooks {
				if note := map[string]string{
					"claude":   "Claude Code runs hooks only in folders you trust.",
					"codex":    "Codex asks you to approve a new hook: run /hooks in it.",
					"vibe":     "Vibe records a resume checkpoint before a tool call or after a completed reply. After /new or /resume, reach a tool call or complete a reply before restarting kerod.",
					"opencode": "OpenCode's background service loads plugins as it starts: run `opencode service restart` when no session is busy.",
				}[h.name()]; note != "" {
					fmt.Println(note)
				}
			}
		}
		return nil
	}
	return usageErr("kero skill setup|show|status|remove [--agent claude|codex|pi|opencode|vibe|agents] [--dry-run]")
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func skillState(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, "SKILL.md"))
	switch {
	case err != nil:
		return "missing"
	case string(b) != skillGuide:
		return "outdated"
	}
	return "current"
}

func writeSkill(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "SKILL.md"), []byte(skillGuide), 0o644)
}

// hooksFor returns the hooks that go with an --agent: Codex's, Pi's,
// OpenCode's and Vibe's with the skill they share.
func hooksFor(agent string) []integration {
	switch agent {
	case "", "claude", "codex", "pi", "opencode", "vibe", "agents":
		return agentHooks(agent)
	}
	return nil
}

// skillDirs returns where agents read skills: Claude Code's, and the
// shared one of Codex, OpenCode and others.
func skillDirs(agent string) map[string]string {
	home := proto.Home()
	claude := os.Getenv("CLAUDE_CONFIG_DIR")
	if claude == "" {
		claude = filepath.Join(home, ".claude")
	}
	all := map[string]string{
		"claude": filepath.Join(claude, "skills", "kero"),
		"agents": filepath.Join(home, ".agents", "skills", "kero"),
	}
	if agent = strings.ToLower(agent); agent != "" {
		if d, ok := all[agent]; ok {
			return map[string]string{agent: d}
		}
		if agent == "codex" || agent == "opencode" || agent == "pi" || agent == "vibe" {
			return map[string]string{"agents": all["agents"]}
		}
	}
	return all
}

// SkillState is where a skill for agents is, and whether it is current,
// with the hooks that go with it.
type SkillState struct {
	Agent string // "claude", or "agents" (Codex, OpenCode, Pi…)
	Dir   string
	State string // "current", "outdated" (or partly installed) or "missing"
}

// SkillStates returns the state of kero's skill and hooks for each kind
// of agent.
func SkillStates() []SkillState {
	var out []SkillState
	for _, agent := range []string{"claude", "agents"} {
		dir := skillDirs(agent)[agent]
		states := []string{skillState(dir)}
		for _, h := range hooksFor(agent) {
			states = append(states, h.state())
		}
		st := "outdated"
		switch {
		case !slices.ContainsFunc(states, func(s string) bool { return s != "current" }):
			st = "current"
		case !slices.ContainsFunc(states, func(s string) bool { return s != "missing" }):
			st = "missing"
		}
		out = append(out, SkillState{Agent: agent, Dir: dir, State: st})
	}
	return out
}

// InstallSkill installs, or updates, kero's skill and hooks for a kind of
// agent.
func InstallSkill(agent string) error {
	dir := skillDirs(agent)[agent]
	if dir == "" {
		return fmt.Errorf("no agent %q", agent)
	}
	if err := writeSkill(dir); err != nil {
		return err
	}
	for _, h := range hooksFor(agent) {
		if err := h.install(); err != nil {
			return err
		}
	}
	return nil
}

// RemoveSkill removes kero's skill and hooks for a kind of agent.
func RemoveSkill(agent string) error {
	dir := skillDirs(agent)[agent]
	if dir == "" {
		return fmt.Errorf("no agent %q", agent)
	}
	for _, h := range hooksFor(agent) {
		if err := h.remove(); err != nil {
			return err
		}
	}
	return os.RemoveAll(dir)
}
