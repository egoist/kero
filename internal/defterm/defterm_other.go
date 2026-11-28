//go:build !darwin

package defterm

// Set makes Kero the default application for the types.
func Set() error { return ErrNotMacOS }

// Restore puts Terminal.app back as the default application for the
// types.
func Restore() error { return ErrNotMacOS }

// Status tells which application runs the types now.
func Status() (string, error) { return "", ErrNotMacOS }
