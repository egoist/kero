//go:build !windows

package remote

import (
	"errors"
	"syscall"
)

// A write to the pipe of a program that ended fails EPIPE: the program's
// end, read early by the write.
func brokenPipe(err error) bool {
	return errors.Is(err, syscall.EPIPE)
}
