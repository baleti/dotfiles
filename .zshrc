# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Enable colors and change prompt:
autoload -U colors && colors

# PROMPT='%~ > '
PROMPT='%F{245}%~%f %F{38}$%f '
# show time on the right
# RPROMPT='%*'

# History in cache directory:
HISTSIZE=99999999
SAVEHIST=$HISTSIZE
HISTFILE="$HOME/.zsh_history"

# delimits words
WORDCHARS='*?[]~&;!#$%^(){}<>,|=+'

setopt auto_pushd
autoload -Uz compinit

# toggle if fzf-tab lists prefixes look weird
zstyle ':completion:*' menu select
#zstyle ':completion:*' menu no

# Auto complete with case insenstivity
zstyle ':completion:*' matcher-list '' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'

zmodload zsh/complist
compinit
_comp_options+=(globdots)		# Include hidden files.

# remove duplicates in zsh_history
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
# setopt HIST_IGNORE_SPACE
setopt HIST_FIND_NO_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS

setopt glob_dots
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY

# inline comments
setopt interactive_comments

# Use vim keys in tab complete menu:
bindkey -M menuselect 'h' vi-backward-char
bindkey -M menuselect 'j' vi-down-line-or-history
bindkey -M menuselect 'k' vi-up-line-or-history
bindkey -M menuselect 'l' vi-forward-char
bindkey -M menuselect 'left' vi-backward-char
bindkey -M menuselect 'down' vi-down-line-or-history
bindkey -M menuselect 'up' vi-up-line-or-history
bindkey -M menuselect 'right' vi-forward-char

export PATH="$HOME/.config/emacs/bin:$PATH"
export GPG_AGENT_SOCK="$HOME/.gnupg/S.gpg-agent"
export SSH_AUTH_SOCK="$HOME/.gnupg/S.gpg-agent.ssh"
export EDITOR="emacsclient -t"

source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/doc/fzf/examples/key-bindings.zsh
source "$HOME/src/fzf-tab/fzf-tab.plugin.zsh"

alias b="batcat --wrap never"
alias fd='fd -H -I'
alias ll='eza -lah'
alias fd="fdfind -H -I"

e(){ (emacsclient --create-frame $@ &) }
ec(){ (emacsclient --create-frame $@ &); exit }
et(){ emacsclient --tty $@ }

copyq.exe(){ powershell.exe -Command "& \"\$env:APPDATA\copyq\copyq.exe\" $@ | Write-Output" }

# preview directory's content with eza when completing cd
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
# set integrated fzf zsh completion options
# --height use full screen height
# --no-preview don't display contents of directories, seems too distracting
zstyle ':fzf-tab:*' fzf-flags --height=100% --no-preview

autoload -Uz chpwd_recent_dirs cdr add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs

# 20 by default, 0 makes it infinite
zstyle ':chpwd:*' recent-dirs-max 0

# bind alt r to list recent directories
function _cdr_completion() {
  local choice=$(cdr -l | fzf)
  local number=$(echo "$choice" | awk '{print $1}')
  BUFFER="cdr $number"
  zle accept-line
}
zle -N _cdr_completion
bindkey '^[r' _cdr_completion

# bind alt left and alt right to cd to previous and next directories
CURRENT_DIR_INDEX=2

function load_recent_dirs() {
  RECENT_DIRS=("${(@f)$(<~/.chpwd-recent-dirs)}")
}
function _cd_prev_dir() {
  load_recent_dirs
  # Skip the current directory by starting at the previous one
  if (( CURRENT_DIR_INDEX < ${#RECENT_DIRS[@]} - 1 )); then
    ((CURRENT_DIR_INDEX++))
    # Check if we are trying to switch to the current directory; if so, go one more
    if [[ "${RECENT_DIRS[CURRENT_DIR_INDEX]}" == "$PWD" ]]; then
      ((CURRENT_DIR_INDEX++))
    fi
    cd ${(Q)RECENT_DIRS[CURRENT_DIR_INDEX]}
    zle reset-prompt
  fi
}

function _cd_next_dir() {
  load_recent_dirs
  # Skip the current directory by starting at the next recent one
  if (( CURRENT_DIR_INDEX > 0 )); then
    ((CURRENT_DIR_INDEX--))
    # Check if we are trying to switch to the current directory; if so, go one more back
    if [[ "${RECENT_DIRS[CURRENT_DIR_INDEX]}" == "$PWD" ]]; then
      ((CURRENT_DIR_INDEX--))
    fi
    cd ${(Q)RECENT_DIRS[CURRENT_DIR_INDEX]}
    zle reset-prompt
  fi
}

zle -N _cd_prev_dir
zle -N _cd_next_dir

bindkey '^[[1;3C' _cd_next_dir
bindkey '^[[1;3D' _cd_prev_dir
#bindkey '^[r' _cd_prev_dir
#bindkey '^[g' _cd_next_dir

# alt up arrow to move up directory
cd_up() { 
  cd ..
  zle reset-prompt
}
zle -N cd_up
bindkey '^[[1;3A' cd_up

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

bindkey '^[[1;5D' emacs-backward-word  # Ctrl + Left Arrow
bindkey '^[[1;5C' emacs-forward-word   # Ctrl + Right Arrow

# bindings to ctrl shift arrow keys and ctrl alt backspace
source $HOME/.config/zsh/motions.zsh

bindkey '^Z' undo
bindkey '^Y' redo
