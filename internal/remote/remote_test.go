package remote

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"kero/internal/proto"
)

func TestParseAddr(t *testing.T) {
	for _, c := range []struct{ in, out, scheme, user, host, port string }{
		{"devbox", "devbox", "ssh", "", "devbox", ""},
		{"me@devbox", "me@devbox", "ssh", "me", "devbox", ""},
		{"me@devbox:2222", "me@devbox:2222", "ssh", "me", "devbox", "2222"},
		{"ssh://me@build.example.com", "me@build.example.com", "ssh", "me", "build.example.com", ""},
		{"ssh://[::1]:22", "[::1]:22", "ssh", "", "::1", "22"},
		{"wsl://", "wsl://", "wsl", "", "", ""},
		{"wsl://Ubuntu-24.04", "wsl://Ubuntu-24.04", "wsl", "", "Ubuntu-24.04", ""},
		{"http://build:7373", "http://build:7373", "http", "", "build", "7373"},
		{"https://build.tail1234.ts.net", "https://build.tail1234.ts.net", "https", "", "build.tail1234.ts.net", ""},
		{"devbox?kero=/opt/kero/kero", "devbox?kero=%2Fopt%2Fkero%2Fkero", "ssh", "", "devbox", ""},
		{"devbox?kero=C:/kero/kero.exe", "devbox?kero=C%3A%2Fkero%2Fkero.exe", "ssh", "", "devbox", ""},
	} {
		a, err := ParseAddr(c.in)
		if err != nil {
			t.Errorf("%q: %v", c.in, err)
			continue
		}
		if a.Scheme != c.scheme || a.User != c.user || a.Host != c.host || a.Port != c.port {
			t.Errorf("%q: %+v", c.in, a)
		}
		if a.String() != c.out {
			t.Errorf("%q: written %q, want %q", c.in, a.String(), c.out)
		}
		if b, err := ParseAddr(a.String()); err != nil || b != a {
			t.Errorf("%q: read back %+v, %v", c.in, b, err)
		}
	}
	for _, bad := range []string{"", "ftp://x", "-oProxyCommand=evil", "ssh://-x", "me:secret@host", "http://", "a b", "devbox/path", "http://x?kero=y", "host:port",
		"dev$(id)box", "ssh://a;b@host", "x@host's", "host?kero=relative/kero", "host?kero=/opt/it's/kero", "wsl://Ubuntu;rm", "host?kero=C:", "host?kero=C:kero.exe", "host?kero=C:/a b/kero.exe", "host?kero=1:/kero"} {
		if a, err := ParseAddr(bad); err == nil {
			t.Errorf("%q read as %+v", bad, a)
		}
	}
}

func TestBridgeCommandQuotes(t *testing.T) {
	cmd := bridgeCommand(Addr{Scheme: "ssh", Host: "x", Kero: "/opt/it's/kero"}, "")
	if !strings.HasPrefix(cmd, "sh -c '") || !strings.Contains(cmd, `'\''`) {
		t.Errorf("%s", cmd)
	}
	if args := sshArgs(Addr{Scheme: "ssh", Host: "devbox", User: "me", Port: "2222"}); args[len(args)-3] != "--" || args[len(args)-2] != "devbox" {
		t.Errorf("ssh %q: the host must follow --", args)
	}
	// cmd runs the command of sh as far as it says it has no sh, before
	// which it would act on its characters.
	if c := bridgeCommand(Addr{Scheme: "ssh", Host: "x"}, ""); strings.ContainsAny(c, `"<>|&%^`) {
		t.Errorf("cmd would read %s", c)
	}
	// cmd /c takes the quotes off a command that starts with one, and the
	// SSH server those of one for PowerShell.
	for _, a := range []Addr{{Scheme: "ssh", Host: "x"}, {Scheme: "ssh", Host: "x", Kero: "C:/kero/kero.exe"}} {
		if c := bridgeCommand(a, shellCmd); strings.HasPrefix(c, `"`) || !strings.Contains(c, "exit /b 127") {
			t.Errorf("cmd: %s", c)
		}
		if c := bridgeCommand(a, shellPowerShell); strings.Contains(c, `"`) || !strings.Contains(c, "exit 127") {
			t.Errorf("PowerShell: %s", c)
		}
	}
	if c := bridgeCommand(Addr{Scheme: "ssh", Host: "x", Kero: "C:/kero/kero.exe"}, shellCmd); !strings.HasPrefix(c, `if exist "C:/kero/kero.exe" ("C:/kero/kero.exe" __bridge`) {
		t.Errorf("cmd, kero=: %s", c)
	}
}

