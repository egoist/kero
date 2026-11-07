package shell

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestInventory(t *testing.T) {
	dir := t.TempDir()
	exe := "test-shell"
	if runtime.GOOS == "windows" {
		exe += ".exe"
	}
	path := filepath.Join(dir, exe)
	if err := os.WriteFile(path, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	detected := []Entry{{"Friendly shell", path}, {"Other", filepath.Join(dir, "other")}}
	got := Inventory(detected, exe)
	if len(got) != 2 || got[0].Name != "Friendly shell" || got[0].Path != exe {
		t.Fatalf("bare command lost its friendly label or PATH resolution: %+v", got)
	}
	second := filepath.Join(t.TempDir(), exe)
	got = Inventory(detected, second)
	if len(got) != 3 || got[0].Path != second {
		t.Fatalf("distinct installation was collapsed: %+v", got)
	}
	if detected[0].Path != path {
		t.Fatal("inventory mutated detection")
	}
	if got := Inventory(nil, ""); len(got) != 1 || got[0].Path != Login() {
		t.Fatalf("missing platform default: %+v", got)
	}
}

func TestDetectedShellsExist(t *testing.T) {
	seen := map[string]bool{}
	for _, e := range Detect() {
		st, err := os.Stat(e.Path)
		if err != nil || st.IsDir() || seen[e.Name] {
			t.Errorf("invalid or duplicate shell: %+v (%v)", e, err)
		}
		seen[e.Name] = true
	}
}
