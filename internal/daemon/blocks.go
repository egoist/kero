package daemon

import (
	"strconv"
	"time"

	"kero/internal/proto"
)

// maxBlocks is how many commands a pane remembers, newest first to stay.
// Blocks go sooner, with their line, as the scrollback lets it go.
const maxBlocks = 500

// maxBlockReading is how far reading the text may go ahead of its share of
// the time, a fifth, before marks wait: as far as a few commands in a row, as
// lines pasted at a prompt, with a long scrollback.
const maxBlockReading = 100 * time.Millisecond

// What a pane's shell is doing, by its marks (OSC 133).
const (
	blockIdle    = iota // no prompt since the last command
	blockPrompt         // at a prompt
	blockRunning        // running a command
)

// blockTrack follows a pane's commands by the prompt marks its shell sends;
// the pane's mu guards it.
type blockTrack struct {
	phase int
	list  []proto.Block
	seq   uint64
	rev   uint64
	// promptRow is the row the prompt starts on, -1 when not known.
	promptRow int
	// started is when the command started; name the program it ran, and
	// quiet that what it ran told its own status.
	started time.Time
	name    string
	quiet   bool
	// reading is how long reading the text for marks took of late, and read
	// when it was last read: reading it takes as long as the scrollback is,
	// and a program may send marks in a loop.
	reading time.Duration
	read    time.Time
}

// parseMark parses an OSC 133 after its "133;": the mark's letter, and the
// exit status D tells, nil for none or for one that makes no sense. A mark
// is its letter, alone or with options after a ";": anything else is no mark.
func parseMark(body string) (kind byte, exit *int, ok bool) {
	if body == "" || len(body) > 1 && body[1] != ';' {
		return 0, nil, false
	}
	switch kind = body[0]; kind {
	case 'A', 'B', 'C':
		return kind, nil, true
	case 'D':
		if len(body) > 2 {
			code := body[2:]
			for i := range len(code) {
				if code[i] == ';' {
					code = code[:i]
					break
				}
			}
			if n, err := strconv.Atoi(code); err == nil && n >= 0 && n <= 0xFFFF {
				exit = &n
			}
		}
		return kind, exit, true
	}
	return 0, nil, false
}

// blockMark takes a prompt mark. The emulator has shown everything before
// it; s.mu is held.
//
// A mark counts only as the shell's: a shell starts a block at a prompt it
// marked, and nothing else's marks do, which a program in the foreground
// passes on from a shell it runs, or sends in its own output. C alone can't
// be told by the foreground: the shell has handed it the terminal by the time
// the mark is read. Being at the prompt says enough for it.
func (s *pane) blockMark(kind byte, exit *int) {
	b := &s.blocks
	foreign := false
	if s.proc != nil {
		pg := s.proc.Foreground()
		foreign = pg != 0 && pg != s.shellPID
	}
	switch kind {
	case 'A':
		if foreign {
			return
		}
		if b.phase == blockRunning {
			// A prompt with no D: it ended, with no status told.
			s.endBlock(nil)
		}
		b.phase = blockPrompt
		b.promptRow = -1
		if row, alt := s.term.CursorRow(); !alt {
			b.promptRow = row
		}
	case 'C':
		if b.phase == blockPrompt {
			s.startBlock()
		}
	case 'D':
		if b.phase == blockRunning && !foreign {
			s.endBlock(exit)
			b.phase = blockIdle
		}
	}
}

// readBlockText reads the terminal's text for a mark, false when it is not to be
// read for now: a screen of a full-screen program holds none of the blocks'
// lines, and marks that come too fast wait.
func (s *pane) readBlockText() (string, bool) {
	b := &s.blocks
	now := time.Now()
	b.reading = max(b.reading-now.Sub(b.read)/4, 0)
	b.read = now
	if b.reading > maxBlockReading {
		return "", false
	}
	if _, alt := s.term.CursorRow(); alt {
		return "", false
	}
	text := s.term.Text()
	b.reading += time.Since(now)
	return text, true
}

