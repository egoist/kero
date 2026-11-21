package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"html/template"
	"strings"

	"github.com/egoist/mygo/i18n"
	"github.com/egoist/mygo/ui"

	"kero/locales"
)

//go:embed image_viewer.html
var viewerPageSource string

var viewerPage = template.Must(template.New("image viewer").Funcs(template.FuncMap{"icon": viewerIcon}).Parse(viewerPageSource))

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

type viewerLabels struct {
	Language, Controls, Gallery, Previous, Next, NewPane string
	Sync, SyncTip, Scale, Fit, FitTip, Actual, Download  string
}

func viewerLabelsIn(tag string) viewerLabels {
	m := locales.In(tag)
	_, language, _ := locales.Catalog.Message(tag, "viewerControls")
	return viewerLabels{
		Language: language, Controls: m.ViewerControls(), Gallery: m.ViewerGallery(),
		Previous: m.ViewerPrevious(), Next: m.ViewerNext(), NewPane: m.ViewerNewPane(),
		Sync: m.ViewerSync(), SyncTip: m.ViewerSyncTip(), Scale: m.ViewerScale(),
		Fit: m.ViewerFit(), FitTip: m.ViewerFitTip(), Actual: m.ActionActualSize(), Download: m.ViewerDownload(),
	}
}

// Update the open document in place so language and theme changes keep its
// focus, image transform and current sync state.
func (e *webEntry) updateViewerAppearance(p *palette) {
	if !e.viewer.ready {
		return
	}
	tag := i18n.Locale()
	if (e.viewer.palette == p && e.viewer.locale == tag) || e.view == nil || e.view.IsDestroyed() || e.view.Page().URL() != e.viewer.url {
		return
	}
	page := e.view.Page()
	if e.viewer.palette != p {
		css, _ := json.Marshal(viewerColors(p))
		page.Eval(fmt.Sprintf("if(window.__keroViewerGeneration===%d) document.documentElement.style.cssText=%s", e.nav, css))
	}
	if e.viewer.palette == nil || e.viewer.locale != tag {
		labels, _ := json.Marshal(viewerLabelsIn(tag))
		page.Eval(fmt.Sprintf("if(window.__keroViewerGeneration===%d) window.__keroApplyLabels(%s)", e.nav, labels))
	}
	e.viewer.palette, e.viewer.locale = p, tag
}

// The only inline markup is from Kero's embedded toolbar icons. The template
// escapes file names, and the image data stays in the page, outside kerod.
func viewerIcon(name string) template.HTML {
	data, err := iconFiles.ReadFile("icons/f7-" + name + ".svg")
	if err != nil {
		panic(err)
	}
	return template.HTML(data)
}

type viewerAppearance struct {
	Labels      viewerLabels
	Light, Dark template.CSS
	InitialZoom *viewerZoomSnapshot
}

func currentViewerAppearance() viewerAppearance {
	light, dark := keroLook("paper", false), keroLook("paper", true)
	if l := currentLooks.Load(); l != nil {
		light, dark = l.light, l.dark
	}
	return viewerAppearance{Labels: viewerLabelsIn(i18n.Locale()), Light: viewerColors(light.pal), Dark: viewerColors(dark.pal)}
}

func (a viewerAppearance) render(img preparedViewerImage, generation uint64) string {
	var b strings.Builder
	b.Grow(len(viewerPageSource) + len(img.src))
	err := viewerPage.Execute(&b, struct {
		viewerAppearance
		Name          string
		Width, Height int
		Generation    uint64
		Src           template.URL
	}{a, img.name, img.w, img.h, generation, template.URL(img.src)})
	if err != nil {
		panic(err)
	}
	return b.String()
}