// The shells of Windows tell themselves by how they fail to run sh, in
// whatever language; a Unix sh's failures are none of them.
func TestWindowsShell(t *testing.T) {
	for _, c := range []struct {
		code   int
		stderr string
		want   string
	}{
		{1, "'sh' is not recognized as an internal or external command,\r\noperable program or batch file.\r\n", shellCmd},
		{1, "\"sh\" no se reconoce como un comando interno o externo,\r\n", shellCmd},
		{1, "'sh' 不是内部或外部命令，也不是可运行的程序\r\n", shellCmd},
		{1, "sh : The term 'sh' is not recognized as the name of a cmdlet\r\n    + CategoryInfo          : ObjectNotFound: (sh:String) [], CommandNotFoundException\r\n", shellPowerShell},
		{1, "\x1b[31;1msh: \x1b[31;1mThe term 'sh' is not recognized as a name of a cmdlet\x1b[0m\r\n", shellPowerShell},
		{1, "\x1b[31;1msh: \x1b[31;1m无法将“sh”项识别为 cmdlet\x1b[0m\r\n", shellPowerShell},
		// The same in the host's code page, GBK, which no pattern of quotes
		// matches.
		{1, "sh: \xce\xde\xb7\xa8\xbd\xab\xa1\xb0sh\xa1\xb1\xcf\xee\r\n", shellPowerShell},
		{127, "sh: 1: exec: /opt/kero: not found", ""},
		{2, "sh: 1: Syntax error: \"(\" unexpected", ""},
		{1, "sh: 1: kero: something", ""},
		{1, "sh: line 1: kero: something", ""},
		{1, "sh: -c: line 0: syntax error", ""},
		{2, "'sh' is not recognized as an internal or external command,\r\n", ""},
		{255, "ssh: connect to host x port 22: Connection refused", ""},
		{1, "kero: kerod did not start", ""},
	} {
		if got := windowsShell(c.code, c.stderr); got != c.want {
			t.Errorf("%d %q: %q, want %q", c.code, c.stderr, got, c.want)
		}
	}
}

