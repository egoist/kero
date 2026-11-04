package main

import (
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
)

// termAccess shows a terminal's view to assistive technology as a text
// field, whose value, while it has the focus, is the text of its screen,
// as Terminal's and Ghostty's are. Dictation apps such as Typeless paste
// with ⌘V and then look for a focused text field to tell the text landed:
// a terminal that reads as a mere group leaves their "copy this text"
// panel up.
func termAccess(el ui.Element, t *terminal.Terminal, focused bool) {
	el.Role(ui.RoleTextField)
	if focused {
		el.Value(axScreen.of(t))
	}
}

// axScreen is the focused terminal's screen text as last read: a read
// copies the scrollback, so it is read again at most every half second,
// which the apps polling the field need no faster.
var axScreen screenRead

type screenRead struct {
	t    *terminal.Terminal
	text string
	at   time.Time
}

func (s *screenRead) of(t *terminal.Terminal) string {
	if s.t != t || time.Since(s.at) > 500*time.Millisecond {
		_, rows := t.Size()
		s.t, s.text, s.at = t, lastLines(t.Text(), rows), time.Now()
	}
	return s.text
}

// lastLines returns the last n lines of text, without the blank lines
// after them.
func lastLines(text string, n int) string {
	text = strings.TrimRight(text, " \n")
	i := len(text)
	for ; n > 0 && i > 0; n-- {
		i = strings.LastIndexByte(text[:i], '\n')
		if i < 0 {
			return text
		}
	}
	return text[i+1:]
}
