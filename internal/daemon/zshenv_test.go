//go:build !windows

package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// zsh redraws its prompt when the terminal resizes, after the terminal
// rewrapped the old one; the terminal clears the old one first (OSC 133
// redraw=1, Kero's .zshenv), so that resizing back and forth, as the
// sidebar's animation does, leaves one prompt, not copies of it (#333).
func TestZshResizeKeepsOnePrompt(t *testing.T) {
	shell, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("zsh not installed")
	}
	defer func(f func() bool) { zshPrompts = f }(zshPrompts)
	zshPrompts = func() bool { return true }
	s := testPane(t)
	home := t.TempDir()
	// A prompt as Powerlevel10k's two-line one: its first line, filled to
	// the terminal's width, wraps once narrower; a right prompt too.
	rc := "setopt prompt_subst\n" +
		"PROMPT=$'user@machine ~/projects ${(l:COLUMNS-34::-:)} 12:34:56\\n> '\n" +
		"RPROMPT='[main]'\n"
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte(rc), 0o644); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "zsh")
	if err := writeZshenv(dir, ""); err != nil {
		t.Fatal(err)
	}
	env := append([]string{"HOME=" + home, "TERM=xterm-256color", "LANG=C.UTF-8"}, zshEnv(dir)...)
	proc, err := startPTY(ptyOptions{
		Path: shell, Args: []string{"-zsh"}, Dir: home, Env: env,
		Cols: s.info.Cols, Rows: s.info.Rows,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { proc.Kill() })
	s.mu.Lock()
	s.proc = proc
	s.mu.Unlock()
	go s.pump(proc)

	prompts := func() int { return strings.Count(s.term.Text(), "user@machine") }
	waitFor := func(what string, ok func() bool) {
		t.Helper()
		for deadline := time.Now().Add(10 * time.Second); !ok(); time.Sleep(20 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatalf("no %s: %q", what, s.term.Text())
			}
		}
		time.Sleep(150 * time.Millisecond) // the rest of the redraw
	}
	waitFor("prompt", func() bool { return prompts() == 1 })
	// What a command wrote stays.
	proc.Write([]byte("print some-output\r"))
	waitFor("second prompt", func() bool { return prompts() == 2 })

	c := attachClient(t, s)
	// The sidebar's animation: a dozen widths, narrower, then back.
	for _, cols := range []int{90, 84, 78, 72, 66, 60, 54, 48, 54, 60, 66, 72, 78, 84, 90, 96} {
		c.resize(cols, s.info.Rows)
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(150 * time.Millisecond)
	c.sync()
	for name, text := range map[string]string{"kerod": s.term.Text(), "the app": c.term.Text()} {
		if n := strings.Count(text, "user@machine"); n != 2 || !strings.Contains(text, "some-output") {
			t.Errorf("after resizing, %s shows %d prompts, want 2 around the output:\n%s", name, n, text)
		}
	}
}

// Kero's .zshenv runs the user's startup files, once each, from their
// ZDOTDIR, which it gives back.
func TestZshStartupFiles(t *testing.T) {
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("zsh not installed")
	}
	for _, custom := range []bool{false, true} {
		home := t.TempDir()
		config := home
		if custom {
			config = t.TempDir()
			t.Setenv("ZDOTDIR", config)
		} else {
			t.Setenv("ZDOTDIR", "")
			os.Unsetenv("ZDOTDIR")
		}
		for _, name := range []string{".zshenv", ".zprofile", ".zshrc", ".zlogin"} {
			if err := os.WriteFile(filepath.Join(config, name), []byte("print -r -- ran-"+name+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		dir := filepath.Join(t.TempDir(), "zsh")
		if err := writeZshenv(dir, ""); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(zsh, "-lic", `print -r -- zdotdir:${+ZDOTDIR}:${ZDOTDIR-}`)
		cmd.Env = append([]string{"HOME=" + home, "PATH=" + os.Getenv("PATH"), "TERM=xterm-256color"}, zshEnv(dir)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("zsh: %v: %s", err, out)
		}
		for _, name := range []string{".zshenv", ".zprofile", ".zshrc", ".zlogin"} {
			if n := strings.Count(string(out), "ran-"+name); n != 1 {
				t.Errorf("custom %v: %s ran %d times: %q", custom, name, n, out)
			}
		}
		want := "zdotdir:0:"
		if custom {
			want = "zdotdir:1:" + config
		}
		if !strings.Contains(string(out), want) {
			t.Errorf("custom %v: got %q, want %q", custom, out, want)
		}
	}
}