// fakeSSH is ssh to a host whose shell is $KERO_TEST_SHELL: cmd or
// powershell, which run no sh, or sh. It logs the commands it runs, and
// finds no kero.
func fakeSSH() {
	cmd := os.Args[len(os.Args)-1]
	if f, err := os.OpenFile(os.Getenv("KERO_TEST_SSH_LOG"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
		fmt.Fprintf(f, "%q\n", cmd)
		f.Close()
	}
	shell := os.Getenv("KERO_TEST_SHELL")
	sh := strings.HasPrefix(cmd, "sh -c ")
	switch {
	case shell == "sh" && cmd == "sh -c 'exit 0'":
		os.Exit(0)
	case shell == "sh" && sh:
		fmt.Fprintln(os.Stderr, "kero is not installed on devbox")
		os.Exit(127)
	case shell == "cmd" && sh:
		fmt.Fprint(os.Stderr, "'sh' is not recognized as an internal or external command,\r\noperable program or batch file.\r\n")
		os.Exit(1)
	case shell == "powershell" && sh:
		fmt.Fprint(os.Stderr, "\x1b[31;1msh: \x1b[31;1mThe term 'sh' is not recognized as a name of a cmdlet.\x1b[0m\r\n")
		os.Exit(1)
	case shell == "cmd" && strings.HasPrefix(cmd, "if exist "), shell == "powershell" && strings.HasPrefix(cmd, "$k = @("):
		fmt.Fprint(os.Stderr, "kero is not installed on DEVBOX\r\n")
		os.Exit(127)
	}
	fmt.Fprintln(os.Stderr, "unexpected command")
	os.Exit(2)
}

func TestMain(m *testing.M) {
	if os.Getenv("KERO_TEST_SHELL") != "" {
		fakeSSH()
	}
	os.Exit(m.Run())
}

// A host of Windows is found as its shell fails to run sh, and reached
// with a command of that shell from then on; Kero installs there with
// PowerShell.
func TestDialWindows(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_SSH", exe)
	for i, shell := range []string{"cmd", "powershell", "sh"} {
		log := filepath.Join(t.TempDir(), "ssh.log")
		t.Setenv("KERO_TEST_SHELL", shell)
		t.Setenv("KERO_TEST_SSH_LOG", log)
		a := Addr{Scheme: "ssh", Host: fmt.Sprintf("devbox%d", i)}
		for range 2 {
			ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
			_, err := Dial(ctx, a, Options{})
			cancel()
			if !errors.Is(err, ErrNotInstalled) {
				t.Fatalf("%s: %v", shell, err)
			}
		}
		b, _ := os.ReadFile(log)
		lines := strings.Split(strings.TrimSpace(string(b)), "\n")
		want := 3 // sh -c, then the shell's, then the shell's at once
		if shell == "sh" {
			want = 2
		}
		if len(lines) != want {
			t.Errorf("%s: ran %d commands: %s", shell, len(lines), b)
		}
		if Windows(a) != (shell != "sh") {
			t.Errorf("%s: Windows(%s) = %v", shell, a, Windows(a))
		}
		cmd, err := InstallCommand(a, "2.1.0", true)
		if err != nil {
			t.Fatal(err)
		}
		last := cmd.Args[len(cmd.Args)-1]
		if strings.HasPrefix(last, "powershell ") != (shell != "sh") {
			t.Errorf("%s: installs with %s", shell, last)
		}
	}
}

func TestEncodedPowerShell(t *testing.T) {
	c := encodedPowerShell("Write-Output 'ü'")
	b, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(c, "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "))
	if err != nil || len(b) != 2*len([]rune("Write-Output 'ü'")) || b[0] != 'W' || b[1] != 0 {
		t.Errorf("%s: %v %v", c, b, err)
	}
	if s := powershellInstall("2.1.0"); !strings.Contains(s, "/v2.1.0/install-server.ps1'") || !strings.Contains(s, "-Version '2.1.0'") {
		t.Error(s)
	}
}

func TestValidName(t *testing.T) {
	for name, ok := range map[string]bool{"build": true, "build-2.lab": true, "a_b": true, "local": false, "LOCAL": false,
		"": false, "-x": false, "a b": false, ".x": false, "x/y": false} {
		if ValidName(name) != ok {
			t.Errorf("ValidName(%q) = %v", name, !ok)
		}
	}
}

func TestParseListen(t *testing.T) {
	for in, want := range map[string]Listen{
		"tailnet://":                     {Kind: "tailnet", Port: ListenPort()},
		"tailnet://:7400":                {Kind: "tailnet", Port: "7400"},
		"tailnet-serve://":               {Kind: "tailnet-serve"},
		"tailnet-serve:///run/kero.sock": {Kind: "tailnet-serve", Path: "/run/kero.sock"},
	} {
		got, err := ParseListen(in)
		if err != nil || got != want {
			t.Errorf("%q: %+v, %v", in, got, err)
		}
	}
	// A test is a development build, whose kerod listens beside the
	// installed Kero's.
	if ListenPort() == DefaultPort {
		t.Errorf("a development build listens on %s, as the installed Kero", DefaultPort)
	}
	for _, bad := range []string{"tcp://:80", "tailnet://0.0.0.0:7373", "tailnet-serve://host/x", ":7373", "tailnet://:0", "tailnet://:99999"} {
		if l, err := ParseListen(bad); err == nil {
			t.Errorf("%q read as %+v", bad, l)
		}
	}
}

// pipes are the ends of a connection the test's client and server share:
// TCP's on loopback, which buffer what is written, as the pipes of ssh do.
func pipes() (client, server io.ReadWriteCloser) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	defer ln.Close()
	ch := make(chan net.Conn, 1)
	go func() {
		c, _ := ln.Accept()
		ch <- c
	}()
	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		panic(err)
	}
	return c, <-ch
}

