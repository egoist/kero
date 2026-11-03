package cli

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/term"

	"kero/internal/client"
	"kero/internal/proto"
	"kero/internal/settings"
)

// attachHintPause is how long the detach key shows, on the screen attach was
// run from, before the pane takes the terminal.
var attachHintPause = time.Second

// attachNoticeAfter is how long the pane may be of another size than the
// terminal before attach says so: a resize's frames come sooner.
const attachNoticeAfter = 300 * time.Millisecond

// needTerminal is kero attach's first check, before it starts kerod for
// nothing.
func needTerminal() error {
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		return usageErr("kero attach needs a terminal for its input and output (over ssh: ssh -t); kero read and kero send need none")
	}
	if os.Getenv("TERM") == "dumb" {
		return usageErr("kero attach can't show a pane in a dumb terminal: kero read and kero send work there")
	}
	return nil
}

// attachCmd is kero attach: the pane shows in this terminal, and what is
// typed goes to it, over the stream the app's terminals use, until the
// detach key.
func attachCmd(c *client.Client, dialer client.Dialer, st proto.State, args []string) error {
	f, err := parse(args, nil, nil)
	if err != nil {
		return err
	}
	if len(f.pos) > 1 || len(f.rest) > 0 {
		return usageErr("kero attach [target]")
	}
	t, err := findOrCurrent(st, f.pos)
	if err != nil {
		return err
	}
	p := t.s.PaneByID(t.pane)
	if p == nil {
		p = t.s.FocusPane()
	}
	switch {
	case p == nil:
		return fmt.Errorf("%w: session %s has no pane", errNotFound, t.s.ID)
	case p.Browser():
		return fmt.Errorf("pane %s shows a page, and has no terminal to attach to: name another pane (kero ls)", p.ID)
	case onHost == "" && p.ID == os.Getenv("KERO_PANE"):
		// Its output would go into its own screen, without end.
		return usageErr("kero attach runs in pane %s: name another pane (kero ls)", p.ID)
	case p.Status == proto.Exited:
		return fmt.Errorf("pane %s exited with code %d: kero read %s prints its screen, kero restart %s starts it again", p.ID, p.ExitCode, p.ID, p.ID)
	}
	keyName := settings.Load().AttachDetachKey
	legacy, code, err := settings.ParseDetachKey(keyName)
	if err != nil {
		keyName = settings.Default().AttachDetachKey
		legacy, code, _ = settings.ParseDetachKey(keyName)
	}
	label := t.s.DisplayName(settings.Load().SessionName)
	if len(t.s.Panes) > 1 {
		label += ", pane " + p.ID
	}

	exited := make(chan int, 1)
	go func() {
		var info proto.Pane
		if err := c.Call("wait", proto.WaitParams{ID: p.ID, Status: []proto.Status{proto.Exited}}, &info); err == nil && info.Status == proto.Exited {
			exited <- info.ExitCode
		}
	}()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, endSignals...)
	defer signal.Stop(signals)
	stop := make(chan struct{})
	defer close(stop)

	end, err := runAttach(attachConfig{
		dial: dialer, pane: p.ID, label: label, client: clientName("kero CLI"),
		in: os.Stdin, out: os.Stdout, keyName: keyName, key: detachMatcher{legacy: legacy, code: code},
		signals: signals, resized: watchResize(stop), exited: exited, lost: c.Done(),
	})
	if err != nil {
		return err
	}
	again := "kero attach " + p.ID
	if onHost != "" {
		again = "kero -H " + onHost + " attach " + p.ID
	}
	switch end.kind {
	case endDetached:
		fmt.Printf("[detached from %s; it keeps running: %s]\n", label, again)
	case endClosed:
		fmt.Printf("[%s ended]\n", label)
	case endExited:
		fmt.Printf("[pane %s exited with code %d: kero read %s prints its screen, kero restart %s starts it again]\n", p.ID, end.code, p.ID, p.ID)
	case endSignal:
		return exitStatus(128 + end.code)
	case endLost:
		if onHost != "" {
			return fmt.Errorf("%w: lost the connection to %s, whose sessions keep running", errUnreachable, onHost)
		}
		return fmt.Errorf("%w: kerod went away (kero daemon status tells whether it's back)", errUnreachable)
	}
	return nil
}

