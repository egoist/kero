package daemon

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"kero/internal/proto"
)

// tcpListener is a socket listening, as the platform tells it: its address
// and port, and what holds it, when the user may see that.
type tcpListener struct {
	addr string
	port int
	pid  int
	name string
}

// portsCache keeps the last list a moment, for clients asking at once:
// listing walks every process's sockets.
var portsCache struct {
	sync.Mutex
	at   time.Time
	list []tcpListener
	err  error
}

// cachedListeners lists what listens on this machine, from what was listed less
// than a second ago, if any.
func cachedListeners() ([]tcpListener, error) {
	portsCache.Lock()
	defer portsCache.Unlock()
	if time.Since(portsCache.at) > time.Second {
		portsCache.list, portsCache.err = tcpListeners()
		portsCache.at = time.Now()
	}
	return portsCache.list, portsCache.err
}

// portList lists the TCP ports listening on this machine, which of them
// the panes' programs hold, by port.
func (d *Daemon) portList() (proto.PortList, error) {
	ls, err := cachedListeners()
	if err != nil {
		return proto.PortList{}, err
	}
	return proto.PortList{Ports: mergePorts(ls, d.paneShells(), procParent, procBundled, os.Getpid())}, nil
}

// paneRef is a pane, by the shell it runs.
type paneRef struct{ pane, session string }

// paneShells maps the shells of the panes running to their panes.
func (d *Daemon) paneShells() map[int]paneRef {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make(map[int]paneRef, len(d.panes))
	for _, p := range d.panes {
		p.mu.Lock()
		if p.shellPID > 0 && p.info.Status != proto.Exited {
			out[p.shellPID] = paneRef{p.info.ID, p.sid}
		}
		p.mu.Unlock()
	}
	return out
}

// paneOfProcess finds the pane a process is of: the one whose shell it
// descends from. A daemon that left its shell, whose parent is init, is of
// none.
func paneOfProcess(pid int, shells map[int]paneRef, parent func(int) int) (paneRef, bool) {
	for i := 0; i < 64 && pid > 1; i++ {
		if r, ok := shells[pid]; ok {
			return r, true
		}
		pid = parent(pid)
	}
	return paneRef{}, false
}

// mergePorts makes the ports of the sockets: a port listening on several
// addresses, or held by several processes, as a server's workers, is one.
// It shows the process of a pane where any holds it, else the first.
func mergePorts(ls []tcpListener, shells map[int]paneRef, parent func(int) int, bundled func(int) bool, self int) []proto.Port {
	byPort := map[int]*proto.Port{}
	selfs := map[int]bool{}
	apps := map[int]bool{}
	for _, l := range ls {
		p := byPort[l.port]
		if p == nil {
			p = &proto.Port{Port: l.port}
			byPort[l.port] = p
		}
		if !slices.Contains(p.Addrs, l.addr) {
			p.Addrs = append(p.Addrs, l.addr)
		}
		if l.pid == 0 {
			continue
		}
		r, owned := paneOfProcess(l.pid, shells, parent)
		switch {
		case owned && p.Pane == "":
			p.PID, p.Process, p.Pane, p.Session = l.pid, l.name, r.pane, r.session
		case p.PID == 0:
			p.PID, p.Process = l.pid, l.name
		}
		if p.PID == l.pid {
			selfs[l.port] = l.pid == self
			apps[l.port] = bundled(l.pid)
		}
	}
	out := make([]proto.Port, 0, len(byPort))
	for port, p := range byPort {
		slices.SortFunc(p.Addrs, compareAddrs)
		p.System = systemPort(*p, apps[port], selfs[port])
		out = append(out, *p)
	}
	slices.SortFunc(out, func(a, b proto.Port) int { return cmp.Compare(a.Port, b.Port) })
	return out
}

// compareAddrs puts the addresses a server listens on in the order to read
// them: the wider first, IPv4 before IPv6.
func compareAddrs(a, b string) int {
	rank := func(s string) int {
		ip, err := netip.ParseAddr(s)
		switch {
		case err != nil:
			return 4
		case ip.IsUnspecified() && ip.Is4():
			return 0
		case ip.IsUnspecified():
			return 1
		case ip.IsLoopback() && ip.Is4():
			return 2
		case ip.IsLoopback():
			return 3
		}
		return 4
	}
	return cmp.Or(cmp.Compare(rank(a), rank(b)), cmp.Compare(a, b))
}

