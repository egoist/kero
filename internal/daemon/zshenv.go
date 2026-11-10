package daemon

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// zsh starts with a .zshenv of Kero's (ZDOTDIR), which sources the user's
// startup files as zsh would, then marks the prompts (OSC 133): zsh draws
// its prompt again when the terminal resizes, after the terminal rewrapped
// the old one, which a wide prompt then leaves copies of; marked with
// redraw=1, the old one is cleared first. In Kero Dev, it also puts bin
// first (binFirst).

// zshDir returns where zsh finds Kero's .zshenv, "" for nowhere: Windows'
// zsh, of MSYS2 or Cygwin, takes paths of its own.
func (d *Daemon) zshDir() string {
	if runtime.GOOS == "windows" || d.dir == "" {
		return ""
	}
	return filepath.Join(d.dir, "zsh")
}

// zshPrompts tells whether panes' shell is a zsh that marks its prompts;
// tests set it.
var zshPrompts = func() bool {
	return runtime.GOOS != "windows" && shellName(userShell()) == "zsh"
}

// writeZshenv writes Kero's .zshenv in dir, putting bin first when set.
func writeZshenv(dir, bin string) error {
	s := zshIntegration
	if bin != "" {
		s += strings.ReplaceAll(zshBinFirst, "BIN", shellQuote("zsh", bin))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, ".zshenv"), []byte(s), 0o644)
}

// zshIntegration gives zsh the user's ZDOTDIR and .zshenv back, then, in
// an interactive shell, marks its prompts from the first, once the startup
// files and the prompt's theme have set it: where each starts (A, with
// redraw=1), its input (B), its next lines (P) and the output of what it
// runs (C). A prompt that marks itself, as Powerlevel10k's does when asked,
// is left alone.
const zshIntegration = `if [[ -n $KERO_ZDOTDIR ]]; then ZDOTDIR=$KERO_ZDOTDIR; else unset ZDOTDIR; fi
[[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source ${ZDOTDIR:-$HOME}/.zshenv
[[ -o interactive ]] || return 0
typeset -gi __p9k_force_term_shell_integration=1
__kero_mark_prompt() {
  emulate -L zsh
  [[ -o promptpercent ]] || return 0
  local start=$'%{\e]133;A;cl=line;redraw=1\a%}' input=$'%{\e]133;B\a%}'
  local continuation=$'%{\e]133;P;k=s\a%}'
  [[ $PS1 == *$'\e]133;'* ]] || PS1=$start${PS1//$'\n'/$'\n'$continuation}$input
  [[ $PS2 == *$'\e]133;'* ]] || PS2=$continuation$PS2$input
}
__kero_command_start() {
  builtin print -n $'\e]133;C\a'
}
__kero_install_marks() {
  emulate -L zsh
  autoload -Uz add-zsh-hook
  add-zsh-hook -d precmd __kero_install_marks
  add-zsh-hook precmd __kero_mark_prompt
  add-zsh-hook preexec __kero_command_start
  __kero_mark_prompt
}
typeset -ga precmd_functions
precmd_functions+=(__kero_install_marks)
`

// zshBinFirst puts BIN first before the first prompt, after .zprofile and
// .zshrc.
const zshBinFirst = `__kero_bin_first() {
  path=(BIN ${path:#BIN})
  precmd_functions=(${precmd_functions:#__kero_bin_first})
  unfunction __kero_bin_first
}
precmd_functions+=(__kero_bin_first)
`
