[[ $- == *i* ]] || return

export EDITOR="emacsclient -t"

export LANG=C.utf8
export LC_ALL=C.utf8

alias b="batcat --wrap never"
alias fd="fdfind -H -I"
alias ll='eza -alF'

ec() { emacsclient --create-frame "$@" & exit; }
et() { emacsclient --tty $@; }

# command line interface to voidtools everything
# maps results to wsl paths
# -p - search paths
# -sort date-modified - sensible default
es() {
    USER_HOME=$(wslpath "$(cmd.exe /c "echo %userprofile%" 2>/dev/null | sed 's/\r$//')")
    "$USER_HOME/Downloads/ES-1.1.0.27.x64/es.exe" -p -sort date-modified -instance 1.5a "$@" | sed 's/\r$//' | xargs -n1 -d'\n' wslpath 2>/dev/null
}
# ignore png files by default - for my current use case which is only full-text search they pollute the results
es-no-png() {
    USER_HOME=$(wslpath "$(cmd.exe /c "echo %userprofile%" 2>/dev/null | sed 's/\r$//')")
    "$USER_HOME/Downloads/ES-1.1.0.27.x64/es.exe" -p -sort date-modified -instance 1.5a "$@" | sed 's/\r$//' | grep -v \.png$ | xargs -n1 -d'\n' wslpath 2>/dev/null
}
inkscape-open-all-svg-files-in-current-folder() {
    fd -e svg -x inkscape.exe --app-id-tag a{/} {} & exit
}

copyq.exe() { powershell.exe -Command "& \"\$env:APPDATA\copyq\copyq.exe\" $@ | Write-Output"; }

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
# append to the history file, don't overwrite it
shopt -s histappend
# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=-1
HISTFILESIZE=-1

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
    exec -a _PASS_AUTOCLOSE_TIMER_ bash -c 'sleep 300; command pass close > /dev/null 2>&1' & disown
  fi
}
