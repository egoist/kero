package cli

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"kero/internal/client"
	"kero/internal/proto"
	"kero/internal/settings"
)

// How long kero search waits for a host to connect and to answer.
const (
	searchConnect = 10 * time.Second
	searchAnswer  = 30 * time.Second
)

// searchFlags are kero search's flags: its query, and the search it asks
// for.
func searchFlags(args []string) (*flags, proto.SearchParams, error) {
	var p proto.SearchParams
	f, err := parse(args, map[string]string{"p": "project", "project": "project", "n": "count", "count": "count"},
		map[string]string{"json": "json", "j": "json", "all": "all", "a": "all"})
	if err != nil {
		return nil, p, err
	}
	p.Query = strings.Join(append(f.pos, f.rest...), " ")
	if strings.TrimSpace(p.Query) == "" {
		return nil, p, usageErr("kero search <query> [-p project] [--all] [-n count] [--json]")
	}
	if len(p.Query) > proto.MaxQuery {
		return nil, p, usageErr("kero search: a query is at most %d bytes", proto.MaxQuery)
	}
	n := 50
	if v := f.vals["count"]; v != "" {
		if n, err = strconv.Atoi(v); err != nil || n <= 0 {
			return nil, p, usageErr("kero search -n takes a count")
		}
	}
	p.Project, p.Limit = f.vals["project"], n
	// A pane takes a fifth of many matches, so that others show too.
	p.PerPane = min(n, max(10, n/5))
	// The pane it runs in comes last: its own command line matches.
	p.Last = current()
	return f, p, nil
}

// searchCmd is kero search on one machine: the matches as they come.
func searchCmd(c *client.Client, args []string, host string) error {
	f, p, err := searchFlags(args)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), searchAnswer)
	defer cancel()
	var names map[string]string
	if !f.set["json"] {
		names = sessionNames(c)
	}
	matches := []proto.SearchMatch{}
	res, err := c.Search(ctx, p, func(ms []proto.SearchMatch) {
		matches = append(matches, ms...)
		if !f.set["json"] {
			printMatches(ms, names)
		}
	})
	if errors.Is(err, client.ErrNoSearch) {
		if host != "" {
			return fmt.Errorf("kerod on %s is of a Kero that can't search: update it (kero -H %s daemon update)", host, host)
		}
		return errors.New("this kerod is of a Kero that can't search: run `kero daemon restart`")
	}
	if err != nil {
		return err
	}
	if f.set["json"] {
		return printJSON(matches)
	}
	searchSummary(len(matches), res)
	return nil
}

// sessionNames returns the names of the sessions of a machine by id, as
// kero ls shows them; none when its state doesn't come, as matches still
// tell their sessions' ids.
func sessionNames(c *client.Client) map[string]string {
	var st proto.State
	if c.Call("state", nil, &st) != nil {
		return nil
	}
	naming := settings.Load().SessionName
	names := make(map[string]string, len(st.Sessions))
	for i := range st.Sessions {
		names[st.Sessions[i].ID] = st.Sessions[i].DisplayName(naming)
	}
	return names
}

// printMatches prints matches: the target to read or focus, the session's
// name, and the line.
func printMatches(ms []proto.SearchMatch, names map[string]string) {
	for _, m := range ms {
		fmt.Println(matchLine(m, names))
	}
}

// matchLine is how kero search prints a match; a session that names has no
// name for, as one started after they came, goes by its id.
func matchLine(m proto.SearchMatch, names map[string]string) string {
	name := names[m.Session]
	if name == "" {
		name = m.Session
	}
	return m.Pane + "\t" + name + "\t" + m.Line
}

// searchSummary says on standard error what the matches printed don't show,
// which stays what a script reads of them.
func searchSummary(found int, res proto.SearchResult) {
	switch {
	case found == 0:
		fmt.Fprintln(os.Stderr, "no matches")
	case res.Truncated:
		fmt.Fprintln(os.Stderr, "there may be more matches: -n shows more")
	}
}

