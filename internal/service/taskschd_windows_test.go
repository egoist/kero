package service

import (
	"encoding/xml"
	"io"
	"strings"
	"testing"
)

// The task is XML Task Scheduler reads, that runs kerod without a window,
// a path of spaces and ampersands too.
func TestDefinition(t *testing.T) {
	var task struct {
		Principal struct {
			UserID    string `xml:"UserId"`
			LogonType string
		} `xml:"Principals>Principal"`
		Exec struct {
			Command   string
			Arguments string
		} `xml:"Actions>Exec"`
	}
	d := xml.NewDecoder(strings.NewReader(definition(`C:\Users\A & B\kero.exe`, `PC\A & B`)))
	d.CharsetReader = func(_ string, r io.Reader) (io.Reader, error) { return r, nil }
	if err := d.Decode(&task); err != nil {
		t.Fatal(err)
	}
	if task.Principal.UserID != `PC\A & B` || task.Principal.LogonType != "InteractiveToken" {
		t.Errorf("principal %+v", task.Principal)
	}
	if !strings.HasSuffix(task.Exec.Command, `\conhost.exe`) || task.Exec.Arguments != `--headless "C:\Users\A & B\kero.exe" daemon serve` {
		t.Errorf("runs %+v", task.Exec)
	}
	if b := utf16File("<a/>"); b[0] != 0xff || b[1] != 0xfe || b[2] != '<' || b[3] != 0 {
		t.Errorf("not UTF-16 with its mark: % x", b[:4])
	}
}
