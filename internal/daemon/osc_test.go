package daemon

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"kero/internal/proto"
)

func TestScannerAcrossReads(t *testing.T) {
	msg := base64.StdEncoding.EncodeToString([]byte("Installing updates"))
	stream := "hello \x1b]0;title\x07 \x1b]7501;state=working:app=brew:msg=" + msg + "\x1b\\ world \x1b]133;A\x07 \x1b]9;4;1;40\x07 \x1bc"
	var got []string
	var o oscScanner
	// Byte at a time: sequences split anywhere still come whole.
	for i := range len(stream) {
		o.scan([]byte{stream[i]}, func(b []byte) { got = append(got, string(b)) }, func() { got = append(got, "RIS") })
	}
	want := []string{"7501;state=working:app=brew:msg=" + msg, "133;A", "9;4;1;40", "RIS"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestParseStatus(t *testing.T) {
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	r, ok := parseStatus("state=blocked:kind=permission:app=terraform:msg=" + b64("Apply 3 to add?") + ":progress=10")
	if !ok || r.rec.State != "blocked" || r.rec.Kind != "permission" || r.rec.App != "terraform" || r.rec.Msg != "Apply 3 to add?" || r.rec.Progress != 10 {
		t.Fatalf("blocked report: %+v %v", r.rec, ok)
	}
	if r, ok := parseStatus("?"); !ok || !r.query {
		t.Fatal("query not recognized")
	}
	for _, bad := range []string{
		"kind=question",                                 // no state
		"state=sleeping",                                // unknown state
		"state=done:msg=" + b64("a\nb"),                 // a control character
		"state=done:msg=!!!",                            // malformed pair, then no msg: fine…
		"state=working:id=a/" + strings.Repeat("x", 40), // segment too long
	} {
		_, ok := parseStatus(bad)
		if bad == "state=done:msg=!!!" {
			if !ok {
				t.Errorf("%q: a malformed pair is skipped, the report kept", bad)
			}
			continue
		}
		if ok {
			t.Errorf("%q accepted", bad)
		}
	}
	// Progress only means something while working or blocked.
	if r, _ := parseStatus("state=done:progress=50"); r.rec.Progress != -1 {
		t.Errorf("progress on done: %d", r.rec.Progress)
	}
	// Bidi overrides are dropped from messages shown outside the grid.
	if r, _ := parseStatus("state=done:msg=" + b64("ok‮gnp.exe")); r.rec.Msg != "okgnp.exe" {
		t.Errorf("bidi not neutralized: %q", r.rec.Msg)
	}
}

// Vibe 3.0.1 reports its state natively, without screen detection rules.
func TestVibeStatusReports(t *testing.T) {
	for _, c := range []struct {
		state, kind, msg string
		status           proto.Status
		unread           bool
	}{
		{"idle", "", "", proto.Idle, false},
		{"working", "", "Fix login", proto.Working, false},
		{"blocked", "permission", "Run the tests?", proto.Waiting, true},
		{"blocked", "question", "Which project?", proto.Waiting, true},
		{"done", "", "Fix login", proto.Idle, true},
		{"error", "", "Request failed", proto.Failed, true},
	} {
		t.Run(c.state+"/"+c.kind, func(t *testing.T) {
			s := testPane(t)
			s.info.Agent = "vibe"
			s.output([]byte("\x1b]0;Vibe\x1b\\\x1b]7501;state=working:app=vibe\x1b\\"))
			s.status(time.Now())

			report := "\x1b]7501;state=" + c.state
			if c.kind != "" {
				report += ":kind=" + c.kind
			}
			report += ":app=vibe"
			if c.msg != "" {
				report += ":msg=" + base64.StdEncoding.EncodeToString([]byte(c.msg))
			}
			report += "\x1b\\"
			for i := range len(report) {
				s.output([]byte{report[i]})
			}
			s.show("> ")
			s.resize(80, 24, 0, 0)
			if got := s.status(time.Now()); got != c.status {
				t.Fatalf("status after redraw: %s, want %s", got, c.status)
			}
			if s.info.Message != c.msg || s.info.Kind != c.kind || s.info.Unread != c.unread {
				t.Errorf("pane: message %q, kind %q, unread %v", s.info.Message, s.info.Kind, s.info.Unread)
			}
			if len(s.info.Records) != 1 {
				t.Fatalf("records: %+v", s.info.Records)
			}
			r := s.info.Records[0]
			if r.App != "vibe" || r.State != c.state || r.Kind != c.kind || r.Msg != c.msg {
				t.Errorf("record: %+v", r)
			}

			s.input(nil)
			if s.info.Unread {
				t.Error("acknowledging the report left it unread")
			}
			if c.state == "done" || c.state == "error" {
				if len(s.info.Records) != 0 || s.info.Status != proto.Idle {
					t.Errorf("finished report not dismissed: %+v", s.info)
				}
			} else if s.info.Status != c.status {
				t.Errorf("input changed a live report's status: %s", s.info.Status)
			}
		})
	}
}

// The first command to end, in a pane started with one, is that command.
func TestCommandExit(t *testing.T) {
	s := testPane(t)
	s.output([]byte("\x1b]133;D;0\x07"))
	if s.info.CommandExit != nil {
		t.Fatal("a pane started with no command took an exit status")
	}
	s.awaiting = true
	s.output([]byte("out\r\n\x1b]133;D;3\x07\x1b]133;D;0\x1b\\"))
	if s.info.CommandExit == nil || *s.info.CommandExit != 3 {
		t.Fatalf("CommandExit = %v, want 3", s.info.CommandExit)
	}
}

// A full reset forgets the programs' reports.
func TestFullResetClearsRecords(t *testing.T) {
	s := testPane(t)
	s.output([]byte("\x1b]7501;state=working:id=build\x1b\\"))
	if s.info.Status != proto.Working {
		t.Fatalf("status %s, want working", s.info.Status)
	}
	s.output([]byte("\x1bc"))
	if len(s.info.Records) != 0 || s.info.Status != proto.Idle || s.reported {
		t.Fatalf("after RIS: records %v, status %s, reported %v", s.info.Records, s.info.Status, s.reported)
	}
}
