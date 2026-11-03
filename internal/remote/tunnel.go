package remote

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"time"

	"kero/internal/proto"
)

// Errors a tunnel tells apart.
var (
	// ErrPortRefused: nothing listens on the port, on the host's loopback.
	ErrPortRefused = errors.New("nothing listens on that port on the host")
	// ErrNoPorts: Kero on the host is older than ports.
	ErrNoPorts = errors.New("Kero on the host is too old to forward ports: update it")
)

// DialPort opens a stream to a port of the host's loopback: its kerod
// connects it there, and to nowhere else, whichever transport this
// connection runs over.
func (c *Conn) DialPort(port int) (net.Conn, error) {
	st, err := c.Open()
	if err != nil {
		return nil, err
	}
	nc, err := openPort(st, port)
	if err != nil {
		st.Close()
		return nil, err
	}
	return nc, nil
}

// openPort asks for a port over a stream, and returns the stream, its
// bytes the port's.
func openPort(st net.Conn, port int) (net.Conn, error) {
	b, _ := json.Marshal(proto.Hello{Kind: proto.KindPort, Version: proto.Version, Port: port})
	if _, err := st.Write(append(b, '\n')); err != nil {
		return nil, err
	}
	st.SetReadDeadline(time.Now().Add(30 * time.Second))
	br := bufio.NewReaderSize(st, 4<<10)
	line, err := readLine(br)
	st.SetReadDeadline(time.Time{})
	if err != nil {
		return nil, err
	}
	var w proto.Welcome
	if err := json.Unmarshal(line, &w); err != nil {
		return nil, err
	}
	switch {
	case w.Refused:
		return nil, ErrPortRefused
	case w.Error != "":
		return nil, errors.New(w.Error)
	case w.Port != port:
		// An older kerod took this for a control connection.
		return nil, ErrNoPorts
	}
	return portConn{Conn: st, r: br}, nil
}

// Handshake opens a remote connection over a stream the caller has, as Dial does
// over its transports.
func Handshake(ctx context.Context, rwc io.ReadWriteCloser) (*Conn, error) {
	return handshake(ctx, rwc, Addr{}, Options{})
}

// portConn is a stream whose first bytes may have been read already, with
// what answered: a server may speak first.
type portConn struct {
	net.Conn
	r io.Reader
}

func (c portConn) Read(p []byte) (int, error) { return c.r.Read(p) }
