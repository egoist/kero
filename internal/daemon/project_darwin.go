package daemon

import (
	"errors"
	"fmt"
	"path/filepath"
	"sync"

	"github.com/ebitengine/purego"
)

// Native package metadata matches the folder picker without a list of extensions.
var projectDirCheck = sync.OnceValues(func() (func(string) error, error) {
	lib, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, err
	}
	// A pointer-typed lookup reads the exported CFStringRef without uintptr casts.
	var symbol func(uintptr, string) *uintptr
	purego.RegisterLibFunc(&symbol, purego.RTLD_DEFAULT, "dlsym")
	key := symbol(lib, "kCFURLIsPackageKey")
	if key == nil {
		return nil, errors.New("cannot load macOS directory package key")
	}
	packageKey := *key
	var fileURL func(uintptr, string, int, bool) uintptr
	var copyProperty func(uintptr, uintptr, *uintptr, uintptr) bool
	var boolValue func(uintptr) bool
	var release func(uintptr)
	purego.RegisterLibFunc(&fileURL, lib, "CFURLCreateFromFileSystemRepresentation")
	purego.RegisterLibFunc(&copyProperty, lib, "CFURLCopyResourcePropertyForKey")
	purego.RegisterLibFunc(&boolValue, lib, "CFBooleanGetValue")
	purego.RegisterLibFunc(&release, lib, "CFRelease")
	return func(dir string) error {
		path, err := filepath.EvalSymlinks(dir)
		if err != nil {
			return err
		}
		url := fileURL(0, path, len(path), true)
		if url == 0 {
			return fmt.Errorf("cannot inspect project directory: %s", dir)
		}
		defer release(url)
		var value uintptr
		if !copyProperty(url, packageKey, &value, 0) || value == 0 {
			return fmt.Errorf("cannot determine directory package status: %s", dir)
		}
		defer release(value)
		if boolValue(value) {
			return fmt.Errorf("cannot open a file package as a project: %s", dir)
		}
		return nil
	}, nil
})

func checkProjectDir(dir string) error {
	check, err := projectDirCheck()
	if err != nil {
		return err
	}
	return check(dir)
}
