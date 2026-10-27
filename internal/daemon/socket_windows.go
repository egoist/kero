package daemon

import (
	"net"
	"os"
)

// listenSocket listens on a Unix socket, in a directory of the user's
// profile, which other users cannot reach.
func listenSocket(path string) (net.Listener, error) { return net.Listen("unix", path) }

// peerUID is unknown on Windows: -1.
func peerUID(net.Conn) int { return -1 }

// ownedByUser: the temporary directory on Windows is the user's.
func ownedByUser(os.FileInfo) bool { return true }