// hostMatches are the matches of a machine, for kero search --all: Host is
// what -H takes to act on them, "local" for this machine.
type hostMatches struct {
	Host      string              `json:"host"`
	Addr      string              `json:"addr,omitempty"`
	Error     string              `json:"error,omitempty"`
	Truncated bool                `json:"truncated,omitempty"`
	Matches   []proto.SearchMatch `json:"matches"`
	noProject bool
	names     map[string]string
}

// searchAll searches this machine and every host of kero hosts at once, each
// printed as it finishes, so that a slow host holds up no other; a host out
// of reach, or too old to search, says why in place of its matches, and
// fails nothing.
func searchAll(f *flags, p proto.SearchParams) error {
	hosts := settings.Load().Hosts
	all := make([]hostMatches, len(hosts)+1)
	all[0].Host = "local"
	for i, h := range hosts {
		all[i+1].Host, all[i+1].Addr = h.Name, h.Addr
	}
	finished := make(chan *hostMatches)
	var wg sync.WaitGroup
	for i := range all {
		hs := &all[i]
		wg.Go(func() {
			host := hs.Host
			if i == 0 {
				host = ""
			}
			hs.search(host, p)
			finished <- hs
		})
	}
	go func() {
		wg.Wait()
		close(finished)
	}()
	first, missing := true, 0
	for hs := range finished {
		if hs.noProject {
			missing++
			continue
		}
		if f.set["json"] {
			continue
		}
		if !first {
			fmt.Println()
		}
		first = false
		hs.print()
	}
	if p.Project != "" && missing == len(all) {
		return fmt.Errorf("no project %q", p.Project)
	}
	if f.set["json"] {
		return printJSON(all)
	}
	return nil
}

// search searches a machine, host being "" for this one.
func (hs *hostMatches) search(host string, p proto.SearchParams) {
	hs.Matches = []proto.SearchMatch{}
	if host != "" {
		p.Last = "" // a pane of this machine names nothing there
	}
	c, done, err := connectWithin(host, searchConnect)
	if err != nil {
		hs.Error = strings.TrimPrefix(strings.TrimPrefix(err.Error(), errUnreachable.Error()+": "), hs.Host+": ")
		if strings.HasSuffix(hs.Error, context.DeadlineExceeded.Error()) {
			hs.Error = fmt.Sprintf("no answer in %s", searchConnect)
		}
		return
	}
	defer done()
	ctx, cancel := context.WithTimeout(context.Background(), searchAnswer)
	defer cancel()
	hs.names = sessionNames(c)
	res, err := c.Search(ctx, p, func(ms []proto.SearchMatch) { hs.Matches = append(hs.Matches, ms...) })
	hs.Truncated = res.Truncated
	switch {
	case err == nil:
	case errors.Is(err, client.ErrNoSearch):
		hs.Error = "skipped: its kerod is of a Kero that can't search"
		if host != "" {
			hs.Error += fmt.Sprintf(" (kero -H %s daemon update)", host)
		} else {
			hs.Error += " (kero daemon restart)"
		}
	case errors.Is(err, context.DeadlineExceeded):
		hs.Error = fmt.Sprintf("no answer in %s", searchAnswer)
	case strings.HasPrefix(err.Error(), "no project"):
		hs.noProject = true
	default:
		hs.Error = err.Error()
	}
}

// print prints a machine's matches, under its name, as kero ls --all does.
func (hs *hostMatches) print() {
	head := hs.Host
	if hs.Addr != "" {
		head += " (" + hs.Addr + ")"
	}
	if hs.Error != "" {
		fmt.Printf("%s: %s\n", head, hs.Error)
		return
	}
	fmt.Println(head)
	printMatches(hs.Matches, hs.names)
	if len(hs.Matches) == 0 {
		fmt.Println("no matches")
	} else if hs.Truncated {
		fmt.Println("there may be more matches: -n shows more")
	}
}
