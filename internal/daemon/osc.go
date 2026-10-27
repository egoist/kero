package daemon

import (
	"bytes"
	"encoding/base64"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"kero/internal/proto"
)

// oscScanner finds, in a program's output, the OSC sequences the daemon
// handles itself, which the emulator ignores: OSC 7501 (program status),
// OSC 133 (shell prompts) and OSC 9;4 (progress), and full resets (RIS).
// It follows them across reads.
type oscScanner struct {
	state int // 0 text, 1 after ESC, 2 in an OSC we keep, 3 in one we skip, 4 ESC in an OSC
	skip  bool
	buf   []byte
}

const maxOSC = 4096 // OSC 7501's limit on a whole sequence

// scan calls fn with the body of each OSC 7501, 133 and 9;4 in p (what is
// between "ESC ]" and the terminator), and reset at each RIS (ESC c).
func (o *oscScanner) scan(p []byte, fn func(body []byte), reset func()) {
	for _, b := range p {
		switch o.state {
		case 0:
			if b == 0x1b {
				o.state = 1
			} else if b == 0x9d { // C1 OSC, in 8-bit output
				o.begin()
			}
		case 1:
			if b == ']' {
				o.begin()
			} else if b != 0x1b {
				o.state = 0
				if b == 'c' {
					reset()
				}
			}
		case 2, 3:
			switch b {
			case 0x07, 0x9c:
				o.end(fn)
			case 0x1b:
				o.state = 4
			default:
				if o.state == 2 {
					o.buf = append(o.buf, b)
					if !o.wanted() || len(o.buf) > maxOSC {
						o.state, o.buf = 3, o.buf[:0]
					}
				}
			}
		case 4:
			if b == '\\' {
				o.end(fn)
			} else {
				// An ESC ends the string whatever follows (a new sequence).
				o.state, o.buf = 1, o.buf[:0]
				if b == ']' {
					o.begin()
				} else if b != 0x1b {
					o.state = 0
				}
			}
		}
	}
}

func (o *oscScanner) begin() { o.state, o.buf = 2, o.buf[:0] }

func (o *oscScanner) end(fn func([]byte)) {
	if o.state == 2 || o.state == 4 && len(o.buf) > 0 {
		if o.wanted() && len(o.buf) > 0 {
			fn(o.buf)
		}
	}
	o.state, o.buf = 0, o.buf[:0]
}

// wanted reports whether what was collected may still be an OSC kept.
func (o *oscScanner) wanted() bool {
	for _, pre := range [][]byte{[]byte("7501;"), []byte("133;"), []byte("9;4;")} {
		n := min(len(o.buf), len(pre))
		if bytes.Equal(o.buf[:n], pre[:n]) {
			return true
		}
	}
	return false
}

// OSC 7501's grammar and limits.
var (
	keyRe     = regexp.MustCompile(`^[a-z]{1,16}$`)
	valueRe   = regexp.MustCompile(`^[A-Za-z0-9_.,+/=-]*$`)
	segmentRe = regexp.MustCompile(`^[A-Za-z0-9_.+-]{1,32}$`)
	appRe     = regexp.MustCompile(`^[A-Za-z0-9_.+-]{1,32}$`)
)

const maxRecords = 64

// statusReport is a parsed OSC 7501 report.
type statusReport struct {
	query bool
	rec   proto.Record
}

