package proto

import (
	"net"
	"net/url"
	"strconv"
	"strings"
)

// BlankURL is the page of a browser pane that has been told none.
const BlankURL = "about:blank"

// BrowserURL makes what the user typed in a browser's address bar, or gave
// kero split --url, a URL to load: one with a scheme stays; a host, as
// "localhost:3000" or "example.com/docs", gets http for a local one and
// https for another; anything else is searched for. "" is BlankURL.
func BrowserURL(text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return BlankURL
	}
	if u, ok := address(text); ok {
		return u
	}
	return "https://www.google.com/search?q=" + url.QueryEscape(text)
}

// IsAddress reports whether text is a URL or a host, as BrowserURL goes to,
// rather than words it would search for.
func IsAddress(text string) bool {
	_, ok := address(strings.TrimSpace(text))
	return ok
}

func address(text string) (string, bool) {
	if hasScheme(text) {
		return text, true
	}
	if text == "" || strings.ContainsAny(text, " \t") {
		return "", false
	}
	host := text
	if i := strings.IndexAny(host, "/?#"); i >= 0 {
		host = host[:i]
	}
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	switch {
	case localHost(host):
		return "http://" + text, true
	case strings.HasPrefix(text, "[") && net.ParseIP(strings.Trim(host, "[]")) != nil:
		return "https://" + text, true
	case strings.Contains(host, ".") && !strings.HasPrefix(host, ".") && !strings.HasSuffix(host, "."):
		return "https://" + text, true
	}
	return "", false
}

// hasScheme tells a URL with a scheme, as "https://", "file:///" or
// "about:blank", from a host and port, as "localhost:3000".
func hasScheme(text string) bool {
	u, err := url.Parse(text)
	if err != nil || u.Scheme == "" {
		return false
	}
	if strings.HasPrefix(text[len(u.Scheme)+1:], "//") {
		return true
	}
	// "about:blank", "data:…", "mailto:…": not a port after a host.
	switch strings.ToLower(u.Scheme) {
	case "about", "data", "mailto", "javascript", "blob", "view-source":
		return true
	}
	return false
}

func localHost(host string) bool {
	host = strings.Trim(host, "[]")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".test") {
		return true
	}
	ip := hostIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified())
}

// hostIP is the address of a host, in the shorthand forms a browser
// takes: "127.1" is 127.0.0.1, and "2130706433" is it too.
func hostIP(host string) net.IP {
	if ip := net.ParseIP(host); ip != nil {
		return ip
	}
	parts := strings.Split(host, ".")
	if len(parts) > 4 {
		return nil
	}
	// The parts fill the address from the right, the last one taking
	// the bytes that are left: "127.1" is 127.0.0.1.
	nums := make([]uint64, len(parts))
	for i, p := range parts {
		if p == "" || len(p) > 1 && p[0] == '0' {
			return nil
		}
		n, err := strconv.ParseUint(p, 10, 64)
		if err != nil {
			return nil
		}
		nums[i] = n
	}
	var v uint64
	switch len(parts) {
	case 1:
		if nums[0] > 0xFFFFFFFF {
			return nil
		}
		v = nums[0]
	case 2:
		if nums[0] > 0xFF || nums[1] > 0xFFFFFF {
			return nil
		}
		v = nums[0]<<24 | nums[1]
	case 3:
		if nums[0] > 0xFF || nums[1] > 0xFFFF || nums[2] > 0xFF {
			return nil
		}
		v = nums[0]<<24 | nums[1]<<8 | nums[2]
	default:
		for _, n := range nums {
			if n > 0xFF {
				return nil
			}
		}
		v = nums[0]<<24 | nums[1]<<16 | nums[2]<<8 | nums[3]
	}
	return net.IPv4(byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}

// URLHost is the host of a URL to show for its page, as "localhost:3000",
// or the URL itself when it has none.
func URLHost(raw string) string {
	if u, err := url.Parse(raw); err == nil && u.Host != "" {
		return strings.TrimPrefix(u.Host, "www.")
	}
	return raw
}
