[[ $- == *i* ]] || return

export EDITOR="emacsclient -t"
et() { emacsclient --tty $@; }

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