// systemProcesses are what a machine runs for itself, by the name of the
// process, in lower case: services, on any platform, not servers of the
// user's.
var systemProcesses = map[string]bool{
	// macOS
	"controlcenter": true, "rapportd": true, "sharingd": true, "mdnsresponder": true, "launchd": true, "airplayxpchelper": true,
	"identityservicesd": true, "remoted": true, "screensharingd": true, "cupsd": true, "netbiosd": true, "smbd": true,
	// Linux
	"systemd": true, "systemd-resolved": true, "systemd-network": true, "sshd": true, "sshd-session": true, "avahi-daemon": true,
	"dnsmasq": true, "rpcbind": true, "rpc.statd": true, "chronyd": true, "named": true, "master": true, "exim4": true, "dhclient": true,
	"tailscaled": true, "containerd": true, "dockerd": true, "snapd": true, "gvfsd": true, "kdeconnectd": true,
	// Windows
	"system": true, "svchost": true, "lsass": true, "wininit": true, "services": true, "spoolsv": true, "wslrelay": true,
	"searchhost": true, "msmpeng": true, "officeclicktorun": true, "wslhost": true,
}

// firstEphemeral is where the ports the system gives programs that ask for
// any start: what listens above it chose none of them to be found by. IANA's,
// which macOS and Windows take; Linux's start lower (32768) but dev servers
// rarely sit there either.
const firstEphemeral = 49152

// systemPort tells a port that is rarely what the user looks for, so that
// a dev server stands out: one the system holds, or an app for itself, one
// of the ports only root takes with no one to tell of, one on a random port,
// or one a tunnel cannot reach. A pane's never is: the user started it.
func systemPort(p proto.Port, bundled, self bool) bool {
	switch {
	case p.Pane != "":
		return false
	case self, bundled, !p.Reachable(), p.Port >= firstEphemeral:
		return true
	case p.PID == 0:
		return p.Port < 1024
	}
	return systemProcesses[strings.ToLower(strings.TrimSuffix(p.Process, ".exe"))]
}

// parseProcNet reads /proc/net/tcp or tcp6: its sockets listening (state
// 0A), each with its inode, which /proc/<pid>/fd tells the process of.
func parseProcNet(data []byte) map[uint64]tcpListener {
	out := map[uint64]tcpListener{}
	for _, line := range bytes.Split(data, []byte{'\n'}) {
		f := strings.Fields(string(line))
		if len(f) < 10 || f[3] != "0A" {
			continue
		}
		a, p, ok := strings.Cut(f[1], ":")
		if !ok {
			continue
		}
		addr, ok := procNetAddr(a)
		port, err := strconv.ParseUint(p, 16, 16)
		inode, err2 := strconv.ParseUint(f[9], 10, 64)
		if !ok || err != nil || err2 != nil {
			continue
		}
		out[inode] = tcpListener{addr: addr, port: int(port)}
	}
	return out
}

// procNetAddr reads an address of /proc/net: bytes in hexadecimal, in words
// of 32 bits of the machine's order, which every platform Kero runs on has
// little-endian.
func procNetAddr(s string) (string, bool) {
	b, err := hex.DecodeString(s)
	if err != nil || len(b)%4 != 0 {
		return "", false
	}
	for i := 0; i < len(b); i += 4 {
		b[i], b[i+1], b[i+2], b[i+3] = b[i+3], b[i+2], b[i+1], b[i]
	}
	ip, ok := netip.AddrFromSlice(b)
	if !ok {
		return "", false
	}
	return ip.Unmap().String(), true
}

// Layouts of macOS's struct socket_fdinfo (sys/proc_info.h), as
// proc_pidfdinfo fills it: a proc_fileinfo of 24 bytes, then a socket_info,
// whose soi_kind and soi_proto follow a vinfo_stat of 136 and its fields; of
// the TCP part, an in_sockinfo of 80, then tcpsi_state.
const (
	sockFamily    = 24 + 160
	sockKind      = 24 + 232
	sockProto     = 24 + 240
	sockInLPort   = sockProto + 4
	sockInVFlag   = sockProto + 24
	sockInLAddr   = sockProto + 48
	sockTCPState  = sockProto + 80
	sockKindTCP   = 2
	sockStateLis  = 1
	sockFlagIPv4  = 1
	sockFlagIPv6  = 2
	sockInfoBytes = sockTCPState + 4
)

