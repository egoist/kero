package settings

import (
	"reflect"
	"strings"
	"testing"
)

func TestHostKeys(t *testing.T) {
	file := `host = devbox=me@devbox
host = build=ssh://ci@build.lab:2222 remote-control
host = wsl=wsl://Ubuntu color=teal
listen = tailnet://:7400
listen = tailnet-serve://
listen-allow = alice@example.com
listen-allow = tag:ci
`
	s, probs := parse(file)
	if len(probs) > 0 {
		t.Fatalf("problems %q", probs)
	}
	want := []Host{
		{Name: "devbox", Addr: "me@devbox"},
		{Name: "build", Addr: "ci@build.lab:2222", RemoteControl: true},
		{Name: "wsl", Addr: "wsl://Ubuntu", Color: "teal"},
	}
	if !reflect.DeepEqual(s.Hosts, want) {
		t.Errorf("hosts %+v", s.Hosts)
	}
	if !reflect.DeepEqual(s.Listen, []string{"tailnet://:7400", "tailnet-serve://"}) || len(s.ListenAllow) != 2 {
		t.Errorf("listen %q, allow %q", s.Listen, s.ListenAllow)
	}
	if h := s.Host("BUILD"); h == nil || h.Name != "build" {
		t.Errorf("Host(BUILD) = %+v", h)
	}
	// Written back as read, an address as ParseAddr writes it.
	out := format(s, "")
	for _, line := range []string{"host = build=ci@build.lab:2222 remote-control", "host = wsl=wsl://Ubuntu color=teal", "listen-allow = tag:ci"} {
		if !strings.Contains(out, line+"\n") {
			t.Errorf("formatted without %q:\n%s", line, out)
		}
	}
	back, _ := parse(out)
	if !reflect.DeepEqual(back.Hosts, s.Hosts) {
		t.Errorf("read back %+v", back.Hosts)
	}
	c := s.Clone()
	c.Hosts[0].Name = "x"
	if s.Hosts[0].Name != "devbox" {
		t.Error("a clone shares its hosts")
	}
}

func TestHostKeyProblems(t *testing.T) {
	for _, bad := range []string{
		"host = devbox",
		"host = local=me@devbox",
		"host = a b=me@devbox",
		"host = devbox=ftp://devbox",
		"host = devbox=me@devbox sudo",
		"host = devbox=me@devbox color=chartreuse",
		"host = a=x\nhost = A=y",
		"listen = tcp://:80",
	} {
		if _, probs := parse(bad + "\n"); len(probs) == 0 {
			t.Errorf("%q: no problem", bad)
		}
	}
}
