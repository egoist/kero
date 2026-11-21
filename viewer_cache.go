package main

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	viewerCacheEntries = 8
	viewerCacheBytes   = 64 << 20
	viewerRemoteTTL    = 3 * time.Second
)

// Only the encoded image and thumbnail survive preparation. The decoded bitmap
// and source bytes can be collected before the WebView document is rendered.
type preparedViewerImage struct {
	name, src, thumbnail string
	w, h                 int
}

func viewerDataURL(mime string, data []byte) string {
	var b strings.Builder
	b.Grow(len("data:;base64,") + len(mime) + base64.StdEncoding.EncodedLen(len(data)))
	b.WriteString("data:" + mime + ";base64,")
	enc := base64.NewEncoder(base64.StdEncoding, &b)
	_, _ = enc.Write(data)
	_ = enc.Close()
	return b.String()
}

type viewerCacheKey struct {
	source previewSource // a reconnected remote host has a different client
	url    string
}

type viewerImageLoad struct {
	key         viewerCacheKey
	done        chan struct{}
	replacement atomic.Pointer[viewerImageLoad]
	// Published by closing done. Readers need no lock after that.
	image   preparedViewerImage
	err     error
	size    int64
	modTime time.Time
	expires time.Time
}

type viewerCache struct {
	mu      sync.Mutex
	pending map[viewerCacheKey]*viewerImageLoad
	recent  []*viewerImageLoad // oldest first, at most viewerCacheEntries
}

// Register requests in navigation order, before dispatching any worker. A
// force reload replaces even an unfinished read of the same source.
func (c *viewerCache) load(raw string, source previewSource, windows, force bool) *viewerImageLoad {
	key := viewerCacheKey{source, raw}
	if source.host == "" {
		key.source.client = nil // local reads go directly to disk
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	existing := c.pending[key]
	if existing != nil && !force {
		return existing
	}
	var prior *viewerImageLoad
	for i, item := range c.recent {
		if item.key == key {
			c.recent = slices.Delete(c.recent, i, i+1)
			if !force && source.host != "" && time.Now().Before(item.expires) {
				c.recent = append(c.recent, item)
				return item
			}
			existing = item
			if !force && source.host == "" {
				prior = item
			}
			break
		}
	}
	if c.pending == nil {
		c.pending = make(map[viewerCacheKey]*viewerImageLoad)
	}
	load := &viewerImageLoad{key: key, done: make(chan struct{})}
	c.pending[key] = load
	if existing != nil {
		existing.replacement.Store(load)
	}
	go func() {
		load.err = load.prepare(prior, windows)
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.pending[key] == load {
			delete(c.pending, key)
			if load.err == nil {
				c.retain(load)
			}
		}
		close(load.done)
	}()
	return load
}

func (l *viewerImageLoad) prepare(prior *viewerImageLoad, windows bool) error {
	host, file, _, ok := imageViewerQuery(l.key.url)
	if !ok || host != l.key.source.host {
		return errors.New("invalid image viewer source")
	}
	if host == "" {
		if !filepath.IsAbs(file) {
			return errors.New("local image path is not absolute")
		}
		st, err := os.Stat(file)
		if err != nil {
			return err
		}
		if !st.Mode().IsRegular() || st.Size() > maxViewerBytes {
			return errors.New("local image is not a regular file or is too large")
		}
		l.size, l.modTime = st.Size(), st.ModTime()
		if prior != nil && l.size == prior.size && l.modTime.Equal(prior.modTime) {
			l.image = prior.image
			return nil
		}
	}
	img, err := readImage(l.key.url, l.key.source, windows)
	if err != nil {
		return err
	}
	l.image = preparedViewerImage{name: img.name, src: viewerDataURL(img.mime, img.data), thumbnail: img.thumbnail, w: img.w, h: img.h}
	if host != "" {
		l.expires = time.Now().Add(viewerRemoteTTL)
	}
	return nil
}

// retain runs under mu. Walk the small LRU from newest to oldest so both
// limits apply to the actual retained strings, including base64 overhead.
func (c *viewerCache) retain(load *viewerImageLoad) {
	c.recent = append(c.recent, load)
	bytes := 0
	for i := len(c.recent) - 1; i >= 0; i-- {
		img := c.recent[i].image
		bytes += len(img.src) + len(img.thumbnail) + len(img.name)
		if bytes > viewerCacheBytes || len(c.recent)-i > viewerCacheEntries {
			c.recent = slices.Delete(c.recent, 0, i+1)
			return
		}
	}
}