// parseSocketInfo reads a socket_fdinfo: the address and port of a TCP
// socket listening.
func parseSocketInfo(b []byte) (string, int, bool) {
	if len(b) < sockInfoBytes {
		return "", 0, false
	}
	u32 := func(at int) uint32 { return binary.LittleEndian.Uint32(b[at:]) }
	if u32(sockKind) != sockKindTCP || u32(sockTCPState) != sockStateLis {
		return "", 0, false
	}
	// In the order of the network, in the low bytes of an int.
	port := int(binary.BigEndian.Uint16(b[sockInLPort:]))
	var ip netip.Addr
	switch vflag := b[sockInVFlag]; {
	case vflag&sockFlagIPv6 != 0:
		ip = netip.AddrFrom16([16]byte(b[sockInLAddr : sockInLAddr+16]))
	case vflag&sockFlagIPv4 != 0:
		ip = netip.AddrFrom4([4]byte(b[sockInLAddr+12 : sockInLAddr+16]))
	default:
		return "", 0, false
	}
	return ip.Unmap().String(), port, true
}

// parseTCPTable reads what Windows' GetExtendedTcpTable wrote for AF_INET
// and TCP_TABLE_OWNER_PID_LISTENER: a count, then rows of state, address,
// port, remote address, remote port and process.
func parseTCPTable(b []byte) []tcpListener {
	const row = 24
	if len(b) < 4 {
		return nil
	}
	n := int(binary.LittleEndian.Uint32(b))
	var out []tcpListener
	for i := range n {
		at := 4 + i*row
		if at+row > len(b) {
			break
		}
		r := b[at : at+row]
		out = append(out, tcpListener{
			addr: netip.AddrFrom4([4]byte(r[4:8])).String(),
			port: int(binary.BigEndian.Uint16(r[8:])),
			pid:  int(binary.LittleEndian.Uint32(r[20:])),
		})
	}
	return out
}

// parseTCP6Table reads what GetExtendedTcpTable wrote for AF_INET6: a
// count, then rows of address, scope, port, remote address, remote scope,
// remote port, state and process.
func parseTCP6Table(b []byte) []tcpListener {
	const row = 56
	if len(b) < 4 {
		return nil
	}
	n := int(binary.LittleEndian.Uint32(b))
	var out []tcpListener
	for i := range n {
		at := 4 + i*row
		if at+row > len(b) {
			break
		}
		r := b[at : at+row]
		out = append(out, tcpListener{
			addr: netip.AddrFrom16([16]byte(r[:16])).Unmap().String(),
			port: int(binary.BigEndian.Uint16(r[20:])),
			pid:  int(binary.LittleEndian.Uint32(r[52:])),
		})
	}
	return out
}

// --- the tunnel's end on the host ---

// loopbackOnly refuses any connection to an address not of this machine's
// loopback, whatever asks: kerod is no proxy to other machines.
func loopbackOnly(_, address string, _ syscall.RawConn) error {
	ap, err := netip.ParseAddrPort(address)
	if err != nil {
		return fmt.Errorf("refused: %q is not an address", address)
	}
	if !ap.Addr().Unmap().IsLoopback() {
		return fmt.Errorf("refused: %s is not this machine's loopback", ap.Addr())
	}
	return nil
}

// loopbackDialer is what connects for a tunnel.
var loopbackDialer = net.Dialer{Timeout: 5 * time.Second, Control: loopbackOnly}

// dialLoopback connects to a port of this machine's loopback, IPv4's or
// IPv6's. A stream names only a port, never an address.
func dialLoopback(ctx context.Context, port int) (net.Conn, error) {
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("%d is not a port", port)
	}
	s := strconv.Itoa(port)
	c, err := loopbackDialer.DialContext(ctx, "tcp", net.JoinHostPort("127.0.0.1", s))
	if err != nil {
		c, err = loopbackDialer.DialContext(ctx, "tcp", net.JoinHostPort("::1", s))
	}
	return c, err
}

// servePort answers a stream of KindPort, connecting it to a port of the
// loopback. Whoever opens one has passed what any stream passes (the
// socket's user, or a listener's identity and listen-allow), and could run
// a program here anyway: it needs nothing more, and gets nothing past the
// loopback.
func (d *Daemon) servePort(conn net.Conn, r *bufio.Reader, hello proto.Hello, welcome proto.Welcome) {
	target, err := dialLoopback(context.Background(), hello.Port)
	if err != nil {
		welcome.Error, welcome.Refused = fmt.Sprintf("nothing listens on port %d of this machine's loopback", hello.Port), true
		json.NewEncoder(conn).Encode(welcome)
		return
	}
	defer target.Close()
	welcome.Port = hello.Port
	if err := json.NewEncoder(conn).Encode(welcome); err != nil {
		return
	}
	pipe(buffered{r, conn}, target)
}

// buffered is a connection whose reads go through a reader that read ahead.
type buffered struct {
	io.Reader
	net.Conn
}

func (b buffered) Read(p []byte) (int, error) { return b.Reader.Read(p) }

// pipe copies both ways between two connections until either ends, then
// closes both.
func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	a.Close()
	b.Close()
}
