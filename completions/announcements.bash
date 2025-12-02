# Bash completion for the announcements helper

_announcements()
{
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  if [[ $COMP_CWORD -eq 1 ]]; then
    local opts="status start stop restart logs test version summary paths off help"
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
  fi

  return 0
}

complete -F _announcements announcements