// parseStatus parses the body of an OSC 7501 after "7501;", as the
// protocol says: a report that breaks a rule is discarded whole, a
// malformed pair skipped.
func parseStatus(body string) (statusReport, bool) {
	body = strings.TrimSpace(body)
	if body == "?" || strings.HasPrefix(body, "?:") {
		return statusReport{query: true}, true
	}
	pairs := map[string]string{}
	for _, pair := range strings.Split(body, ":") {
		k, v, ok := strings.Cut(pair, "=")
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if !ok || !keyRe.MatchString(k) || !valueRe.MatchString(v) {
			continue
		}
		pairs[k] = v // the last one wins
	}
	r := proto.Record{State: pairs["state"], Progress: -1}
	switch r.State {
	case "idle", "working", "done", "blocked", "error", "clear":
	default:
		return statusReport{}, false
	}
	if id, ok := pairs["id"]; ok {
		segs := strings.Split(id, "/")
		if len(id) > 128 || len(segs) > 8 {
			return statusReport{}, false
		}
		for _, s := range segs {
			if !segmentRe.MatchString(s) {
				return statusReport{}, false
			}
		}
		r.ID = id
	}
	if r.State == "blocked" {
		switch k := pairs["kind"]; k {
		case "permission", "question", "auth":
			r.Kind = k
		}
	}
	if p, err := strconv.Atoi(pairs["progress"]); err == nil && p >= 0 && p <= 100 && (r.State == "working" || r.State == "blocked") {
		r.Progress = p
	}
	if app := pairs["app"]; appRe.MatchString(app) {
		r.App = app
	}
	text := func(key string, encoded, decoded int) (string, bool) {
		v, ok := pairs[key]
		if !ok {
			return "", true
		}
		if len(v) > encoded {
			return "", false
		}
		b, err := base64.StdEncoding.DecodeString(v)
		if err != nil {
			b, err = base64.RawStdEncoding.DecodeString(v)
		}
		if err != nil || len(b) > decoded || !utf8.Valid(b) {
			return "", false
		}
		s := string(b)
		for _, c := range s {
			if c < 0x20 || c >= 0x7f && c <= 0x9f {
				return "", false
			}
		}
		return neutralize(s), true
	}
	var ok bool
	if r.Msg, ok = text("msg", 2732, 2048); !ok {
		return statusReport{}, false
	}
	if r.Title, ok = text("title", 256, 192); !ok {
		return statusReport{}, false
	}
	r.Updated = time.Now().UnixMilli()
	return statusReport{rec: r}, true
}

// neutralize drops the bidi overrides and invisible formatting that
// would make text shown outside the grid lie about itself.
func neutralize(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 0x202A && r <= 0x202E, r >= 0x2066 && r <= 0x2069, r == 0x200E, r == 0x200F, r == 0x061C,
			r >= 0x200B && r <= 0x200D, r == 0xFEFF:
			return -1
		}
		return r
	}, s)
}

// statusQueryReply answers a program's OSC 7501 query: the defaults, so
// no list.
const statusQueryReply = "\x1b]7501;?\x1b\\"

// handleOSC acts on an OSC the scanner found; s.mu is held.
func (s *pane) handleOSC(body []byte) {
	switch {
	case bytes.HasPrefix(body, []byte("7501;")):
		rep, ok := parseStatus(string(body[5:]))
		if !ok {
			return
		}
		if rep.query {
			if s.proc != nil {
				s.proc.Write([]byte(statusQueryReply))
			}
			return
		}
		s.applyReport(rep.rec)
	case bytes.HasPrefix(body, []byte("9;4;")):
		// ConEmu's progress (OSC 9;4), which only agents' rules read: a
		// program's progress bar, as Neovim's for its language servers,
		// tells no work the user waits on.
		s.progress = string(body[2:])
	case bytes.HasPrefix(body, []byte("133;A")):
		// A new prompt: what ran is over.
		s.dropLive()
	case bytes.HasPrefix(body, []byte("133;D")):
		// A command ended, with its exit status: the first to, of a pane
		// started with one, is that command (shellArgs).
		if !s.awaiting {
			return
		}
		s.awaiting = false
		code, _, _ := strings.Cut(strings.TrimPrefix(string(body[5:]), ";"), ";")
		n, _ := strconv.Atoi(code)
		s.info.CommandExit = &n
		s.wake()
		s.d.changed()
	}
}

// fullReset forgets every record and the progress, as a full reset (RIS)
// does; s.mu is held.
func (s *pane) fullReset() {
	if len(s.records) > 0 {
		clear(s.records)
		s.fromRecords()
	}
	s.reported = false
	s.progress = ""
}

