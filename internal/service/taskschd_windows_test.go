package service

import (
	"encoding/xml"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"kero/internal/clilink"
	"kero/internal/proto"
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

// The task's file tells the executable it runs, a path of spaces and
// ampersands too.
func TestTaskExe(t *testing.T) {
	exe := `C:\Users\A & B\AppData\Roaming\kero\bin\kero.exe`
	if got := taskExe(utf16File(definition(exe, `PC\A & B`))); got != exe {
		t.Errorf("taskExe = %q, want %q", got, exe)
	}
	if got := taskExe([]byte("not a task")); got != "" {
		t.Errorf("taskExe of no task = %q", got)
	}
}

// A task that runs the kero command, a copy of the app's executable,
// starts the app's code of now: Start copies it again once the app
// updated.
func TestRefreshCopiesUpdatedApp(t *testing.T) {
	src, err := exec.LookPath("notepad.exe")
	if err != nil {
		t.Skip("no notepad")
	}
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_HOME", t.TempDir())
	app := filepath.Join(t.TempDir(), "Kero.exe")
	if err := os.WriteFile(app, b, 0o755); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(proto.Dir(), "bin")
	if err := clilink.Link(app, bin); err != nil {
		t.Fatal(err)
	}
	cmd := filepath.Join(bin, "kero.exe")
	if err := os.WriteFile(file(), utf16File(definition(cmd, `PC\A`)), 0o600); err != nil {
		t.Fatal(err)
	}
	// The update: the app of another size and time.
	if err := os.WriteFile(app, append(b, 0), 0o755); err != nil {
		t.Fatal(err)
	}
	refresh()
	got, err := os.Stat(cmd)
	if err != nil {
		t.Fatal(err)
	}
	if got.Size() != int64(len(b)+1) {
		t.Errorf("the command is %d bytes, not the updated app's %d", got.Size(), len(b)+1)
	}
}
