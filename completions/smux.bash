# bash completion for smux

_smux_timeout() {
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout 2s "$@" 2>/dev/null
  elif command -v timeout >/dev/null 2>&1; then
    timeout 2s "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

_smux_sessions() {
  command -v tmux >/dev/null 2>&1 || return 0
  _smux_timeout tmux list-sessions -F '#{session_name}' | awk 'NF' | sort -u
}

_smux_complete() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local commands="install update uninstall remove init start stop attach status doctor version help"

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return 0
  fi

  cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    init)
      COMPREPLY=( $(compgen -W "--force" -- "$cur") )
      ;;
    update)
      COMPREPLY=( $(compgen -W "--check --dry-run" -- "$cur") )
      ;;
    start)
      if [[ "$prev" == "-n" ]]; then
        return 0
      fi
      COMPREPLY=( $(compgen -W "-n -d --replace --dry-run --preview" -- "$cur") )
      ;;
    stop|attach)
      if [[ "$prev" == "-n" ]]; then
        COMPREPLY=( $(compgen -W "$(_smux_sessions)" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "-n" -- "$cur") )
      fi
      ;;
    status)
      COMPREPLY=( $(compgen -W "--agents" -- "$cur") )
      ;;
    flow)
      COMPREPLY=( $(compgen -W "start status reset" -- "$cur") )
      ;;
  esac
}

complete -F _smux_complete smux
