package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"path/filepath"
	"slices"
	"sync"
	"syscall"
	"testing"
	"time"

	"kero/internal/client"
	"kero/internal/proto"
)

// Split Right creates a session when there is no pane to split, and
// splits the selected session otherwise.
func TestSplitRightWithoutSessionStartsOne(t *testing.T) {
	a := testApp(t)
	a.st.Sessions, a.selected = nil, ""
	a.local().conn = connReady
	calls := make(chan string, 2)
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		switch method {
		case "create":
			var p proto.CreateParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			calls <- method
			return proto.Session{ID: "s2", Project: p.Project}, nil
		case "split":
			var p proto.CreateParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			calls <- method
			return proto.Session{ID: "s1"}, nil
		default:
			return nil, errors.New("unexpected method " + method)
		}
	})
	a.local().cl = cl
	defer stop()

	a.run("pane.split.right", nil)
	select {
	case got := <-calls:
		if got != "create" {
			t.Fatalf("Split Right called %q with no session, want create", got)
		}
	case <-time.After(time.Second):
		t.Fatal("Split Right did not create a session")
	}

	a.st.Sessions = []proto.Session{{ID: "s1"}}
	a.selected = "s1"
	a.focus["s1"] = "a"
	a.run("pane.split.right", nil)
	select {
	case got := <-calls:
		if got != "split" {
			t.Fatalf("Split Right called %q with a session, want split", got)
		}
	case <-time.After(time.Second):
		t.Fatal("Split Right did not split the session")
	}
}

// projectClient speaks the real control protocol without starting the user's daemon.
func projectClient(t *testing.T, handle func(string, json.RawMessage) (any, error)) (*client.Client, func()) {
	t.Helper()
	t.Setenv("KERO_HOME", t.TempDir())
	t.Setenv("KERO_SOCKET", "")
	listener, err := net.Listen("unix", proto.SocketPath())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		dec, enc := json.NewDecoder(conn), json.NewEncoder(conn)
		var hello proto.Hello
		if err := dec.Decode(&hello); err != nil {
			t.Error(err)
			return
		}
		if err := enc.Encode(proto.Welcome{Version: proto.Version}); err != nil {
			t.Error(err)
			return
		}
		for {
			var req struct {
				ID     int64           `json:"id"`
				Method string          `json:"method"`
				Params json.RawMessage `json:"params"`
			}
			if err := dec.Decode(&req); err != nil {
				// A client gone with an answer unread resets the
				// connection, which is no more an error than EOF.
				if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) && !errors.Is(err, syscall.ECONNRESET) {
					t.Error(err)
				}
				return
			}
			result, err := handle(req.Method, req.Params)
			msg := proto.Message{ID: req.ID, Result: result}
			if err != nil {
				msg.Error = err.Error()
			}
			if err := enc.Encode(msg); err != nil {
				return
			}
		}
	}()
	cl, err := client.Connect(true)
	if err != nil {
		t.Fatal(err)
	}
	stop := sync.OnceFunc(func() { cl.Close(); listener.Close(); <-done })
	t.Cleanup(stop)
	return cl, stop
}

func TestOpenProjectDirectories(t *testing.T) {
	a := testApp(t)
	first, second, alias, failed := t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir()
	invalid := filepath.Join(t.TempDir(), "file.txt")
	packaged := filepath.Join(t.TempDir(), "Application.app")
	var opened []string
	cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
		switch method {
		case "project.create":
			var p proto.ProjectParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			switch p.Dir {
			case first, alias:
				return proto.Project{ID: "first", Dir: first}, nil
			case second:
				return proto.Project{ID: "second", Dir: second}, nil
			case failed:
				return proto.Project{ID: "failed", Dir: failed}, nil
			case invalid:
				return nil, errors.New("not a directory")
			case packaged:
				return nil, errors.New("cannot open a file package as a project")
			default:
				t.Errorf("project.create received unsupported drop %q", p.Dir)
				return nil, errors.New("unsupported drop")
			}
		case "create":
			var p proto.CreateParams
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, err
			}
			if p.Project == "failed" {
				return nil, errors.New("shell could not start")
			}
			opened = append(opened, p.Dir)
			return proto.Session{ID: "session-" + p.Project, Project: p.Project, Dir: p.Dir}, nil
		default:
			t.Errorf("unexpected method %q", method)
			return nil, errors.New("unexpected method")
		}
	})
	a.local().cl = cl
	a.openProjectDirs(a.local(), cl, []string{first, invalid, alias, "", "relative", "file:///tmp/project", failed, packaged, second}, true)
	stop()
	if want := []string{first, second}; !slices.Equal(opened, want) {
		t.Errorf("sessions opened in %q, want %q", opened, want)
	}
}

func TestOpenProjectRemotePaths(t *testing.T) {
	for _, dir := range []string{`C:\Projects\日本語 project`, `/srv/project`} {
		t.Run(dir, func(t *testing.T) {
			a := testApp(t)
			var opened []string
			cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
				switch method {
				case "project.create":
					var p proto.ProjectParams
					if err := json.Unmarshal(raw, &p); err != nil {
						return nil, err
					}
					if p.Dir != dir {
						t.Errorf("remote directory = %q, want %q", p.Dir, dir)
					}
					return proto.Project{ID: "remote-project", Dir: p.Dir}, nil
				case "create":
					var p proto.CreateParams
					if err := json.Unmarshal(raw, &p); err != nil {
						return nil, err
					}
					opened = append(opened, p.Dir)
					return proto.Session{ID: "remote-session", Project: p.Project, Dir: p.Dir}, nil
				default:
					return nil, errors.New("unexpected method")
				}
			})
			h := &host{name: "remote", cl: cl, conn: connReady}
			a.hosts = append(a.hosts, h)
			a.openProjectDirs(h, cl, []string{dir}, false)
			stop()
			if !slices.Equal(opened, []string{dir}) {
				t.Errorf("remote sessions opened in %q, want [%q]", opened, dir)
			}
		})
	}
}
