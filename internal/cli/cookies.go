package cli

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"kero/internal/client"
	"kero/internal/proto"
)

// cookiesCmd saves the cookies of the browser panes' pages to a file, or
// loads them from one: Playwright's storage state, as JSON, or the
// Netscape cookies.txt that curl and browser extensions write, for a
// file named .txt.
func cookiesCmd(c *client.Client, p proto.BrowserParams, pos []string, f *flags) error {
	const use = "kero browser [target] cookies <save [file] | load <file>> [--domain domain]"
	if len(pos) == 0 || len(pos) > 2 || len(f.rest) > 0 || f.vals["out"] != "" || f.vals["text"] != "" || f.set["enter"] || p.Ref != "" {
		return usageErr("%s", use)
	}
	file := ""
	if len(pos) == 2 {
		file = pos[1]
	}
	domain := strings.ToLower(strings.TrimPrefix(f.vals["domain"], "."))
	p.Text = pos[0]
	switch p.Text {
	case "save":
		p.Domain = domain
		var res proto.BrowserResult
		if err := c.Call("browser", p, &res); err != nil {
			return err
		}
		var b []byte
		if strings.HasSuffix(strings.ToLower(file), ".txt") {
			b = netscapeCookies(res.Cookies)
		} else {
			if res.Cookies == nil {
				res.Cookies = []proto.Cookie{}
			}
			var err error
			b, err = json.MarshalIndent(struct {
				Cookies []proto.Cookie `json:"cookies"`
				Origins []any          `json:"origins"`
			}{res.Cookies, []any{}}, "", "  ")
			if err != nil {
				return err
			}
			b = append(b, '\n')
		}
		if file == "" || file == "-" {
			_, err := os.Stdout.Write(b)
			return err
		}
		if err := os.WriteFile(file, b, 0o600); err != nil {
			return err
		}
		n := fmt.Sprintf("%d cookies", len(res.Cookies))
		if len(res.Cookies) == 1 {
			n = "1 cookie"
		}
		fmt.Printf("saved %s to %s\n", n, file)
		return nil
	case "load":
		if file == "" {
			return usageErr("kero browser [target] cookies load <file> [--domain domain]")
		}
		var b []byte
		var err error
		if file == "-" {
			b, err = io.ReadAll(os.Stdin)
		} else {
			b, err = os.ReadFile(file)
		}
		if err != nil {
			return err
		}
		all, err := parseCookies(b)
		if err != nil {
			return fmt.Errorf("%s: %w", file, err)
		}
		for _, ck := range all {
			if host := strings.TrimPrefix(strings.ToLower(ck.Domain), "."); domain == "" || host == domain || strings.HasSuffix(host, "."+domain) {
				p.Cookies = append(p.Cookies, ck)
			}
		}
		if len(p.Cookies) == 0 {
			return fmt.Errorf("%s has no cookies to load", file)
		}
		var res proto.BrowserResult
		if err := c.Call("browser", p, &res); err != nil {
			return err
		}
		fmt.Println(res.Text)
		return nil
	}
	return usageErr("%s", use)
}

// parseCookies reads cookies of a storage state, a list of its cookies,
// or a cookies.txt.
func parseCookies(b []byte) ([]proto.Cookie, error) {
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf"))
	switch t := bytes.TrimSpace(b); {
	case len(t) > 0 && t[0] == '{':
		var state struct {
			Cookies []proto.Cookie `json:"cookies"`
		}
		err := json.Unmarshal(t, &state)
		return state.Cookies, err
	case len(t) > 0 && t[0] == '[':
		var list []proto.Cookie
		err := json.Unmarshal(t, &list)
		return list, err
	}
	var out []proto.Cookie
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(nil, 1<<20)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimRight(sc.Text(), "\r")
		httpOnly := strings.HasPrefix(line, "#HttpOnly_")
		if httpOnly {
			line = strings.TrimPrefix(line, "#HttpOnly_")
		} else if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) == 6 {
			f = append(f, "")
		}
		if len(f) != 7 {
			return nil, fmt.Errorf("line %d is no cookie of a cookies.txt", n)
		}
		exp, err := strconv.ParseFloat(f[4], 64)
		if err != nil {
			return nil, fmt.Errorf("line %d: expiry %q is no number", n, f[4])
		}
		if exp <= 0 {
			exp = -1
		}
		domain := f[0]
		if strings.EqualFold(f[1], "TRUE") && !strings.HasPrefix(domain, ".") {
			domain = "." + domain
		}
		out = append(out, proto.Cookie{Name: f[5], Value: f[6], Domain: domain, Path: f[2], Expires: exp,
			HTTPOnly: httpOnly, Secure: strings.EqualFold(f[3], "TRUE"), SameSite: "Lax"})
	}
	return out, sc.Err()
}

// netscapeCookies writes cookies as a cookies.txt.
func netscapeCookies(cs []proto.Cookie) []byte {
	var b bytes.Buffer
	b.WriteString("# Netscape HTTP Cookie File\n")
	flag := func(v bool) string {
		if v {
			return "TRUE"
		}
		return "FALSE"
	}
	for _, c := range cs {
		if c.HTTPOnly {
			b.WriteString("#HttpOnly_")
		}
		exp := int64(0)
		if c.Expires > 0 {
			exp = int64(c.Expires)
		}
		fmt.Fprintf(&b, "%s\t%s\t%s\t%s\t%d\t%s\t%s\n", c.Domain, flag(strings.HasPrefix(c.Domain, ".")), c.Path, flag(c.Secure), exp, c.Name, c.Value)
	}
	return b.Bytes()
}
