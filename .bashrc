[[ $- == *i* ]] || return

export EDITOR="emacsclient -t"

export LANG=C.utf8
export LC_ALL=C.utf8

alias b="batcat --wrap never"
alias fd="fdfind -H -I"
alias ll='eza -alF'

ec() {
	emacsclient --create-frame "$@" &
	exit
}
et() { emacsclient --tty $@; }

# Auto-start tmux if not already running in a tmux session
if [ -z "$TMUX" ]; then
	# Create a unique session name based on the terminal process ID
	SESSION_NAME="auto-$(basename "$SHELL")-$$"

	# Check if a tmux session with this name already exists
	tmux has-session -t "$SESSION_NAME" 2>/dev/null

	if [ $? != 0 ]; then
		# If the session does not exist, create a new one
		tmux new-session -s "$SESSION_NAME"
	else
		# If it exists, attach to the existing session
		tmux attach-session -t "$SESSION_NAME"
	fi

	# Exit the shell when tmux exits
	exit
fi

HISTCONTROL=ignoreboth
HISTSIZE=-1
HISTFILESIZE=-1

# append to the history file, don't overwrite it
shopt -s histappend
# immediately append command to history file after it run
# https://askubuntu.com/questions/67283/is-it-possible-to-make-writing-to-bash-history-immediate
PROMPT_COMMAND="history -a;$PROMPT_COMMAND"

PS1='\[\033[01;34m\]$PWD\[\033[00m\] > '

source /usr/share/doc/fzf/examples/key-bindings.bash
bind -x '"\t": fzf_bash_completion'

source /usr/share/bash-completion/bash_completion

# auto close pass coffin after 5 minutes, no systemd timers
# tag via argv[0] so a later `pass open` can find and kill any timer
# still running from a previous call, then start a fresh 300s countdown
pass() {
	command pass "$@"
	if [[ "$1" == "open" && "$#" -eq 1 ]]; then
		pkill -f '_PASS_AUTOCLOSE_TIMER_' 2>/dev/null
		exec -a _PASS_AUTOCLOSE_TIMER_ bash -c 'sleep 300; command pass close > /dev/null 2>&1' &
		disown
	fi
}
