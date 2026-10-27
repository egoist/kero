//go:build !linux && !darwin && !windows

package daemon

import "net"

func peerUID(net.Conn) int { return -1 }
