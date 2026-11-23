package main

import (
	"encoding/json"
	"testing"

	"kero/internal/proto"
)

func TestPickerGenerationSurvivesPickerReset(t *testing.T) {
	cl, stop := projectClient(t, func(string, json.RawMessage) (any, error) {
		return proto.FSList{}, nil
	})
	defer stop()
	a := testApp(t)
	h := a.local()
	h.cl = cl

	a.openProjectOn(h)
	first := a.picker.gen
	a.resetPicker()
	a.openProjectOn(h)
	if second := a.picker.gen; second == first {
		t.Fatalf("new picker listing reused generation %d", first)
	}
}
