package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/markdown/parser"

	"kero/internal/client"
	"kero/internal/proto"
)

const (
	maxMarkdownImageBytes   = 8 << 20
	maxMarkdownImagePixels  = 16_000_000
	maxMarkdownImagesPixels = 64_000_000
)

// A loader belongs to one document path, host connection and network
// consent. MyGo caches results and runs Load on workers; those workers
// never read UI state. Replacing the options/loader leaves obsolete
// results in the old cache.
type markdownImages struct {
	base    string
	client  *client.Client
	network bool
	blocked atomic.Bool
	failed  atomic.Bool
	mu      sync.Mutex
	pixels  int64
	count   int
	slots   chan struct{}
	linked  sync.Map // URL -> *markdownLinkedImage
}

func newMarkdownImages(base string, cl *client.Client, network bool) *markdownImages {
	return &markdownImages{base: base, client: cl, network: network, slots: make(chan struct{}, 4)}
}

func (m *markdownImages) load(dest string) (src ui.ImageSource, err error) {
	u, err := url.Parse(dest)
	if err != nil {
		m.failed.Store(true)
		return nil, err
	}
	web := u.Scheme == "http" || u.Scheme == "https"
	if web && !m.network {
		m.blocked.Store(true)
		return nil, fmt.Errorf("network images require permission")
	}
	defer func() {
		if err != nil {
			m.failed.Store(true)
		}
	}()
	m.mu.Lock()
	m.count++
	count := m.count
	m.mu.Unlock()
	if count > 128 {
		return nil, fmt.Errorf("too many images in this document")
	}
	m.slots <- struct{}{}
	defer func() { <-m.slots }()
	var data []byte
	if web {
		data, err = fetchMarkdownImage(markdownImageHTTPClient, dest)
	} else {
		var file string
		file, _, err = previewPath(m.base, dest)
		if err == nil {
			if m.client == nil {
				return nil, fmt.Errorf("file host is disconnected")
			}
			var res proto.FSRead
			err = m.client.Call("fs.read", proto.FSReadParams{
				Path: file, Max: maxMarkdownImageBytes + 1,
			}, &res)
			data = res.Data
		}
	}
	if err != nil {
		return nil, err
	}
	return decodeMarkdownImage(data, func(pixels int64) bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		if pixels > maxMarkdownImagesPixels-m.pixels {
			return false
		}
		m.pixels += pixels
		return true
	})
}

func decodeMarkdownImage(data []byte, reserve func(int64) bool) (ui.ImageSource, error) {
	if len(data) == 0 || len(data) > maxMarkdownImageBytes {
		return nil, fmt.Errorf("image exceeds the 8 MiB limit or is empty")
	}
	// Inspect raster dimensions before allocating decoded pixels. SVG is
	// parsed by MyGo's native SVG renderer, not a browser/resource loader.
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err == nil {
		pixels := int64(cfg.Width) * int64(cfg.Height)
		if cfg.Width <= 0 || cfg.Height <= 0 || pixels > maxMarkdownImagePixels || !reserve(pixels) {
			return nil, fmt.Errorf("image dimensions exceed the preview budget")
		}
		return ui.DecodeBitmap(data)
	}
	svg, err := ui.ParseSVG(data)
	if err != nil {
		return nil, err
	}
	w, h := svg.Size()
	if !(w > 0 && h > 0 && w <= 8192 && h <= 8192) ||
		float64(w)*float64(h) > maxMarkdownImagePixels || !reserve(int64(w*h)+1) {
		return nil, fmt.Errorf("invalid or oversized SVG")
	}
	return svg, nil
}

func fetchMarkdownImage(cl *http.Client, dest string) ([]byte, error) {
	u, err := url.Parse(dest)
	if err != nil || u == nil || (u.Scheme != "http" && u.Scheme != "https") ||
		u.User != nil || u.Hostname() == "" {
		return nil, fmt.Errorf("unsupported image URL")
	}
	req, err := http.NewRequest(http.MethodGet, dest, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "image/*")
	res, err := cl.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("image request returned HTTP %d", res.StatusCode)
	}
	if res.ContentLength > maxMarkdownImageBytes {
		return nil, fmt.Errorf("image exceeds 8 MiB")
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, maxMarkdownImageBytes+1))
	if err == nil && len(data) > maxMarkdownImageBytes {
		err = fmt.Errorf("image exceeds 8 MiB")
	}
	return data, err
}

