package shell

import (
	"os/exec"
	"runtime"
	"testing"
)

// What PowerShell reads back from PSQuote is the string, whatever quotes
// and dollars it holds.
func TestPSQuote(t *testing.T) {
	cases := []string{`C:\a b\$(calc).png`, "it's", "x\u2019+(Write-Output PWNED)+\u2019y", "\u2018\u201a\u201b", "a\"b`c"}
	for _, s := range cases {
		q := PSQuote(s)
		if q[0] != '\'' || q[len(q)-1] != '\'' {
			t.Errorf("%q: %s", s, q)
		}
	}
	if runtime.GOOS != "windows" {
		return
	}
	for _, s := range cases {
		out, err := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
			"[Console]::OutputEncoding = [Text.Encoding]::UTF8; [Console]::Out.Write("+PSQuote(s)+")").Output()
		if err != nil || string(out) != s {
			t.Errorf("%q read back as %q, %v", s, out, err)
		}
	}
}
