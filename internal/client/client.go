// Package client connects to kerod, starting it when it is not running.
package client

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"

	"kero/internal/detach"
	"kero/internal/proto"
	"kero/internal/service"
)

// ErrVersion is returned when the daemon running speaks another protocol,
// as after kero was updated: it has to be restarted.
var ErrVersion = errors.New("kerod is of another version")

// Dialer opens connections to a kerod: this machine's, through its socket
// (Local), or a host's, as streams of a remote connection (remote.Conn).
type Dialer interface {
	Dial() (net.Conn, error)
}

// Local is this machine's kerod, which a dial starts unless NoStart.
type Local struct{ NoStart bool }

func (l Local) Dial() (net.Conn, error) { return dial(l.NoStart) }

// dial connects to the daemon, starting it unless noStart.
func dial(noStart bool) (net.Conn, error) {
	sock := proto.SocketPath()
	conn, err := net.Dial("unix", sock)
	if err == nil {
		return conn, nil
	}
	if noStart {
		return nil, fmt.Errorf("kerod is not running: %w", err)
	}
	if err := StartDaemon(); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		conn, err = net.Dial("unix", sock)
		if err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("kerod did not start: %w (see %s)", err, filepath.Join(proto.Dir(), "kerod.log"))
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// Exe is the executable StartDaemon runs, os.Executable's when empty: the
// bridge sets it as it starts, as an update moves the install it runs
// from aside, and os.Executable then names the old one.
var Exe string

// StartDaemon starts kerod in the background: the service, when kerod
// runs as one (kero daemon install-service), else this executable (Exe),
// in a session of its own, so that it outlives whoever started it.
func StartDaemon() error {
	// The service's, or none: a kerod beside it would hold the lock its
	// manager starts the service's for, again and again. But Task
	// Scheduler's, which starts none while no one is logged on to the
	// machine, and never again: a kerod of its own then.
	if service.Installed() {
		err := service.Start()
		if err == nil {
			return nil
		}
		if runtime.GOOS != "windows" {
			return fmt.Errorf("kerod's service did not start: %w", err)
		}
	}
	exe := Exe
	if exe == "" {
		var err error
		if exe, err = os.Executable(); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(proto.Dir(), 0o700); err != nil {
		return err
	}
	logf, err := os.OpenFile(filepath.Join(proto.Dir(), "kerod.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logf.Close()
	cmd := exec.Command(exe, "__kerod")
	cmd.Dir = proto.Home()
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd, err = detach.Start(cmd)
	if err != nil {
		return err
	}
	go cmd.Wait() // reap it, should it exit while we run
	return nil
}

func handshake(conn net.Conn, hello proto.Hello) (proto.Welcome, *bufio.Reader, error) {
	hello.Version = proto.Version
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		return proto.Welcome{}, nil, err
	}
	r := bufio.NewReaderSize(conn, 64<<10)
	conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	line, err := proto.ReadLine(r, 64<<10)
	conn.SetReadDeadline(time.Time{})
	if err != nil {
		return proto.Welcome{}, nil, err
	}
	var w proto.Welcome
	if err := json.Unmarshal(line, &w); err != nil {
		return w, nil, err
	}
	if w.Version != proto.Version {
		return w, nil, ErrVersion
	}
	if w.Error != "" {
		return w, nil, errors.New(w.Error)
	}
	return w, r, nil
}

// DaemonPID returns the pid of the daemon running, whatever its version,
// or 0.
func DaemonPID() int {
	conn, err := dial(true)
	if err != nil {
		return 0
	}
	defer conn.Close()
	w, _, _ := handshake(conn, proto.Hello{Kind: "control"})
	return w.PID
}

// Client is a control connection.
type Client struct {
	conn    net.Conn
	Welcome proto.Welcome

	wmu     sync.Mutex
	enc     *json.Encoder
	mu      sync.Mutex
	nextID  int64
	pending map[int64]chan response
	onEvent func(proto.Message)
	closed  chan struct{}
	err     error
}

type response struct {
	result json.RawMessage
	err    error
}

// Connect opens a control connection to this machine's kerod, starting it
// unless noStart.
func Connect(noStart bool) (*Client, error) { return ConnectVia(Local{NoStart: noStart}) }

// ConnectVia opens a control connection through d.
func ConnectVia(d Dialer) (*Client, error) {
	conn, err := d.Dial()
	if err != nil {
		return nil, err
	}
	w, r, err := handshake(conn, proto.Hello{Kind: "control"})
	if err != nil {
		conn.Close()
		return nil, err
	}
	c := &Client{conn: conn, Welcome: w, enc: json.NewEncoder(conn), pending: map[int64]chan response{}, closed: make(chan struct{})}
	go c.read(r)
	return c, nil
}

// OnEvent sets the function events go to, on the client's goroutine.
func (c *Client) OnEvent(fn func(proto.Message)) {
	c.mu.Lock()
	c.onEvent = fn
	c.mu.Unlock()
}

// Done is closed once the connection ended.
func (c *Client) Done() <-chan struct{} { return c.closed }

func (c *Client) Close() error { return c.conn.Close() }

func (c *Client) read(r *bufio.Reader) {
	defer func() {
		c.mu.Lock()
		for id, ch := range c.pending {
			ch <- response{err: errors.New("kerod went away")}
			delete(c.pending, id)
		}
		c.mu.Unlock()
		close(c.closed)
	}()
	for {
		line, err := proto.ReadLine(r, proto.MaxLine)
		if err != nil {
			return
		}
		var m struct {
			ID     int64           `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
			Event  string          `json:"event"`
		}
		if json.Unmarshal(line, &m) != nil {
			continue
		}
		if m.Event != "" {
			var ev proto.Message
			if json.Unmarshal(line, &ev) == nil {
				c.mu.Lock()
				fn := c.onEvent
				c.mu.Unlock()
				if fn != nil {
					fn(ev)
				}
			}
			continue
		}
		c.mu.Lock()
		ch := c.pending[m.ID]
		delete(c.pending, m.ID)
		c.mu.Unlock()
		if ch != nil {
			var err error
			if m.Error != "" {
				err = errors.New(m.Error)
			}
			ch <- response{result: m.Result, err: err}
		}
	}
}

// Call calls a method of the daemon, decoding its result into out.
func (c *Client) Call(method string, params, out any) error {
	ch := make(chan response, 1)
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	c.pending[id] = ch
	c.mu.Unlock()
	c.wmu.Lock()
	err := c.enc.Encode(proto.Request{ID: id, Method: method, Params: params})
	c.wmu.Unlock()
	if err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return err
	}
	res := <-ch
	if res.err != nil {
		return res.err
	}
	if out != nil && len(res.result) > 0 {
		return json.Unmarshal(res.result, out)
	}
	return nil
}

// Go calls a method without waiting for its result, reporting an error to
// fn when set.
func (c *Client) Go(method string, params any, fn func(error)) {
	go func() {
		err := c.Call(method, params, nil)
		if fn != nil {
			fn(err)
		}
	}()
}

// Stream is a session's terminal stream: an io.ReadWriteCloser for the
// terminal plugin's Conn, with ResizePixels and UseTheme, which it calls
// with its size and its colors.
type Stream struct {
	conn    net.Conn
	r       *bufio.Reader
	Welcome proto.Welcome

	wmu    sync.Mutex
	buf    []byte
	closed chan struct{}
	once   sync.Once
	// Gone is closed when the daemon closed the session (FrameClosed).
	Gone     chan struct{}
	goneOnce sync.Once
	// OnResized, when set, gets the sizes the session's terminal takes
	// (FrameResized), within Read, before the output after them: set it
	// before the first Read.
	OnResized func(cols, rows int)
}

// Attach opens a session's stream. What reads from it gets frames of the
// session's terminal (proto.FrameOutput), the first of them at the size of
// Welcome.
func Attach(id string) (*Stream, error) { return AttachVia(Local{NoStart: true}, id) }

// AttachVia opens a session's stream through d.
func AttachVia(d Dialer, id string) (*Stream, error) {
	conn, err := d.Dial()
	if err != nil {
		return nil, err
	}
	w, r, err := handshake(conn, proto.Hello{Kind: "attach", Session: id})
	if err != nil {
		conn.Close()
		return nil, err
	}
	return &Stream{conn: conn, r: r, Welcome: w, closed: make(chan struct{}), Gone: make(chan struct{})}, nil
}

func (s *Stream) Read(p []byte) (int, error) {
	for len(s.buf) == 0 {
		kind, payload, err := proto.ReadFrame(s.r)
		if err != nil {
			return 0, io.EOF
		}
		switch kind {
		case proto.FrameOutput:
			s.buf = payload
		case proto.FrameClosed:
			s.goneOnce.Do(func() { close(s.Gone) })
		case proto.FrameResized:
			if c, r, ok := proto.ParseResize(payload); ok && s.OnResized != nil {
				s.OnResized(c, r)
			}
		}
	}
	n := copy(p, s.buf)
	s.buf = s.buf[n:]
	return n, nil
}

func (s *Stream) Write(p []byte) (int, error) {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	if err := proto.WriteFrame(s.conn, proto.FrameInput, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// ResizePixels tells the daemon the terminal's size, and its cells' in
// pixels, which the program gets.
func (s *Stream) ResizePixels(cols, rows, cellWidth, cellHeight int) error {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	return proto.WriteFrame(s.conn, proto.FrameResize, proto.ResizePixelsPayload(cols, rows, cellWidth, cellHeight))
}

// Claim tells the daemon the user moved into this terminal, which the
// session then takes the size of (proto.FrameClaim).
func (s *Stream) Claim() error {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	return proto.WriteFrame(s.conn, proto.FrameClaim, nil)
}

// UseTheme tells the daemon the colors the terminal shows, which programs
// asking about them get.
func (s *Stream) UseTheme(theme *terminal.Theme) error {
	if theme == nil {
		return nil
	}
	rgba := func(c ui.Color) [4]byte { return [4]byte{c.R, c.G, c.B, c.A} }
	t := proto.Theme{Foreground: rgba(theme.Foreground), Background: rgba(theme.Background), Cursor: rgba(theme.Cursor)}
	for i, c := range theme.Palette {
		t.Palette[i] = rgba(c)
	}
	s.wmu.Lock()
	defer s.wmu.Unlock()
	return proto.WriteFrame(s.conn, proto.FrameTheme, t.Payload())
}

// Clear asks the session's terminal to clear, what being
// proto.ClearScreen or proto.ClearScrollback (proto.FrameClear), in order
// with what is typed.
func (s *Stream) Clear(what byte) error {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	return proto.WriteFrame(s.conn, proto.FrameClear, []byte{what})
}

func (s *Stream) Close() error {
	var err error
	s.once.Do(func() {
		close(s.closed)
		err = s.conn.Close()
	})
	return err
}
