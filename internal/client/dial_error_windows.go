//go:build windows

package client

import (
	"errors"
	"syscall"

	"golang.org/x/sys/windows"
)

func dialRefused(err error) bool {
	return errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, windows.WSAECONNREFUSED)
}
