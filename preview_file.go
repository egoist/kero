package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"

	"kero/internal/client"
	"kero/internal/proto"
)

// previewSource captures the pane's host before a file read leaves the UI
// thread. Its zero value reads files on this machine.
type previewSource struct {
	host   string
	client *client.Client
}

func (h *host) previewSource() previewSource {
	return previewSource{host: h.name, client: h.cl}
}

func (s previewSource) read(path, base string, limit int64) ([]byte, error) {
	if s.host != "" {
		if s.client == nil {
			return nil, errors.New("image host is not connected")
		}
		var st proto.FSStat
		if err := s.client.Call("fs.stat", proto.FSStatParams{Path: path, Base: base}, &st); err != nil {
			return nil, err
		}
		if !st.Exists || st.Dir || st.Size > limit {
			return nil, errors.New("remote image is missing, a directory, or too large")
		}
		var r proto.FSRead
		if err := s.client.Call("fs.read", proto.FSReadParams{Path: st.Path, Max: limit}, &r); err != nil {
			return nil, err
		}
		if int64(len(r.Data)) > limit {
			return nil, errors.New("remote image exceeds size limit")
		}
		return r.Data, nil
	}
	if !filepath.IsAbs(path) {
		return nil, errors.New("local image path is not absolute")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.IsDir() || st.Size() > limit {
		return nil, errors.New("local image is missing, a directory, or too large")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if int64(len(data)) > limit {
		return nil, errors.New("local image grew beyond the size limit")
	}
	return data, err
}