// How an attachment ended.
const (
	endDetached = iota // the detach key
	endHangup          // the terminal went: no one to tell
	endSignal          // a signal, in code
	endClosed          // the pane ended
	endExited          // the pane's program failed, its code in code
	endLost            // kerod, or the connection to its host, went away
)

type attachEnd struct {
	kind, code int
}

// attachConfig is what an attachment runs on.
type attachConfig struct {
	dial          client.Dialer
	pane          string
	label, client string
	in, out       *os.File
	keyName       string
	key           detachMatcher
	signals       <-chan os.Signal
	resized       <-chan struct{}
	exited        <-chan int
	lost          <-chan struct{}
}

// runAttach attaches until something ends it. The outer terminal is as it
// was when it returns, whatever the way.
func runAttach(cfg attachConfig) (attachEnd, error) {
	state, err := term.MakeRaw(int(cfg.in.Fd()))
	if err != nil {
		return attachEnd{}, fmt.Errorf("kero attach: %w", err)
	}
	closeConsole, err := prepareConsole(cfg.out)
	if err != nil {
		term.Restore(int(cfg.in.Fd()), state)
		return attachEnd{}, err
	}
	outer := &outerTerm{w: cfg.out, restoreTTY: func() {
		term.Restore(int(cfg.in.Fd()), state)
		closeConsole()
	}}
	defer outer.restore()
	fmt.Fprintf(cfg.out, "kero: attaching to %s. Press %s to detach.\r\n", cfg.label, cfg.keyName)
	time.Sleep(attachHintPause)
	outer.write([]byte(attachEnter))

	a := &attacher{cfg: cfg, outer: outer, events: make(chan attachEvent, 16), done: make(chan struct{}), claimed: true}
	defer close(a.done)
	a.filter.colored = &outer.colored
	a.cols, a.rows, a.cellW, a.cellH = terminalSize(cfg.out)
	if err := a.open(); err != nil {
		return a.failed(err), nil
	}
	defer func() {
		a.mu.Lock()
		st := a.stream
		a.mu.Unlock()
		st.Close()
	}()
	return a.run(), nil
}

// outerTerm is the terminal kero attach runs in, which takes one write at a
// time, of sequences whole, so that it's in a state to take what restores
// it.
type outerTerm struct {
	w          io.Writer
	restoreTTY func()
	colored    atomic.Bool

	mu     sync.Mutex
	closed bool
	once   sync.Once
}

func (o *outerTerm) write(p []byte) { o.writeIf(p, nil) }

// writeIf writes p unless the terminal was restored or ok, asked in turn,
// says not to.
func (o *outerTerm) writeIf(p []byte, ok func() bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.closed && (ok == nil || ok()) {
		o.w.Write(p)
	}
}

// restore gives the terminal back. A terminal that takes nothing more, as a
// connection that stalled, doesn't hold kero up: its settings go back all
// the same.
func (o *outerTerm) restore() {
	o.once.Do(func() {
		done := make(chan struct{})
		go func() {
			defer close(done)
			o.mu.Lock()
			defer o.mu.Unlock()
			o.closed = true
			o.w.Write([]byte(attachLeave(o.colored.Load())))
		}()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
		o.restoreTTY()
	})
}

// What a stream's pump tells the attachment.
type attachEvent struct {
	gen  int
	over bool // the stream ended; else it takes a new start
	gone bool // the daemon closed the pane
}

// attacher is an attachment to a pane, over a stream that it replaces as it
// takes a new start, which the pane's first frame for a stream is.
type attacher struct {
	cfg    attachConfig
	outer  *outerTerm
	events chan attachEvent
	done   chan struct{}

	mu     sync.Mutex
	stream *client.Stream
	gen    int
	filter frameFilter
	// The outer terminal's size, its cells' in pixels, and the pane's.
	cols, rows, cellW, cellH int
	paneCols, paneRows       int
	// claimed tells that the pane is this terminal's to size, until another
	// client takes it, which a new stream then doesn't take back.
	claimed bool
	// noticed tells that the screen shows why the pane doesn't; timer is
	// on its way to.
	noticed bool
	timer   *time.Timer
}