// Requests have no cookies, credentials, referrer or environment proxy.
// DNS answers are checked at the actual dial, including after redirects,
// to avoid a document probing localhost, the LAN or cloud metadata
// endpoints.
var markdownImageHTTPClient = &http.Client{
	Timeout: 15 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 || (req.URL.Scheme != "http" && req.URL.Scheme != "https") ||
			req.URL.User != nil {
			return fmt.Errorf("unsupported image redirect")
		}
		return nil
	},
	Transport: &http.Transport{
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
		IdleConnTimeout:       30 * time.Second,
		MaxIdleConns:          8,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
			if err != nil {
				return nil, err
			}
			for _, ip := range ips {
				if !markdownPublicIP(ip) {
					return nil, fmt.Errorf("private network images are not allowed")
				}
			}
			var dial net.Dialer
			for _, ip := range ips {
				conn, err := dial.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
				if err == nil {
					return conn, nil
				}
			}
			return nil, fmt.Errorf("image host could not be reached")
		},
	},
}

func markdownPublicIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.Zone() != "" {
		return false
	}
	if ip.Is6() && !netip.MustParsePrefix("2000::/3").Contains(ip) {
		return false
	}
	// Shared-address space includes tailnets. Reserved/test ranges must not
	// be treated as public destinations either.
	for _, prefix := range []string{
		"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24",
		"192.88.99.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
		"240.0.0.0/4", "2001:db8::/32", "2001::/32", "2002::/16", "64:ff9b::/96",
	} {
		if netip.MustParsePrefix(prefix).Contains(ip) {
			return false
		}
	}
	return true
}

// The native Markdown image-only paragraph does not include linked
// images. Keep badges/image links native too, without replacing text
// paragraph layout.
type markdownLinkedImage struct {
	done   chan struct{}
	source ui.ImageSource
}

func (m *markdownImages) linkedImage(c *ui.Context, dest string) ui.ImageSource {
	v, loaded := m.linked.LoadOrStore(dest, &markdownLinkedImage{done: make(chan struct{})})
	e := v.(*markdownLinkedImage)
	if !loaded {
		services := c.Services()
		go func() {
			e.source, _ = m.load(dest)
			close(e.done)
			services.Invalidate()
		}()
	}
	select {
	case <-e.done:
		return e.source
	default:
		return nil
	}
}

func (m *markdownPreview) imageLinks(c *ui.Context, doc *parser.Document, index int) bool {
	if doc.Block(index).Kind != parser.Paragraph {
		return false
	}
	type item struct {
		image     parser.Inline
		alt, link string
	}
	var items []item
	in := doc.Inlines(index)
	linked := false
	for k := 0; k < len(in); k = in[k].Next {
		n := in[k]
		link := ""
		imageIndex := k
		switch n.Kind {
		case parser.Text:
			if strings.TrimSpace(n.Text) != "" {
				return false
			}
			continue
		case parser.SoftBreak, parser.LineBreak:
			continue
		case parser.Link:
			if k+1 >= len(in) || in[k+1].Kind != parser.Image || in[k+1].Next != n.Next {
				return false
			}
			linked = true
			link = n.Dest
			imageIndex = k + 1
			n = in[imageIndex]
		case parser.Image:
		default:
			return false
		}
		items = append(items, item{n, parser.PlainText(in[imageIndex+1 : n.Next]), link})
	}
	if !linked {
		return false
	}
	ui.Row(c).Wrap().Gap(8).FillWidth().Children(func() {
		for i, it := range items {
			src := m.images.linkedImage(c, it.image.Dest)
			show := func() {
				if src == nil {
					ui.Text(c, it.alt)
					return
				}
				img := ui.Image(c, src).Label(it.alt).MaxWidthPercent(100)
				if w, h := ui.ImageSize(src); w > 0 && h > 0 {
					img.AspectRatio(w / h)
				}
			}
			if it.link == "" {
				ui.Box(c.Key(i)).MaxWidthPercent(100).Children(show)
				continue
			}
			onLink := m.options.OnLink
			ui.ButtonBase(c.Key(i)).Padding(0).MaxWidthPercent(100).
				Label(it.alt).Tooltip(it.link).Children(show).OnClick(func() {
				if onLink != nil {
					onLink(it.link)
				}
			})
		}
	})
	return true
}
