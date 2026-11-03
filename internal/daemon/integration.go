package daemon

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"kero/internal/settings"
)

// Shell integration: panes' shells mark their prompts and commands with OSC
// 133, which the pane's blocks come from (blockTrack). A shell's own startup
// files run as they always do, and the marks go on what they leave:
//
//   - zsh reads Kero's .zshenv (ZDOTDIR), which gives the user's ZDOTDIR back;
//     the hooks go in at the first prompt, after .zshrc.
//   - bash starts in POSIX mode, the one way to run a file of Kero's in a login
//     shell, which gives its usual mode back and reads its usual files. macOS's
//     own bash, which POSIX mode would leave so without reading the file, takes
//     it from PROMPT_COMMAND after its files instead, unless they replace it.
//   - fish takes -C, which runs after config.fish; since 4.0 it marks its
//     prompts itself, and the file does nothing.
//   - PowerShell's prompt is wrapped after its profile (powershellMarks).
//
// shell-integration = false starts every shell as it was.

const (
	// integrationVar tells Kero's .zshenv to load the marks.
	integrationVar = "KERO_SHELL_INTEGRATION"
	// bashInjectVar tells kero.bash that it runs as bash's ENV, and
	// bashBootVar what in PROMPT_COMMAND runs it (bashOld).
	bashInjectVar = "KERO_BASH_INJECT"
	bashBootVar   = "KERO_BASH_BOOT"
)

// bashOld tells macOS's own bash, 3.2, which takes no ENV in POSIX mode.
func bashOld(shell string) bool { return runtime.GOOS == "darwin" && shell == "/bin/bash" }

// bashBoot is the PROMPT_COMMAND that runs kero.bash in bashOld.
func bashBoot(integ string) string {
	return ". " + shellQuote("bash", filepath.Join(integ, "bash", "kero.bash"))
}

// integrationDir is where the shells' files of Kero's are, "" when panes'
// shells don't load them.
func (d *Daemon) integrationDir() string {
	if d.dir == "" || !settings.Load().ShellIntegration {
		return ""
	}
	if _, err := os.Stat(filepath.Join(d.dir, "zsh", "kero.zsh")); err != nil {
		return ""
	}
	return d.dir
}

// integrationEnv is what shell's environment needs for integ (shellArgs) and
// bin first on PATH (binFirst).
func integrationEnv(shell, bin, integ string, command []string) []string {
	if runtime.GOOS == "windows" {
		return nil // PowerShell's are in its arguments (powershellArgs)
	}
	switch shellName(shell) {
	case "zsh":
		if bin == "" && integ == "" {
			return nil
		}
		dir := integ
		if dir == "" {
			dir = filepath.Dir(bin)
		}
		env := []string{"ZDOTDIR=" + filepath.Join(dir, "zsh"), "KERO_ZDOTDIR=" + os.Getenv("ZDOTDIR")}
		if integ != "" {
			env = append(env, integrationVar+"=1")
		}
		return env
	case "bash":
		// A session's command runs in a usual bash, and the shell it goes on
		// with has these from its script (shellArgs).
		if integ == "" || len(command) > 0 {
			return nil
		}
		if bashOld(shell) {
			return []string{"PROMPT_COMMAND=" + bashBoot(integ), bashBootVar + "=" + bashBoot(integ)}
		}
		env := []string{"ENV=" + filepath.Join(integ, "bash", "kero.bash"), bashInjectVar + "=1", "KERO_BASH_ENV=" + os.Getenv("ENV")}
		// POSIX mode's history would be ~/.sh_history.
		if os.Getenv("HISTFILE") == "" {
			if home, err := os.UserHomeDir(); err == nil {
				env = append(env, "HISTFILE="+filepath.Join(home, ".bash_history"), "KERO_BASH_UNEXPORT_HISTFILE=1")
			}
		}
		return env
	}
	return nil
}

