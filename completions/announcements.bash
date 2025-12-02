# Bash completion for the announcements helper

_announcements()
{
  local cur
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  # top-level commands
  if [[ $COMP_CWORD -eq 1 ]]; then
    local opts="config help logs off paths services smb start status stop restart test version"
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
  fi

  return 0
}

complete -F _announcements announcements
