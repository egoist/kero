//go:build !darwin

package main

import "errors"

// lidAwake tells that Kero can keep the computer awake with its lid
// closed on battery: not here, where the system's own setting decides
// what closing the lid does.
const lidAwake = false

// errCanceled is the password's dialog closed without a password.
var errCanceled = errors.New("canceled")

type lidHold struct{}

func (*lidHold) hold(bool) {}

func lidHelperInstalled() bool { return false }

func installLidHelper(string) error { return nil }
