package detach

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// TestMain is also the program WMI starts: it writes what it was given.
func TestMain(m *testing.M) {
	if out := os.Getenv("KERO_WMI_OUT"); out != "" {
		wd, _ := os.Getwd()
		os.WriteFile(out, []byte(os.Getenv("KERO_PROBE")+"|"+wd+"|"+os.Args[1]), 0o600)
		return
	}
	os.Exit(m.Run())
}

// WMI starts a program with the environment, directory and arguments it
// is given, of any characters.
func TestWMIStart(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "dé中 it’s")
	os.MkdirAll(dir, 0o755)
	out := filepath.Join(dir, "out.txt")
	const probe = "it’s \"here\"\nand ‘there’ $(calc)"
	cmd := exec.Command(exe, "an arg’s")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "KERO_PROBE="+probe, "KERO_WMI_OUT="+out)
	if _, err := wmiStart(cmd); err != nil {
		t.Fatal(err)
	}
	for range 200 {
		if b, err := os.ReadFile(out); err == nil && len(b) > 0 {
			if want := probe + "|" + dir + "|an arg’s"; string(b) != want {
				t.Errorf("got %q, want %q", b, want)
			}
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("it did not run")
}
