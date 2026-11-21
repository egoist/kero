package main

import (
	"errors"
	"testing"

	"kero/internal/proto"
)

// A host whose conversations call failed keeps the list it had, and is
// asked again: only an older kerod, which knows of none, is left alone.
func TestConversationsAskedAgain(t *testing.T) {
	a := testApp(t)
	h := a.local()
	h.convs = []proto.Conversation{{Agent: "claude", ID: "c1"}}
	h.convGen = 3
	// A link that broke: the list stays as it was.
	a.conversationsAnswered(h, nil, 3, errors.New("kerod went away"))
	if len(h.convs) != 1 || h.convKnown {
		t.Fatalf("the list %+v, known %v", h.convs, h.convKnown)
	}
	// An older kerod knows of none: ask it no more.
	a.conversationsAnswered(h, nil, 3, errors.New(`unknown method "conversations"`))
	if !h.convKnown {
		t.Fatal("asked an older kerod again")
	}
	// A list that came is the host's.
	h.convKnown = false
	list := []proto.Conversation{{Agent: "claude", ID: "c2"}}
	a.conversationsAnswered(h, list, 3, nil)
	if len(h.convs) != 1 || h.convs[0].ID != "c2" || !h.convKnown {
		t.Fatalf("the list %+v, known %v", h.convs, h.convKnown)
	}
	// And one that came as the host's changed is asked for again.
	a.conversationsAnswered(h, list, 2, nil)
	if h.convKnown {
		t.Fatal("the list of a host that changed was taken for its own")
	}
}
