package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"kero/internal/client"
	"kero/internal/proto"
)

// browserCommands are what kero browser does to a page, which name no
// target: kero browser text is this session's browser's text.
var browserCommands = []string{"open", "back", "forward", "reload", "text", "html", "click", "type", "wait", "eval", "screenshot"}

// browserCmd drives a browser pane's page, which the app has: kerod asks
// the app, and hands its answer back.
func browserCmd(c *client.Client, st proto.State, args []string) error {
	f, err := parse(args, map[string]string{"timeout": "timeout", "t": "timeout", "o": "out", "out": "out", "text": "text"},
		map[string]string{"enter": "enter", "E": "enter"})
	if err != nil {
		return err
	}
	const use = "kero browser [target] <open|back|forward|reload|text|html|click|type|wait|eval|screenshot> [args…]"
	pos := f.pos
	var t target
	if len(pos) > 0 && !slices.Contains(browserCommands, pos[0]) {
		if t, err = find(st, pos[0]); err != nil {
			return err
		}
		pos = pos[1:]
	} else {
		if t, err = findOrCurrent(st, nil); err != nil {
			return usageErr("which browser? (outside kero, name one): %s", use)
		}
		// The pane a command runs in is a terminal: its session's
		// browser is meant.
		t.pane = ""
	}
	if len(pos) == 0 {
		return usageErr("%s", use)
	}
	op, pos := pos[0], pos[1:]
	if !slices.Contains(browserCommands, op) {
		return usageErr("no browser command %q: %s", op, use)
	}
	pane, err := browserOf(t)
	if err != nil {
		return err
	}
	timeout, err := parseTimeout(f.vals["timeout"])
	if err != nil {
		return err
	}
	p := proto.BrowserParams{ID: pane, Op: op, Timeout: timeout}
	// The text after the arguments, as kero send takes it: all of them,
	// those after -- too, or - for stdin.
	rest := func(from []string) (string, error) {
		text := strings.Join(append(from, f.rest...), " ")
		if text == "-" {
			b, err := io.ReadAll(os.Stdin)
			return string(b), err
		}
		return text, nil
	}
	switch op {
	case "open":
		if p.Text, err = rest(pos); err != nil {
			return err
		}
		if strings.TrimSpace(p.Text) == "" {
			return usageErr("kero browser [target] open <url>")
		}
	case "back", "forward", "reload", "screenshot":
		if len(pos) > 0 || len(f.rest) > 0 {
			return usageErr("kero browser [target] %s takes no arguments", op)
		}
	case "text", "html":
		if len(pos) > 1 {
			return usageErr("kero browser [target] %s [selector]", op)
		}
		if len(pos) == 1 {
			p.Selector = pos[0]
		}
	case "click":
		if len(pos) != 1 {
			return usageErr("kero browser [target] click <selector>")
		}
		p.Selector = pos[0]
	case "type":
		if len(pos) < 1 {
			return usageErr("kero browser [target] type <selector> <text…> [--enter]")
		}
		p.Selector, p.Enter = pos[0], f.set["enter"]
		if p.Text, err = rest(pos[1:]); err != nil {
			return err
		}
	case "wait":
		if len(pos) > 1 {
			return usageErr("kero browser [target] wait [selector] [--text text]")
		}
		if len(pos) == 1 {
			p.Selector = pos[0]
		}
		p.Text = f.vals["text"]
	case "eval":
		if p.Text, err = rest(pos); err != nil {
			return err
		}
		if strings.TrimSpace(p.Text) == "" {
			return usageErr("kero browser [target] eval <js…>")
		}
	}
	if f.vals["out"] != "" && op != "screenshot" {
		return usageErr("-o is screenshot's")
	}
	if f.set["enter"] && op != "type" {
		return usageErr("--enter is type's")
	}
	if f.vals["text"] != "" && op != "wait" {
		return usageErr("--text is wait's")
	}
	var res proto.BrowserResult
	if err := c.Call("browser", p, &res); err != nil {
		return err
	}
	if op == "screenshot" {
		return saveShot(res.PNG, pane, f.vals["out"])
	}
	if res.Text != "" {
		fmt.Print(res.Text)
		if !strings.HasSuffix(res.Text, "\n") {
			fmt.Println()
		}
	}
	return nil
}

// browserOf is the browser pane a target stands for: the pane named, or
// for a session, its focused pane when that is a browser, else its one
// browser.
func browserOf(t target) (string, error) {
	if t.pane != "" {
		if p := t.s.PaneByID(t.pane); p == nil || !p.Browser() {
			return "", fmt.Errorf("%w: pane %s is a terminal, not a browser", errNotFound, t.pane)
		}
		return t.pane, nil
	}
	if p := t.s.FocusPane(); p != nil && p.Browser() {
		return p.ID, nil
	}
	var ids []string
	for _, p := range t.s.Panes {
		if p.Browser() {
			ids = append(ids, p.ID)
		}
	}
	switch len(ids) {
	case 1:
		return ids[0], nil
	case 0:
		return "", fmt.Errorf("%w: session %s has no browser pane (open one with kero split --url <url>)", errNotFound, t.s.ID)
	}
	return "", fmt.Errorf("%w: session %s has several browser panes, name one: %s", errNotFound, t.s.ID, strings.Join(ids, ", "))
}

// saveShot writes a screenshot where -o says, - for stdout, else to a
// file of its own in the temporary directory, and prints where it went.
func saveShot(png []byte, pane, out string) error {
	if len(png) == 0 {
		return errors.New("the page gave no picture")
	}
	if out == "-" {
		_, err := os.Stdout.Write(png)
		return err
	}
	if out == "" {
		out = filepath.Join(os.TempDir(), fmt.Sprintf("kero-%s-%s.png", pane, time.Now().Format("20060102-150405.000")))
	}
	if err := os.WriteFile(out, png, 0o644); err != nil {
		return err
	}
	fmt.Println(out)
	return nil
}
