export GPG_AGENT_SOCK="$HOME/.gnupg/S.gpg-agent"
export SSH_AUTH_SOCK="$HOME/.gnupg/S.gpg-agent.ssh"
export EDITOR="emacsclient -t"

# set locale
export LANG=C.utf8
export LC_ALL=C.utf8

alias b="batcat --wrap never"
alias fd="fdfind -H -I"
alias ll='eza -alF'

ec() { emacsclient --create-frame "$@" & exit; }
e() { emacsclient --create-frame "$@" & }
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

# If not running interactively, don't do anything
[[ $- == *i* ]] || return

# don't put duplicate lines or lines starting with space in the history.
HISTCONTROL=ignoreboth
# append to the history file, don't overwrite it
shopt -s histappend
# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=-1
HISTFILESIZE=-1

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='\[\033[01;34m\]$PWD\[\033[00m\] > '
else
    PS1='$PWD > '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

source /usr/share/doc/fzf/examples/key-bindings.bash
source $HOME/bin/fzf-tab-completion-bash.sh
bind -x '"\t": fzf_bash_completion'

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi
. "$HOME/.cargo/env"
