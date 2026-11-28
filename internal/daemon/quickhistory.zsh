__kero_qh_install() {
  emulate -L zsh
  autoload -Uz add-zle-hook-widget
  typeset -g __kero_qh_open=0 __kero_qh_query= __kero_qh_last= __kero_qh_sel=0
  typeset -g __kero_qh_zebra= __kero_qh_pick_style=standout
  typeset -ga __kero_qh_matches
  typeset -gA __kero_qh_was
  local key w
  for key in '^[[A' '^[OA' '^[[C' '^[OC' '^I'; do
    w=${${(z)"$(bindkey -M main -- $key)"}[2]}
    [[ $w == undefined-key ]] && w=
    __kero_qh_was[$key]=$w
  done
  zle -N __kero_qh_up
  zle -N __kero_qh_down
  zle -N __kero_qh_accept
  zle -N __kero_qh_tab
  zle -N __kero_qh_enter
  zle -N __kero_qh_esc
  zle -N __kero_qh_escape
  bindkey -M main '^[[A' __kero_qh_up '^[OA' __kero_qh_up
  if (( ! ${+functions[_zsh_autosuggest_start]} )); then
    bindkey -M main '^[[C' __kero_qh_accept '^[OC' __kero_qh_accept '^I' __kero_qh_accept
  fi
  add-zle-hook-widget line-init __kero_qh_init
  add-zle-hook-widget line-pre-redraw __kero_qh_redraw
  add-zle-hook-widget line-finish __kero_qh_finish
}
__kero_qh_init() {
  (( __kero_qh_open )) && __kero_qh_close
  __kero_qh_last=
}
__kero_qh_finish() {
  POSTDISPLAY=
  region_highlight=(${region_highlight:#*memo=kero-qh*})
}
__kero_qh_run() {
  local w=${__kero_qh_was[${(V)KEYS}]}
  [[ -n $w ]] && zle $w
}
__kero_qh_filter() {
  emulate -L zsh -o extendedglob
  local -a all=(${(u)history})
  if [[ -n $__kero_qh_query ]]; then
    all=(${(M)all:#(#i)*${(b)__kero_qh_query}*})
  fi
  __kero_qh_matches=(${all[1,200]})
}
__kero_qh_pick() {
  __kero_qh_sel=$1
  if (( __kero_qh_sel )); then
    BUFFER=$__kero_qh_matches[__kero_qh_sel]
  else
    BUFFER=$__kero_qh_query
  fi
  CURSOR=$#BUFFER
  __kero_qh_last=$BUFFER
}
__kero_qh_tone() {
  local -i p=$1 c
  local out=
  for c in $2 $3 $4; do
    if (( $5 )); then c=$(( c + (255 - c) * p / 100 )); else c=$(( c - c * p / 100 )); fi
    out+=${(l:2::0:)$(( [##16] c ))}
  done
  REPLY="bg=#$out"
}
__kero_qh_colors() {
  emulate -L zsh -o extendedglob
  local reply= c
  print -n $'\e]11;?\e\\' > $TTY
  # Not -s: zle has echo off already, and -s leaves the line undrawn.
  while read -t 0.3 -k c; do
    reply+=$c
    [[ $reply == *($'\a'|$'\e\\') ]] && break
  done
  if [[ $reply != *rgb:(#b)([[:xdigit:]](#c2,4))/([[:xdigit:]](#c2,4))/([[:xdigit:]](#c2,4))* ]]; then
    __kero_qh_zebra= __kero_qh_pick_style=standout
    return
  fi
  local -i r=16#${match[1][1,2]} g=16#${match[2][1,2]} b=16#${match[3][1,2]}
  local -i dark=$(( r * 299 + g * 587 + b * 114 < 128000 ))
  __kero_qh_tone 4 $r $g $b $dark; __kero_qh_zebra=$REPLY
  __kero_qh_tone 14 $r $g $b $dark; __kero_qh_pick_style=$REPLY
}
__kero_qh_close() {
  __kero_qh_open=0
  zle -K main
}
__kero_qh_up() {
  if (( __kero_qh_open )); then
    (( __kero_qh_sel < $#__kero_qh_matches )) && __kero_qh_pick $((__kero_qh_sel + 1))
    return
  fi
  if [[ $LBUFFER == *$'\n'* ]]; then
    __kero_qh_run
    return
  fi
  __kero_qh_query=$BUFFER
  __kero_qh_filter
  (( $#__kero_qh_matches )) || return
  __kero_qh_colors
  __kero_qh_open=1
  # Esc alone closes at once: no binding is left that it starts, which
  # zsh would wait for (KEYTIMEOUT); __kero_qh_escape tells the keys that
  # do start with it apart.
  bindkey -D __kero_qh 2>/dev/null
  bindkey -N __kero_qh main
  bindkey -M __kero_qh -rp '^['
  bindkey -M __kero_qh '^[' __kero_qh_escape '^I' __kero_qh_tab '^M' __kero_qh_enter '^J' __kero_qh_enter '^G' __kero_qh_esc
  zle -K __kero_qh
  __kero_qh_pick 1
}
__kero_qh_escape() {
  local k seq=
  if ! read -t 0.02 -k k; then
    __kero_qh_esc
    return
  fi
  seq=$k
  if [[ $k == '[' || $k == O ]]; then
    while read -t 0.02 -k k; do
      seq+=$k
      [[ $k == [[:alpha:]~] ]] && break
    done
  fi
  case $seq in
    '[A'|OA) __kero_qh_up ;;
    '[B'|OB) __kero_qh_down ;;
    *)
      local w=${${(z)"$(bindkey -M main -- "^[${(V)seq}")"}[2]}
      [[ -n $w && $w != undefined-key ]] && zle $w
      ;;
  esac
}
__kero_qh_down() {
  (( __kero_qh_sel )) && __kero_qh_pick $((__kero_qh_sel - 1))
}
__kero_qh_tab() {
  local sel=$__kero_qh_sel
  __kero_qh_close
  (( sel )) || __kero_qh_run
}
__kero_qh_enter() {
  __kero_qh_close
  zle accept-line
}
__kero_qh_esc() {
  __kero_qh_pick 0
  __kero_qh_close
}
__kero_qh_accept() {
  # While the list is open, POSTDISPLAY is the list, not a suggestion.
  if (( ! __kero_qh_open && CURSOR == $#BUFFER )) && [[ -n $POSTDISPLAY ]]; then
    BUFFER+=$POSTDISPLAY
    CURSOR=$#BUFFER
  else
    __kero_qh_run
  fi
}
# __kero_qh_syntax colors the command, in the theme's colors:
# its name green, or underlined when there is no such command, its
# options yellow and its variables magenta.
__kero_qh_syntax() {
  emulate -L zsh -o extendedglob
  [[ $KERO_SYNTAX_HIGHLIGHT == 1 ]] || return
  (( ${+functions[_zsh_highlight]} )) && return
  local rest w style
  local -i at=0 named=0
  while :; do
    rest=${BUFFER:$at}
    w=${rest%%[^[:space:]]*}
    at+=$#w
    w=${${BUFFER:$at}%%[[:space:]]*}
    [[ -n $w ]] || return
    style=
    if (( ! named )) && [[ $w != [[:alpha:]_][[:alnum:]_]#=* ]]; then
      if (( ${+commands[$w]} || ${+functions[$w]} || ${+aliases[$w]} || ${+builtins[$w]} || ${reswords[(Ie)$w]} )) ||
        [[ $w == */* && -x ${~w} ]]; then
        style=fg=green
      else
        style=underline
      fi
      [[ $w == (sudo|doas|nohup|time|env|command|builtin|exec|noglob|nocorrect) ]] || named=1
    elif (( named )) && [[ $w == -* ]]; then
      style=fg=yellow
    elif [[ $w == \$* ]]; then
      style=fg=magenta
    fi
    [[ $w == (\||\|\||\&\&|\;) ]] && named=0
    [[ -n $style ]] && region_highlight+=("$at $(( at + $#w )) $style memo=kero-qh")
    at+=$#w
  done
}
__kero_qh_redraw() {
  emulate -L zsh
  region_highlight=(${region_highlight:#*memo=kero-qh*})
  POSTDISPLAY=
  __kero_qh_syntax
  if (( __kero_qh_open )); then
    if [[ $BUFFER != $__kero_qh_last ]]; then
      __kero_qh_query=$BUFFER __kero_qh_last=$BUFFER __kero_qh_sel=0
      __kero_qh_filter
    fi
    __kero_qh_panel
    return
  fi
  [[ -n $BUFFER && $CURSOR == $#BUFFER && $BUFFER != *$'\n'* ]] || return
  (( ${+functions[_zsh_autosuggest_start]} )) && return
  local s=${history[(r)${(b)BUFFER}?*]}
  [[ -n $s && $s != *$'\n'* ]] || return
  POSTDISPLAY=${s:$#BUFFER}
  region_highlight+=("$#BUFFER $(( $#BUFFER + $#POSTDISPLAY )) fg=8 memo=kero-qh")
}
# __kero_qh_panel lists the matches under the prompt, the oldest at the
# top and the newest at the bottom, as the Up arrow goes back from it, with
# what is typed bold in each.
__kero_qh_panel() {
  local -i n=$#__kero_qh_matches rows=$(( LINES - 5 < 12 ? LINES - 5 : 12 )) width=$(( COLUMNS - 1 ))
  (( rows < 1 )) && rows=1
  (( rows > n )) && rows=n
  local -i first=1
  (( __kero_qh_sel > rows )) && first=$(( __kero_qh_sel - rows + 1 ))
  local out= line part bg before q=${(L)__kero_qh_query}
  local -i i at=$#BUFFER start
  __kero_qh_add() {
    out+=$part
    [[ -n $1 ]] && region_highlight+=("$at $(( at + $#part )) $1 memo=kero-qh")
    at+=$#part
  }
  part=$'\n'; __kero_qh_add
  part=' '; __kero_qh_add
  part=' ↑ '; __kero_qh_add $__kero_qh_pick_style
  part=' '; __kero_qh_add
  part=' ↓ '; __kero_qh_add $__kero_qh_pick_style
  part=' to navigate  '; __kero_qh_add fg=8
  part=' tab '; __kero_qh_add $__kero_qh_pick_style
  part=' to select  '; __kero_qh_add fg=8
  part=' esc '; __kero_qh_add $__kero_qh_pick_style
  part=' to dismiss'; __kero_qh_add fg=8
  part=$'\n'; __kero_qh_add
  for (( i = first + rows - 1; i >= first; i-- )); do
    (( i < first + rows - 1 )) && { part=$'\n'; __kero_qh_add }
    bg=
    if (( i == __kero_qh_sel )); then
      bg=$__kero_qh_pick_style
    elif (( (first + rows - 1 - i) % 2 )); then
      bg=$__kero_qh_zebra
    fi
    part=' >_ '; __kero_qh_add fg=8${bg:+,$bg}
    line=${(V)__kero_qh_matches[i]}
    part=${(mr:width-4:)line}
    start=$at
    __kero_qh_add $bg
    if [[ -n $q ]]; then
      before=${${(L)part}%%${(b)q}*}
      (( $#before < $#part )) &&
        region_highlight+=("$(( start + $#before )) $(( start + $#before + $#q )) bold${bg:+,$bg} memo=kero-qh")
    fi
  done
  (( n )) || { part='  no matching commands'; __kero_qh_add fg=8 }
  POSTDISPLAY=$out
}
