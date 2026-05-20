# bash completion for tmux-bridge

_tmux_bridge_timeout() {
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout 2s "$@" 2>/dev/null
  elif command -v timeout >/dev/null 2>&1; then
    timeout 2s "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

_tmux_bridge_targets() {
  command -v tmux >/dev/null 2>&1 || return 0
  _tmux_bridge_timeout tmux list-panes -a -F '#{pane_id} #{@name}' \
    | awk '{ print $1; if ($2 != "") print $2 }' \
    | sort -u
}

_tmux_bridge_keys() {
  printf '%s\n' \
    Enter Escape Space Tab BSpace Delete Home End Insert \
    Up Down Left Right PPage NPage \
    C-a C-b C-c C-d C-e C-f C-g C-h C-j C-k C-l C-m C-n C-o C-p C-q C-r C-s C-t C-u C-v C-w C-x C-y C-z
}

_tmux_bridge_complete() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local commands="list type message msg file read keys name resolve id doctor version help"

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return 0
  fi

  cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    type|message|msg|file|read|keys|name)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=( $(compgen -W "$(_tmux_bridge_targets)" -- "$cur") )
      elif [[ "$cmd" == "keys" ]]; then
        COMPREPLY=( $(compgen -W "$(_tmux_bridge_keys)" -- "$cur") )
      elif [[ "$prev" != "--" && ( "$cmd" == "type" || "$cmd" == "message" || "$cmd" == "msg" ) ]]; then
        COMPREPLY=( $(compgen -W "--stdin --base64 --" -- "$cur") )
      elif [[ "$prev" != "--" && "$cmd" == "file" ]]; then
        COMPREPLY=( $(compgen -W "--stdin --name --max-bytes --max-lines --" -- "$cur") )
      fi
      ;;
    resolve)
      COMPREPLY=( $(compgen -W "$(_tmux_bridge_targets)" -- "$cur") )
      ;;
  esac
}

complete -F _tmux_bridge_complete tmux-bridge
