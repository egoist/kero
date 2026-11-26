package main

import (
	"testing"

	"kero/internal/proto"
)

func TestProgramIconPi(t *testing.T) {
	if programIcons["pi"] == nil {
		t.Fatal("pi icon is not registered")
	}
	got := programIcon(&proto.Pane{Agent: "pi", Process: "pi", Runtime: "node"})
	if got != programIcons["pi"] {
		t.Fatalf("got %p, want pi icon %p (node=%p)", got, programIcons["pi"], programIcons["node"])
	}
}
