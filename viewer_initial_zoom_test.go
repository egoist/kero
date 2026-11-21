package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestViewerInitialZoom(t *testing.T) {
	appearance := currentViewerAppearance()
	group := viewerGroup{zoom: viewerZoomState{Enabled: true, Mode: "actual", Zoom: 2, PanX: .25, PanY: -.1}}
	initial := group.snapshot(0)
	appearance.InitialZoom = &initial
	page := appearance.render(preparedViewerImage{name: "sample.png", w: 64, h: 32, src: "data:image/png;base64,"}, 4)
	encoded, err := json.Marshal(initial)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(page, string(encoded)) {
		t.Fatal("new image document lacks the initial synchronized view")
	}
}
