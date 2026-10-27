package remote

import "testing"

func TestAgentLine(t *testing.T) {
	for _, c := range []struct{ out, want string }{
		{"\n" + agentMark + "/tmp/agent.sock\n", "/tmp/agent.sock"},
		{"Welcome!\n\n" + agentMark + "/Users/me/Library/Group Containers/2BUI8C4Y56.com.1password/t/agent.sock\n", "/Users/me/Library/Group Containers/2BUI8C4Y56.com.1password/t/agent.sock"},
		{"\n" + agentMark + "\n", ""},
		{agentMark + "/not/after/a/newline\n", ""},
		{"", ""},
	} {
		if got := agentLine([]byte(c.out)); got != c.want {
			t.Errorf("agentLine(%q) = %q, want %q", c.out, got, c.want)
		}
	}
}
