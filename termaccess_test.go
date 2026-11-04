package main

import "testing"

func TestLastLines(t *testing.T) {
	for _, c := range []struct {
		text string
		n    int
		want string
	}{
		{"", 24, ""},
		{"  \n\n", 24, ""},
		{"a\nb\nc\n\n", 0, ""},
		{"a\nb\nc\n\n", 2, "b\nc"},
		{"a\nb\nc", 5, "a\nb\nc"},
		{"\nb", 1, "b"},
		{"\nb", 2, "b"},
	} {
		if got := lastLines(c.text, c.n); got != c.want {
			t.Errorf("lastLines(%q, %d) = %q, want %q", c.text, c.n, got, c.want)
		}
	}
}