// open attaches again, or at first: the new stream takes the pane before the
// one it replaces lets go of it, so that it doesn't change size between them.
func (a *attacher) open() error {
	st, err := client.AttachAs(a.cfg.dial, a.cfg.pane, a.cfg.client)
	if err != nil {
		return err
	}
	a.mu.Lock()
	old := a.stream
	a.stream = st
	a.gen++
	gen := a.gen
	a.filter.reset()
	a.paneCols, a.paneRows = st.Welcome.Cols, st.Welcome.Rows
	a.filter.rows = st.Welcome.Rows
	a.updateHold()
	if !a.filter.hold {
		a.noticed = false // this stream's first frame draws it all
	}
	cols, rows, cellW, cellH, claimed := a.cols, a.rows, a.cellW, a.cellH, a.claimed
	a.mu.Unlock()
	st.OnResized = func(c, r int) { a.paneResized(gen, c, r) }
	if cols > 0 && rows > 0 {
		st.ResizePixels(cols, rows, cellW, cellH)
	}
	if claimed {
		st.Claim()
	}
	if old != nil {
		old.Close()
	}
	go a.pump(st, gen)
	return nil
}

// updateHold keeps back what draws while the pane is of another size than
// the outer terminal, and reports that the screen needs a new start for it to
// show again; a.mu is held.
func (a *attacher) updateHold() (repaint bool) {
	was := a.filter.hold
	a.filter.hold = a.cols > 0 && a.rows > 0 && (a.paneCols != a.cols || a.paneRows != a.rows)
	switch {
	case a.filter.hold && !was:
		a.timer = time.AfterFunc(attachNoticeAfter, a.showNotice)
	case !a.filter.hold && was:
		if a.timer != nil {
			a.timer.Stop()
		}
		repaint, a.noticed = a.noticed, false
	}
	return repaint
}

// showNotice says why the pane doesn't show: another client took it.
func (a *attacher) showNotice() {
	a.mu.Lock()
	if !a.filter.hold || a.noticed {
		a.mu.Unlock()
		return
	}
	a.noticed = true
	msg := fmt.Sprintf("\x1b[0m\x1b[2J\x1b[HAnother client shows this pane at %dx%d; this terminal is %dx%d.\r\nPress a key to take it back, or %s to detach.",
		a.paneCols, a.paneRows, a.cols, a.rows, a.cfg.keyName)
	a.mu.Unlock()
	a.outer.write([]byte(msg))
}

// paneResized follows the size the pane took; it runs within the stream's
// Read, in order with the frames.
func (a *attacher) paneResized(gen, cols, rows int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if gen != a.gen {
		return
	}
	a.paneCols, a.paneRows, a.filter.rows = cols, rows, rows
	if cols != a.cols || rows != a.rows {
		a.claimed = false
	}
	if a.updateHold() {
		a.event(attachEvent{gen: gen})
	}
}

// terminalResized follows the outer terminal's size: the user is at it, as
// they resize it, so that it takes the pane.
func (a *attacher) terminalResized() {
	cols, rows, cellW, cellH := terminalSize(a.cfg.out)
	a.mu.Lock()
	if cols == a.cols && rows == a.rows {
		a.mu.Unlock()
		return
	}
	a.cols, a.rows, a.cellW, a.cellH = cols, rows, cellW, cellH
	a.claimed = true
	was := a.filter.hold
	a.updateHold()
	// Back at the pane's size with no resize of the pane to come: what was
	// kept back takes a new start.
	repaint := was && !a.filter.hold
	st, gen := a.stream, a.gen
	a.mu.Unlock()
	if cols > 0 && rows > 0 {
		st.ResizePixels(cols, rows, cellW, cellH)
		st.Claim()
	}
	if repaint {
		a.event(attachEvent{gen: gen})
	}
}

