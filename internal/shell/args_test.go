package shell

import (
	"reflect"
	"testing"
)

func TestParseArgs(t *testing.T) {
	for _, tt := range []struct {
		line string
		want []string
	}{
		{"", nil},
		{" \t ", nil},
		{`-l`, []string{"-l"}},
		{`-c "echo hi"`, []string{"-c", "echo hi"}},
		{`-c 'echo "hi"'`, []string{"-c", `echo "hi"`}},
		{`--name="a b" '' ""`, []string{"--name=a b", "", ""}},
		{`-File "C:\Users\My Name\profile.ps1"`, []string{"-File", `C:\Users\My Name\profile.ps1`}},
		{`--path C:\tools\profile.ps1`, []string{"--path", `C:\tools\profile.ps1`}},
		{`--path \\server\share`, []string{"--path", `\\server\share`}},
		{`-c "echo \"hi\""`, []string{"-c", `echo "hi"`}},
		{`hello\ world $HOME`, []string{"hello world", "$HOME"}},
	} {
		t.Run(tt.line, func(t *testing.T) {
			got, err := ParseArgs(tt.line)
			if err != nil || !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("ParseArgs(%q) = %q, %v; want %q", tt.line, got, err, tt.want)
			}
		})
	}
	for _, bad := range []string{`-c "echo hi`, "'unterminated", "a\x00b"} {
		if _, err := ParseArgs(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}
