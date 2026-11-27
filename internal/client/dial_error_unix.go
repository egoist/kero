//go:build !windows

package client

import (
	"errors"
	"syscall"
)

func dialRefused(err error) bool { return errors.Is(err, syscall.ECONNREFUSED) }