// echoServer answers each stream's Hello with a Welcome naming its kind,
// then echoes what comes.
func echoServer(t *testing.T) *Server {
	return &Server{
		Info: func() proto.HostInfo {
			return proto.HostInfo{OS: "linux", Hostname: "box", Kero: "9.9.9", Version: proto.Version}
		},
		Stream: func(s net.Conn, hello []byte, mux proto.MuxHello) {
			defer s.Close()
			var h proto.Hello
			if err := json.Unmarshal(hello, &h); err != nil {
				t.Errorf("hello %q: %v", hello, err)
				return
			}
			b, _ := json.Marshal(proto.Welcome{Version: proto.Version, App: h.Kind + "/" + mux.Client})
			s.Write(append(b, '\n'))
			io.Copy(s, s)
		},
		Restart: func() (func(), error) { return nil, nil },
		Update: func(app string) error {
			if app == "bad" {
				return errors.New("no such version")
			}
			return nil
		},
	}
}

func dialPipe(t *testing.T, s *Server, junk string) (*Conn, chan error) {
	t.Helper()
	cl, sv := pipes()
	done := make(chan error, 1)
	go func() {
		if junk != "" {
			// What a shell's startup files print before the bridge runs.
			io.WriteString(sv, junk)
		}
		done <- s.Serve(sv)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := handshake(ctx, cl, Addr{Scheme: "ssh", Host: "box"}, Options{App: "1.0", Client: "test"})
	if err != nil {
		t.Fatal(err)
	}
	return c, done
}

func TestMuxStreams(t *testing.T) {
	c, done := dialPipe(t, echoServer(t), "Welcome to the box!\nlast login: today")
	if c.Welcome.Host.Hostname != "box" || c.Welcome.Compress != deflate {
		t.Fatalf("welcome %+v", c.Welcome)
	}
	var wg sync.WaitGroup
	for i := range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s, err := c.Dial()
			if err != nil {
				t.Error(err)
				return
			}
			defer s.Close()
			kind := "control"
			if i%2 == 1 {
				kind = "attach"
			}
			b, _ := json.Marshal(proto.Hello{Kind: kind, Version: proto.Version})
			s.Write(append(b, '\n'))
			r := bufio.NewReader(s)
			line, err := r.ReadBytes('\n')
			if err != nil {
				t.Error(err)
				return
			}
			var w proto.Welcome
			json.Unmarshal(line, &w)
			if w.App != kind+"/test" {
				t.Errorf("stream %d: welcome %+v", i, w)
			}
			// Much output, as a screen's first frame: it compresses, and
			// comes back whole.
			payload := bytes.Repeat([]byte(fmt.Sprintf("\x1b[38;5;%dmline %d of stream %d\r\n", i, i, i)), 20000)
			go s.Write(payload)
			got := make([]byte, len(payload))
			if _, err := io.ReadFull(r, got); err != nil || !bytes.Equal(got, payload) {
				t.Errorf("stream %d: echoed %d bytes, %v", i, len(got), err)
			}
		}()
	}
	wg.Wait()
	if _, err := c.Ping(); err != nil {
		t.Error(err)
	}
	ctx := context.Background()
	if err := c.Host(ctx, proto.HostRequest{Kind: proto.KindRestart}); err != nil {
		t.Error(err)
	}
	if err := c.Host(ctx, proto.HostRequest{Kind: proto.KindUpdate, App: "2.0"}); err != nil {
		t.Error(err)
	}
	if err := c.Host(ctx, proto.HostRequest{Kind: proto.KindUpdate, App: "bad"}); err == nil || !strings.Contains(err.Error(), "no such version") {
		t.Errorf("update to a bad version: %v", err)
	}
	c.Close()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the server did not end with the connection")
	}
	select {
	case <-c.Done():
	default:
		t.Error("Done is not closed")
	}
}

func TestMuxRefusesHostRequests(t *testing.T) {
	s := echoServer(t)
	s.Restart, s.Update = nil, nil
	c, _ := dialPipe(t, s, "")
	defer c.Close()
	if err := c.Host(context.Background(), proto.HostRequest{Kind: proto.KindUpdate, App: "2.0"}); err == nil || !strings.Contains(err.Error(), "as it was installed") {
		t.Errorf("update: %v", err)
	}
}