// startBlock starts a block for the command the shell just marked; s.mu is
// held.
func (s *pane) startBlock() {
	b := &s.blocks
	b.phase = blockIdle
	text, ok := s.readBlockText()
	if !ok {
		return
	}
	_, line := proto.LastLine(text)
	if line == "" {
		return
	}
	up := 0
	if row, _ := s.term.CursorRow(); b.promptRow >= 0 {
		up = max(row-b.promptRow-proto.WrappedRows(line, s.info.Cols), 0)
	}
	now := time.Now()
	b.phase, b.started, b.name, b.quiet = blockRunning, now, "", false
	b.seq++
	b.list = append(b.list, proto.Block{Seq: b.seq, Line: proto.ClipLine(line), Up: up, Output: -1, Started: now.UnixMilli(), Ms: -1})
	s.pruneBlocks(text)
	s.blocksChanged(nil)
}

// endBlock ends the block that runs, with the exit status the shell told;
// s.mu is held.
func (s *pane) endBlock(exit *int) {
	b := &s.blocks
	ms := time.Since(b.started).Milliseconds()
	cur := &proto.Block{}
	for i := range b.list {
		if b.list[i].Seq == b.seq {
			cur = &b.list[i]
		}
	}
	cur.Ms, cur.Exit = ms, exit
	if text, ok := s.readBlockText(); ok {
		found := s.pruneBlocks(text)
		// Its own line, wherever the scrollback's limit left it.
		if n := len(found); n > 0 && found[n-1] >= 0 && b.list[n-1].Seq == b.seq {
			last, _ := proto.LastLine(text)
			b.list[n-1].Output = max(last-found[n-1], 0)
		}
	}
	end := &proto.Commands{Last: b.seq, Ms: ms, Name: b.name, Quiet: b.quiet || len(s.records) > 0 || s.info.Agent != ""}
	if exit != nil {
		end.Exit, end.ExitKnown = *exit, true
	}
	s.blocksChanged(end)
}

// pruneBlocks forgets the blocks whose lines the text no longer shows, and
// the oldest past the limit, and returns the lines of those left; s.mu is
// held.
func (s *pane) pruneBlocks(text string) []int {
	b := &s.blocks
	lines := make([]string, len(b.list))
	for i, bl := range b.list {
		lines[i] = bl.Line
	}
	found := proto.MatchBlocks(text, lines)
	kept, at := b.list[:0], found[:0]
	for i, bl := range b.list {
		if found[i] >= 0 {
			kept, at = append(kept, bl), append(at, found[i])
		}
	}
	if n := len(kept) - maxBlocks; n > 0 {
		kept, at = kept[n:], at[n:]
	}
	b.list = append(b.list[:0], kept...)
	return at
}

// blocksChanged tells the clients the blocks changed, and, with end, that a
// command ended; s.mu is held.
func (s *pane) blocksChanged(end *proto.Commands) {
	b := &s.blocks
	b.rev++
	c := proto.Commands{Rev: b.rev}
	switch {
	case end != nil:
		c = *end
		c.Rev = b.rev
	case s.info.Commands != nil:
		c = *s.info.Commands
		c.Rev = b.rev
	}
	s.info.Commands = &c
	s.d.changed()
}

// resetBlocks forgets the blocks, as the screen they were on goes; s.mu is
// held.
func (s *pane) resetBlocks() {
	b := &s.blocks
	if b.phase == blockIdle && len(b.list) == 0 {
		return
	}
	b.phase, b.list = blockIdle, nil
	s.blocksChanged(nil)
}

// noteBlock follows what the command that runs runs; s.mu is held.
func (s *pane) noteBlock(proc, agent string) {
	b := &s.blocks
	if b.phase != blockRunning {
		return
	}
	if proc != "" {
		b.name = proc
	}
	if agent != "" || len(s.records) > 0 {
		b.quiet = true
	}
}

// blocksFrom returns the pane's blocks from since on.
func (s *pane) blocksFrom(since uint64) proto.BlocksResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := proto.BlocksResult{Blocks: []proto.Block{}, First: s.blocks.seq + 1}
	for i, bl := range s.blocks.list {
		if i == 0 {
			r.First = bl.Seq
		}
		if bl.Seq >= since {
			r.Blocks = append(r.Blocks, bl)
		}
	}
	return r
}