func (s *pane) applyReport(r proto.Record) {
	if s.records == nil {
		s.records = map[string]proto.Record{}
	}
	if r.State == "clear" {
		if r.ID == "" {
			clear(s.records)
		} else {
			for id := range s.records {
				if id == r.ID || strings.HasPrefix(id, r.ID+"/") {
					delete(s.records, id)
				}
			}
		}
	} else {
		if _, ok := s.records[r.ID]; !ok && len(s.records) >= maxRecords {
			// Full: the one updated longest ago goes.
			oldest := ""
			for id, o := range s.records {
				if oldest == "" || o.Updated < s.records[oldest].Updated {
					oldest = id
				}
			}
			delete(s.records, oldest)
		}
		s.records[r.ID] = r
	}
	s.reported = true
	s.fromRecords()
}

// dropLive drops the records that end with their program: working and
// blocked ones, as its process exits or a prompt starts; s.mu is held.
func (s *pane) dropLive() {
	changed := false
	for id, r := range s.records {
		if r.State == "working" || r.State == "blocked" || r.State == "idle" {
			delete(s.records, id)
			changed = true
		}
	}
	if changed {
		s.fromRecords()
	}
}

// dismissFinished drops done and error records once the user acted;
// s.mu is held.
func (s *pane) dismissFinished() {
	changed := false
	for id, r := range s.records {
		if r.State == "done" || r.State == "error" {
			delete(s.records, id)
			changed = true
		}
	}
	if changed {
		s.fromRecords()
	}
}

// fromRecords sets the session's status from its records, which come
// before what the daemon would guess: blocked over working over error over
// done; s.mu is held.
func (s *pane) fromRecords() {
	recs := make([]proto.Record, 0, len(s.records))
	for _, r := range s.records {
		recs = append(recs, r)
	}
	slices.SortFunc(recs, func(a, b proto.Record) int { return strings.Compare(a.ID, b.ID) })
	// Records without app take their nearest ancestor's.
	apps := map[string]string{}
	for _, r := range recs {
		apps[r.ID] = r.App
	}
	for i := range recs {
		for id := recs[i].ID; recs[i].App == "" && id != ""; {
			j := strings.LastIndexByte(id, '/')
			if j < 0 {
				id = ""
			} else {
				id = id[:j]
			}
			recs[i].App = apps[id]
		}
	}
	s.info.Records = recs
	if len(recs) == 0 {
		s.info.Kind, s.info.Progress = "", -1
		if s.info.Status == proto.Failed || s.reportedStatus() {
			s.setStatus(proto.Idle)
			s.info.Message = ""
		}
		s.d.changed()
		return
	}
	pick := func(state string) *proto.Record {
		for i := range recs {
			if recs[i].State == state {
				return &recs[i]
			}
		}
		return nil
	}
	viewed := s.viewed()
	switch {
	case pick("blocked") != nil:
		r := pick("blocked")
		s.setStatus(proto.Waiting)
		s.info.Message, s.info.Kind, s.info.Progress = r.Msg, r.Kind, r.Progress
		if !viewed {
			s.info.Unread = true
		}
	case pick("working") != nil:
		r := pick("working")
		s.setStatus(proto.Working)
		s.info.Message, s.info.Kind, s.info.Progress = r.Msg, "", r.Progress
	case pick("error") != nil:
		r := pick("error")
		s.setStatus(proto.Failed)
		s.info.Message, s.info.Kind, s.info.Progress = r.Msg, "", -1
		if !viewed {
			s.info.Unread = true
		}
	case pick("done") != nil:
		r := pick("done")
		if s.info.Status != proto.Idle || s.info.Message != r.Msg {
			s.setStatus(proto.Idle)
			if !viewed {
				s.info.Unread = true
			}
		}
		s.info.Message, s.info.Kind, s.info.Progress = r.Msg, "", -1
	default: // idle
		s.setStatus(proto.Idle)
		s.info.Message, s.info.Kind, s.info.Progress = "", "", -1
	}
	s.d.changed()
}

// reportedStatus reports whether the status came from records; s.mu is
// held.
func (s *pane) reportedStatus() bool {
	return s.reported && (s.info.Status == proto.Working || s.info.Status == proto.Waiting)
}

// declared reports whether a program declared it works or waits, which
// the daemon's guesses then leave alone; s.mu is held.
func (s *pane) declared() bool {
	for _, r := range s.records {
		if r.State == "working" || r.State == "blocked" {
			return true
		}
	}
	return false
}
