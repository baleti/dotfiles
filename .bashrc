[[ $- == *i* ]] || return

HISTCONTROL=ignoreboth
HISTSIZE=-1
HISTFILESIZE=-1
shopt -s histappend

PS1='\h:\w $ '

source /usr/share/bash-completion/bash_completion

export GPG_TTY=$(tty)
export EDITOR=/usr/bin/vi
alias ls="/usr/bin/eza"
alias ll="/usr/bin/eza -alF"
alias fd="/usr/bin/fdfind -H -I"
alias b="/usr/bin/batcat --wrap never"
shopt -s histappend
PROMPT_COMMAND="history -a;$PROMPT_COMMAND"
source /usr/share/doc/fzf/examples/key-bindings.bash

# auto close pass coffin after 5 minutes, no systemd timers
# tag via argv[0] so a later `pass open` can find and kill any timer
# still running from a previous call, then start a fresh 300s countdown
pass() {
  command pass "$@"
  if [[ "$1" == "open" && "$#" -eq 1 ]]; then
    pkill -f '_PASS_AUTOCLOSE_TIMER_' 2>/dev/null
    ( exec -a _PASS_AUTOCLOSE_TIMER_ bash -c 'sleep 300; command pass close' </dev/null >/dev/null 2>&1 & )
  fi
}

# wraps git network and signing commands push/fetch/pull (auth) and commit/merge/tag/rebase (signing)
# opens password store and loads the right SSH key for current repo using custom ssh-agent
git() {
  local class toplevel entry key

  case "$1" in
    push|fetch|pull)         class=net ;;
    commit|merge|tag|rebase) class=sign ;;
    *) command git "$@"; return ;; # any other git subcommand
  esac

  toplevel=$(command git rev-parse --show-toplevel 2>/dev/null)
  [[ -z "$toplevel" ]] && { command git "$@"; return; }  # no .git

  local -A ssh_key_map=(
    ["$HOME|sign"]=github-dotfiles-sign
    ["$HOME|net"]=github-dotfiles-auth
    ["$HOME/qemu|sign"]=github-qemu-sign
    ["$HOME/qemu|net"]=github-qemu-auth
  )

  key="$toplevel|$class"
  entry=${ssh_key_map[$key]:-}
  [[ -z "$entry" ]] && { command git "$@"; return; }

  echo "+ pass close && pass open; eval \$(~/bin/ssh-agent); ssh-add <(pass $entry); git $*" >&2
  pass close; pass open
  eval "$(~/bin/ssh-agent)" >/dev/null
  ssh-add -q <(pass "$entry")
  command git "$@"
}
