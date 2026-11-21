// Package defterm makes Kero the default application for the content
// types a shell script opens with on macOS, and puts Terminal.app back.
// It is the app's and the kero command's, not kerod's: LaunchServices
// answers for the machine the app runs on.
package defterm

import "errors"

// ErrNotMacOS is what Set, Restore and Status give where there are no
// LaunchServices: the feature is macOS's.
var ErrNotMacOS = errors.New("default terminal is only on macOS")

// Types are the content types whose default application Kero takes, or
// gives back: shell scripts, as .command files, and executables, which
// a terminal runs.
var Types = []string{
	"com.apple.terminal.shell-script",
	"public.shell-script",
	"public.unix-executable",
}
