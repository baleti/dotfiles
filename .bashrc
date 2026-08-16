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