func (a *attacher) event(ev attachEvent) {
	go func() {
		select {
		case a.events <- ev:
		case <-a.done:
		}
	}()
}

// pump shows what a stream sends, until it ends.
func (a *attacher) pump(st *client.Stream, gen int) {
	buf := make([]byte, 64<<10)
	current := func() bool {
		a.mu.Lock()
		defer a.mu.Unlock()
		return gen == a.gen
	}
	for {
		n, err := st.Read(buf)
		if n > 0 {
			a.mu.Lock()
			if gen != a.gen {
				a.mu.Unlock()
				return
			}
			out, left := a.filter.feed(buf[:n])
			refused := a.filter.takeRefused()
			a.mu.Unlock()
			for _, r := range refused {
				st.Write([]byte(r))
			}
			if len(out) > 0 {
				a.outer.writeIf(out, current)
			}
			if left {
				a.event(attachEvent{gen: gen})
			}
		}
		if err != nil {
			gone := false
			select {
			case <-st.Gone:
				gone = true
			default:
			}
			a.event(attachEvent{gen: gen, over: true, gone: gone})
			return
		}
	}
}

// input takes what the user typed: a key to the pane, but for the first key
// on the notice, which takes the pane back and goes no further.
func (a *attacher) input(b []byte) {
	user := string(b) != "\x1b[I" && string(b) != "\x1b[O" // focus reports aren't the user's
	a.mu.Lock()
	st, noticed := a.stream, a.noticed
	cols, rows, cellW, cellH := a.cols, a.rows, a.cellW, a.cellH
	if user {
		a.claimed = true
	}
	a.mu.Unlock()
	if noticed && user {
		// As well as the claim, for a kerod that takes no claims.
		st.ResizePixels(cols, rows, cellW, cellH)
		st.Claim()
		return
	}
	st.Write(b)
}

// read passes what is typed on, until the detach key or the terminal's end.
func (a *attacher) read(detached, hangup chan<- struct{}) {
	key := a.cfg.key
	buf := make([]byte, 32<<10)
	for {
		n, err := a.cfg.in.Read(buf)
		if n > 0 {
			forward, detach := key.feed(buf[:n])
			if len(forward) > 0 {
				a.input(forward)
			}
			if detach {
				close(detached)
				return
			}
		}
		if err != nil {
			close(hangup)
			return
		}
	}
}

// run serves the attachment until something ends it.
func (a *attacher) run() attachEnd {
	detached, hangup := make(chan struct{}), make(chan struct{})
	go a.read(detached, hangup)
	for {
		select {
		case <-detached:
			return attachEnd{kind: endDetached}
		case <-hangup:
			return attachEnd{kind: endHangup}
		case sig := <-a.cfg.signals:
			return attachEnd{kind: endSignal, code: signalNumber(sig)}
		case <-a.cfg.resized:
			a.terminalResized()
		case code := <-a.cfg.exited:
			return attachEnd{kind: endExited, code: code}
		case <-a.cfg.lost:
			return attachEnd{kind: endLost}
		case ev := <-a.events:
			a.mu.Lock()
			current := ev.gen == a.gen
			a.mu.Unlock()
			if !current {
				continue
			}
			if ev.over {
				// kerod going takes the control connection with it, at about
				// the same moment; a stream alone ended by the pane's end, or
				// as kerod dropped a client too far behind, which is to attach
				// again.
				select {
				case <-a.cfg.lost:
					return attachEnd{kind: endLost}
				case <-time.After(300 * time.Millisecond):
				}
				if ev.gone {
					return attachEnd{kind: endClosed}
				}
			}
			if err := a.open(); err != nil {
				return a.failed(err)
			}
		}
	}
}

// failed tells how attaching failing ends it.
func (a *attacher) failed(err error) attachEnd {
	if s := err.Error(); strings.HasPrefix(s, "no session") || s == "session closed" {
		return attachEnd{kind: endClosed}
	}
	return attachEnd{kind: endLost}
}
