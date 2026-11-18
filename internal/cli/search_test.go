package cli

import (
	"strings"
	"testing"

	"kero/internal/proto"
)

func TestSearchFlags(t *testing.T) {
	t.Setenv("KERO_PANE", "")
	t.Setenv("KERO_SESSION", "")
	f, p, err := searchFlags([]string{"connection", "refused", "-p", "api", "-n", "100", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	if p.Query != "connection refused" || p.Project != "api" || p.Limit != 100 || p.PerPane != 20 || !f.set["json"] || f.set["all"] {
		t.Errorf("%+v %+v", p, f)
	}
	// A pane gives at most what's asked for, and a query can start with a dash.
	_, p, err = searchFlags([]string{"-n", "5", "--", "-v"})
	if err != nil {
		t.Fatal(err)
	}
	if p.Query != "-v" || p.Limit != 5 || p.PerPane != 5 {
		t.Errorf("%+v", p)
	}
	f, p, err = searchFlags([]string{"x", "-a"})
	if err != nil || !f.set["all"] || p.Limit != 50 || p.PerPane != 10 {
		t.Errorf("%+v %+v %v", p, f, err)
	}
	for _, args := range [][]string{{}, {"  "}, {"x", "-n", "0"}, {"x", "-n", "many"}, {"x", "--nope"}, {strings.Repeat("x", 2000)}} {
		if _, _, err := searchFlags(args); err == nil {
			t.Errorf("%q: no error", args)
		}
	}
	if !IsCommand("search") {
		t.Error("search is no command")
	}
}

// The pane a command runs in comes last, its own command line matching, and
// names nothing on another machine.
func TestSearchLastPane(t *testing.T) {
	t.Setenv("KERO_PANE", "here")
	old := onHost
	defer func() { onHost = old }()
	onHost = ""
	if _, p, _ := searchFlags([]string{"x"}); p.Last != "here" {
		t.Errorf("last %q", p.Last)
	}
	onHost = "box"
	if _, p, _ := searchFlags([]string{"x"}); p.Last != "" {
		t.Errorf("last %q on a host", p.Last)
	}
}

// A match prints its pane, its session's name, and its line: a session with
// no name known goes by its id.
func TestMatchLine(t *testing.T) {
	m := proto.SearchMatch{Session: "s1", Pane: "p1", Line: "a timeout here"}
	if got, want := matchLine(m, map[string]string{"s1": "api"}), "p1\tapi\ta timeout here"; got != want {
		t.Errorf("%q, want %q", got, want)
	}
	if got, want := matchLine(m, nil), "p1\ts1\ta timeout here"; got != want {
		t.Errorf("no names: %q, want %q", got, want)
	}
}
