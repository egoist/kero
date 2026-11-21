package cli

import (
	"errors"
	"testing"

	"kero/internal/proto"
)

// A conversation that names several is a target that is not found, as the
// help says: "3 no such target (or an ambiguous one)". Every other
// ambiguous target of the CLI says so too.
func TestAmbiguousConversation(t *testing.T) {
	list := []proto.Conversation{
		{Agent: "claude", ID: "ab12345"},
		{Agent: "claude", ID: "ab67890"},
	}
	if _, err := findConversation(list, "ab"); !errors.Is(err, errNotFound) {
		t.Errorf("a conversation that names several: %v, want errNotFound", err)
	}
	if _, err := findConversation(list, "ab12345"); err != nil {
		t.Errorf("the whole id: %v", err)
	}
	if _, err := findConversation(list, "zz"); !errors.Is(err, errNotFound) {
		t.Errorf("no such conversation: %v, want errNotFound", err)
	}
}
