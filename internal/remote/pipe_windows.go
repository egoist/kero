package remote

import (
	"errors"
	"syscall"
)

// The same answer on Windows, as ERROR_BROKEN_PIPE: a write to the pipe
// of a program that ended.
func brokenPipe(err error) bool {
	return errors.Is(err, syscall.ERROR_BROKEN_PIPE)
}
