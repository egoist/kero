//go:build darwin

package defterm

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/ebitengine/purego"
)

// launchServices is what LaunchServices and CoreFoundation answer with,
// loaded once: the calls are few and cheap after it.
var launchServices = sync.OnceValues(func() (services, error) {
	var s services
	cf, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return s, err
	}
	ls, err := purego.Dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return s, err
	}
	purego.RegisterLibFunc(&s.cfstring, cf, "CFStringCreateWithCString")
	purego.RegisterLibFunc(&s.cfurl, cf, "CFURLCreateWithCString")
	purego.RegisterLibFunc(&s.cfpath, cf, "CFURLCopyFileSystemPath")
	purego.RegisterLibFunc(&s.cfstringBytes, cf, "CFStringGetCString")
	purego.RegisterLibFunc(&s.release, cf, "CFRelease")
	purego.RegisterLibFunc(&s.setDefault, ls, "LSSetDefaultApplicationURLForContentType")
	purego.RegisterLibFunc(&s.copyDefault, ls, "LSCopyDefaultApplicationURLForContentType")
	return s, nil
})

// services are the calls this package makes, of CoreFoundation and of
// LaunchServices.
type services struct {
	cfstring      func(alloc uintptr, s *byte, encoding uint32) uintptr
	cfurl         func(alloc uintptr, s *byte, encoding uint32) uintptr
	cfpath        func(url uintptr, domain uintptr) uintptr
	cfstringBytes func(str uintptr, buf *byte, size int64, encoding uint32) bool
	release       func(cf uintptr)
	setDefault    func(appURL, uti uintptr, errOut *uintptr) int32
	copyDefault   func(uti uintptr, roles uintptr, errOut *uintptr) uintptr
}

// kCFStringEncodingUTF8, kCFURLPOSIXPathStyle and kLSRolesAll.
const (
	utf8      uint32  = 0x08000100
	posixPath         = 0
	rolesAll  uintptr = 0xFFFFFFFF
)

// Set makes Kero the default application for the types: the app bundle
// this build runs from, which LaunchServices knows by it.
func Set() error {
	app, err := bundlePath()
	if err != nil {
		return err
	}
	return setDefault(app)
}

// Restore puts Terminal.app back as the default application for the
// types, as it is on a machine Kero has not been made the default of.
func Restore() error {
	return setDefault("/System/Applications/Utilities/Terminal.app")
}

// Status tells which application runs the types now: its path, or ""
// when none of them has one.
func Status() (string, error) {
	s, err := launchServices()
	if err != nil {
		return "", err
	}
	for _, t := range Types {
		uti := s.newString(t)
		if uti == 0 {
			continue
		}
		url := s.copyDefault(uti, rolesAll, nil)
		s.release(uti)
		if url == 0 {
			continue
		}
		path := s.pathOf(url)
		s.release(url)
		if path != "" {
			return path, nil
		}
	}
	return "", nil
}

// setDefault makes app, a path of an .app bundle, the default
// application for every type.
func setDefault(app string) error {
	s, err := launchServices()
	if err != nil {
		return err
	}
	url := s.newURL(app)
	if url == 0 {
		return fmt.Errorf("cannot read %s as an application", app)
	}
	defer s.release(url)
	for _, t := range Types {
		uti := s.newString(t)
		if uti == 0 {
			continue
		}
		status := s.setDefault(url, uti, nil)
		s.release(uti)
		if status != 0 {
			return fmt.Errorf("cannot make %s the default for %s: LaunchServices status %d", filepath.Base(app), t, status)
		}
	}
	return nil
}

// bundlePath is the .app bundle this build runs from: the executable's,
// back to the bundle's name, as LaunchServices knows it.
func bundlePath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	if i := strings.Index(exe, ".app/Contents/"); i >= 0 {
		return exe[:i+len(".app")], nil
	}
	return "", errors.New("Kero is not running from an app bundle")
}

// newString makes a CFString of s, which the caller releases.
func (s services) newString(str string) uintptr {
	return s.cfstring(0, cbytes(str), utf8)
}

// newURL makes a CFURL of a path, which the caller releases.
func (s services) newURL(path string) uintptr {
	return s.cfurl(0, cbytes(path), utf8)
}

// pathOf is the file system path a CFURL names.
func (s services) pathOf(url uintptr) string {
	str := s.cfpath(url, posixPath)
	if str == 0 {
		return ""
	}
	defer s.release(str)
	buf := make([]byte, 4096)
	if !s.cfstringBytes(str, &buf[0], int64(len(buf)), utf8) {
		return ""
	}
	if i := strings.IndexByte(string(buf), 0); i >= 0 {
		return string(buf[:i])
	}
	return string(buf)
}

// cbytes is s as a C string, for a call that reads it at once.
func cbytes(s string) *byte {
	b := append([]byte(s), 0)
	return &b[0]
}
