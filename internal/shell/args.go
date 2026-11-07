package shell

import (
	"fmt"
	"strings"
	"unicode"
)

// ParseArgs splits a command line without expanding variables or running a shell.
// Backslashes in paths are literal unless escaping a quote, space or backslash.
func ParseArgs(line string) ([]string, error) {
	var args []string
	var word strings.Builder
	var quote rune
	started := false
	runes := []rune(line)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if r == 0 {
			return nil, fmt.Errorf("arguments contain NUL")
		}
		if r == '\\' && quote != '\'' && i+1 < len(runes) {
			next := runes[i+1]
			if next == '"' || quote == 0 && (next == '\'' || unicode.IsSpace(next)) || next == '\\' && quote == '"' {
				word.WriteRune(next)
				started = true
				i++
				continue
			}
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				word.WriteRune(r)
			}
		} else if r == '\'' || r == '"' {
			quote, started = r, true
		} else if unicode.IsSpace(r) {
			if started {
				args = append(args, word.String())
				word.Reset()
				started = false
			}
		} else {
			word.WriteRune(r)
			started = true
		}
	}
	if quote != 0 {
		return nil, fmt.Errorf("unclosed quote")
	}
	if started {
		args = append(args, word.String())
	}
	return args, nil
}
