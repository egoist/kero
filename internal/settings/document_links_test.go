package settings

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDocumentLinksAreOptInAndPersist(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KERO_HOME", dir)
	t.Setenv("KERO_CONFIG", filepath.Join(dir, "config"))
	if Load().OpenDocumentLinks {
		t.Fatal("document links must keep opening externally by default")
	}
	if err := os.WriteFile(Path(), []byte("open-document-links = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := Load()
	if probs := Problems(); len(probs) != 0 {
		t.Fatalf("opt-in setting rejected: %v", probs)
	}
	if !s.OpenDocumentLinks {
		t.Fatal("document links did not opt in")
	}
	s.FontSize = 17
	if err := Save(s); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(Path())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "open-document-links = true") || !Load().OpenDocumentLinks {
		t.Fatalf("opt-in was not saved: %s", b)
	}
}