func TestMuxOtherVersion(t *testing.T) {
	cl, sv := pipes()
	go func() {
		br := bufio.NewReader(sv)
		br.ReadBytes('\n')
		b, _ := json.Marshal(proto.MuxWelcome{Mux: proto.MuxVersion + 1, Host: proto.HostInfo{Kero: "9.0"}})
		sv.Write(append(b, '\n'))
	}()
	_, err := handshake(context.Background(), cl, Addr{Scheme: "ssh", Host: "x"}, Options{})
	if err == nil || !strings.Contains(err.Error(), "Kero 9.0") {
		t.Errorf("a host of another mux version: %v", err)
	}
	cl, sv = pipes()
	go func() {
		// Not Kero at all: a shell that says nothing of it.
		bufio.NewReader(sv).ReadBytes('\n')
		io.WriteString(sv, strings.Repeat("hello\n", 200))
	}()
	if _, err := handshake(context.Background(), cl, Addr{Scheme: "ssh", Host: "x"}, Options{}); err == nil || !strings.Contains(err.Error(), "not Kero") {
		t.Errorf("not Kero: %v", err)
	}
}

func TestMuxHandshakeTimesOut(t *testing.T) {
	cl, _ := pipes()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := handshake(ctx, cl, Addr{Scheme: "ssh", Host: "x"}, Options{})
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) > 2*time.Second {
		t.Errorf("a host that never answers: %v after %s", err, time.Since(start))
	}
}

func TestFlateConn(t *testing.T) {
	a, b := pipes()
	fa, fb := newFlateConn(a), newFlateConn(b)
	msgs := []string{"x", strings.Repeat("abc", 100000), "\x00\x01", "end"}
	go func() {
		for _, m := range msgs {
			fa.Write([]byte(m))
		}
	}()
	for _, m := range msgs {
		got := make([]byte, len(m))
		if _, err := io.ReadFull(fb, got); err != nil || string(got) != m {
			t.Fatalf("read %d bytes of %d: %v", len(got), len(m), err)
		}
	}
}

// Plain http:// carries Kero only to a tailnet peer, or through a tunnel
// of this machine's.
func TestTailnetAddr(t *testing.T) {
	for ip, ok := range map[string]bool{"100.64.0.1": true, "100.127.255.254": true, "fd7a:115c:a1e0::1": true, "127.0.0.1": true, "::1": true,
		"192.168.1.10": false, "10.0.0.1": false, "100.128.0.1": false, "8.8.8.8": false, "fe80::1": false} {
		if got := tailnetAddr(netip.MustParseAddr(ip)); got != ok {
			t.Errorf("tailnetAddr(%s) = %v", ip, got)
		}
	}
}

// The bridge's sh finds kero where it looks, a path with a space too, and
// says when there is none.
func TestBridgeScript(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("sh of Windows takes no Unix paths")
	}
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skip(err)
	}
	for _, loc := range []string{"", ".local/bin/kero", "Library/Application Support/kero/bin/kero"} {
		home := t.TempDir()
		if loc != "" {
			os.MkdirAll(filepath.Dir(filepath.Join(home, loc)), 0o755)
			os.WriteFile(filepath.Join(home, loc), []byte("#!/bin/sh\necho \"$0 $*\"\n"), 0o755)
		}
		cmd := exec.Command(sh, "-c", bridgeScript(Addr{Scheme: "ssh", Host: "x"}, "ssh"))
		cmd.Env = []string{"HOME=" + home, "PATH=" + home + "/none"}
		out, err := cmd.Output()
		if loc == "" {
			var ee *exec.ExitError
			if !errors.As(err, &ee) || ee.ExitCode() != bridgeNotFound {
				t.Errorf("no kero: %q, %v", out, err)
			}
			continue
		}
		if want := filepath.Join(home, loc) + " __bridge --via ssh\n"; err != nil || string(out) != want {
			t.Errorf("%s: %q, %v; want %q", loc, out, err, want)
		}
	}
}

// An install finds a host of Windows before it runs, as its shell fails to
// run sh.
func TestFindShell(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_SSH", exe)
	t.Setenv("KERO_TEST_SSH_LOG", filepath.Join(t.TempDir(), "ssh.log"))
	for i, shell := range []string{"cmd", "powershell", "sh"} {
		t.Setenv("KERO_TEST_SHELL", shell)
		a := Addr{Scheme: "ssh", Host: fmt.Sprintf("probe%d", i)}
		if err := FindShell(a, true); err != nil {
			t.Errorf("%s: %v", shell, err)
		}
		if Windows(a) != (shell != "sh") {
			t.Errorf("%s: Windows = %v", shell, Windows(a))
		}
	}
}