// fishInit is what fish runs with -C: bin first on PATH, and its marks.
func fishInit(bin, integ string) string {
	var cmds []string
	if bin != "" {
		cmds = append(cmds, fishBinFirst(bin))
	}
	if integ != "" {
		cmds = append(cmds, "source "+shellQuote("fish", filepath.Join(integ, "fish", "kero.fish")))
	}
	return strings.Join(cmds, "; ")
}

// writeShellFiles writes the shells' files of Kero's into dir: they are read
// by the shells that start from now on, and written for a version's own.
func writeShellFiles(dir, bin string) error {
	files := map[string]string{
		"zsh/.zshenv":    zshEnvFile(dir, bin),
		"zsh/kero.zsh":   zshIntegration,
		"bash/kero.bash": bashIntegration,
		"fish/kero.fish": fishIntegration,
	}
	for name, text := range files {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// zshEnvFile is Kero's .zshenv: the user's ZDOTDIR and .zshenv, then the
// marks, and bin first before the first prompt, after .zprofile and .zshrc.
func zshEnvFile(dir, bin string) string {
	s := `if [[ -n $KERO_ZDOTDIR ]]; then ZDOTDIR=$KERO_ZDOTDIR; else unset ZDOTDIR; fi
[[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source ${ZDOTDIR:-$HOME}/.zshenv
if [[ -n $KERO_SHELL_INTEGRATION ]]; then
  unset KERO_SHELL_INTEGRATION
  [[ -o interactive ]] && builtin source ` + shellQuote("zsh", filepath.Join(dir, "zsh", "kero.zsh")) + `
fi
`
	if bin != "" {
		s += strings.ReplaceAll(`__kero_bin_first() {
  path=(BIN ${path:#BIN})
  precmd_functions=(${precmd_functions:#__kero_bin_first})
  unfunction __kero_bin_first
}
precmd_functions+=(__kero_bin_first)
`, "BIN", shellQuote("zsh", bin))
	}
	return s
}

// zshIntegration marks zsh's prompts and commands. D comes first of the
// prompt's hooks, for the status of the command; the prompt takes A and B
// last, over what the other hooks made of it. Hooks keep the status for those
// after them.
const zshIntegration = `# Marks the shell's prompts and commands for Kero (OSC 133).
typeset -g __kero_running=
typeset -g __kero_a=$'%{\e]133;A\a%}' __kero_b=$'%{\e]133;B\a%}'

__kero_precmd() {
  local ret=$?
  if [[ -n $__kero_running ]]; then
    __kero_running=
    builtin print -rn -- $'\e]133;D;'"$ret"$'\a'
  fi
  return $ret
}

__kero_preexec() {
  __kero_running=1
  builtin print -rn -- $'\e]133;C\a'
}

__kero_prompt() {
  local ret=$?
  if [[ -o prompt_percent ]]; then
    PS1=${PS1//$__kero_a/}
    PS1=${PS1//$__kero_b/}
    PS1=$__kero_a$PS1$__kero_b
  fi
  builtin emulate -L zsh
  if [[ ${precmd_functions[1]} != __kero_precmd || ${precmd_functions[-1]} != __kero_prompt ]]; then
    precmd_functions=(__kero_precmd ${precmd_functions:#(__kero_precmd|__kero_prompt)} __kero_prompt)
  fi
  return $ret
}

# The first prompt's hooks are on their way already: this one marks it.
__kero_init() {
  local ret=$?
  builtin emulate -L zsh
  precmd_functions=(__kero_precmd ${precmd_functions:#__kero_init} __kero_prompt)
  preexec_functions+=(__kero_preexec)
  builtin unfunction __kero_init
  builtin unset KERO_ZDOTDIR
  builtin print -rn -- $'\e]133;A\a'
  return $ret
}

typeset -ag precmd_functions preexec_functions
precmd_functions+=(__kero_init)
`

// bashIntegration runs as bash's ENV, in POSIX mode: it takes bash back to its
// usual mode, reads the startup files that mode would have read, and marks the
// prompts and commands. A command's start is PS0 where bash has it (4.4), else
// a DEBUG trap unless the user's startup files set one.
const bashIntegration = `# Marks the shell's prompts and commands for Kero (OSC 133).
if [[ -n ${KERO_BASH_INJECT-} ]]; then
  builtin unset ENV KERO_BASH_INJECT
  if [[ -n ${KERO_BASH_ENV-} ]]; then builtin export ENV=$KERO_BASH_ENV; fi
  builtin unset KERO_BASH_ENV
  builtin set +o posix
  builtin shopt -u inherit_errexit 2>/dev/null
  if [[ -n ${KERO_BASH_UNEXPORT_HISTFILE-} ]]; then
    builtin export -n HISTFILE
    builtin unset KERO_BASH_UNEXPORT_HISTFILE
  fi
  if builtin shopt -q login_shell; then
    [ -r /etc/profile ] && builtin source /etc/profile
    for __kero_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -r "$__kero_rc" ]; then builtin source "$__kero_rc"; break; fi
    done
    builtin unset __kero_rc
  else
    [ -r "$HOME/.bashrc" ] && builtin source "$HOME/.bashrc"
  fi
fi

__kero_boot=
if [[ -n ${KERO_BASH_BOOT-} ]]; then
  # Run from PROMPT_COMMAND, once, after the startup files.
  PROMPT_COMMAND=${PROMPT_COMMAND//"$KERO_BASH_BOOT"/:}
  builtin export -n PROMPT_COMMAND
  builtin unset KERO_BASH_BOOT
  __kero_boot=1
fi

if [[ $- == *i* && -z ${__kero_marks-} ]]; then
  __kero_marks=1
  __kero_a='\[\e]133;A\a\]' __kero_b='\[\e]133;B\a\]' __kero_c='\e]133;C\a'
  __kero_at_prompt=

  __kero_status() {
    local ret=$?
    __kero_at_prompt=
    builtin printf '\e]133;D;%s\a' "$ret"
    return $ret
  }

  __kero_mark() {
    local ret=$?
    case $PS1 in
      *"$__kero_a"*) ;;
      *) PS1=$__kero_a$PS1$__kero_b ;;
    esac
    if ((BASH_VERSINFO[0] > 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)); then
      case ${PS0-} in
        *"$__kero_c"*) ;;
        *) PS0=$__kero_c${PS0-} ;;
      esac
    fi
    __kero_at_prompt=1
    return $ret
  }

  __kero_debug() {
    [[ -n ${__kero_at_prompt-} && -z ${COMP_LINE-} ]] || return 0
    case $BASH_COMMAND in __kero_*) return 0 ;; esac
    __kero_at_prompt=
    builtin printf '\e]133;C\a'
  }

  if ((BASH_VERSINFO[0] < 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4)) && [[ -z $(builtin trap -p DEBUG) ]]; then
    builtin trap '__kero_debug' DEBUG
  fi

  if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
    PROMPT_COMMAND=(__kero_status "${PROMPT_COMMAND[@]}" __kero_mark)
  elif [[ -n ${PROMPT_COMMAND-} ]]; then
    PROMPT_COMMAND=__kero_status$'\n'$PROMPT_COMMAND$'\n'__kero_mark
  else
    PROMPT_COMMAND=__kero_status$'\n'__kero_mark
  fi
fi

# Last: from here the next command is the user's.
if [[ -n $__kero_boot ]]; then
  builtin unset __kero_boot
  __kero_mark
else
  builtin unset __kero_boot
fi
`

// fishIntegration marks fish's prompts and commands, where it doesn't itself.
const fishIntegration = `# Marks the shell's prompts and commands for Kero (OSC 133).
# fish 4 marks them itself.
if status is-interactive; and test (string split -f1 . -- $version) -lt 4
    function __kero_prompt --on-event fish_prompt
        printf '\e]133;A\a'
    end
    function __kero_preexec --on-event fish_preexec
        printf '\e]133;C\a'
    end
    function __kero_postexec --on-event fish_postexec
        printf '\e]133;D;%s\a' $status
    end
end
`
