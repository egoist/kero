package main

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"strings"

	"github.com/egoist/mygo/ui"
)

//go:embed image_viewer.html
var viewerPageSource string

var viewerPage = template.Must(template.New("image viewer").Parse(viewerPageSource))

// viewerColors exposes the same palette used by the pane around the WebView.
func viewerColors(p *palette) template.CSS {
	css := func(c ui.Color) string { return fmt.Sprintf("#%02x%02x%02x%02x", c.R, c.G, c.B, c.A) }
	track, thumb := ui.RGBA(0, 0, 0, .06), ui.Hex("#ffffff")
	shadow := "0 .5px 1.5px #00000029,0 0 0 .5px #0000000a"
	if p.dark {
		track, thumb = ui.RGBA(255, 255, 255, .07), ui.RGBA(255, 255, 255, .2)
		shadow = "0 1px 1px #00000040"
	}
	return template.CSS(fmt.Sprintf("--card:%s;--text:%s;--muted:%s;--accent:%s;--divider:%s;--hover:%s;--press:%s;--track:%s;--thumb:%s;--shadow:%s;", css(p.card), css(p.text), css(p.textMuted), css(p.accent), css(p.divider), css(p.rowHover), css(p.rowHover.Alpha(.12)), css(track), css(thumb), shadow))
}

// Match the pane even when Kero overrides the OS appearance or the user
// changes a theme with a viewer open. Each navigation gets its own palette.
func (e *webEntry) updateViewerPalette(p *palette) {
	if !e.viewerReady || e.viewerPalette == p || e.view == nil || e.view.IsDestroyed() || e.view.Page().URL() != e.viewerURL {
		return
	}
	css, _ := json.Marshal(viewerColors(p))
	e.view.Page().Eval(fmt.Sprintf("if(window.__keroViewerGeneration===%d) document.documentElement.style.cssText=%s", e.nav, css))
	e.viewerPalette = p
}

// The only inline markup is from Kero's embedded toolbar icons. The template
// escapes file names, and the image data stays in the page, outside kerod.
func viewerArrow(name string) template.HTML {
	data, err := iconFiles.ReadFile("icons/f7-chevron-" + name + ".svg")
	if err != nil {
		panic(err)
	}
	return template.HTML(data)
}

func imageViewerHTML(name string, w, h int, mime string, data []byte, generation uint64) string {
	light, dark := keroLook("paper", false), keroLook("paper", true)
	if l := currentLooks.Load(); l != nil {
		light, dark = l.light, l.dark
	}
	var b strings.Builder
	err := viewerPage.Execute(&b, struct {
		Name           string
		Width, Height  int
		Generation     uint64
		Light, Dark    template.CSS
		Previous, Next template.HTML
		Src            template.URL
	}{
		Name: name, Width: w, Height: h, Generation: generation,
		Light: viewerColors(light.pal), Dark: viewerColors(dark.pal),
		Previous: viewerArrow("left"), Next: viewerArrow("right"),
		Src: template.URL("data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(data)),
	})
	if err != nil {
		panic(err)
	}
	return b.String()
}
