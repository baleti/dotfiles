# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Enable colors and change prompt:
autoload -U colors && colors

PROMPT='%F{245}%m:%~%f %F{38}$%f '

# History in cache directory:
HISTSIZE=99999999
SAVEHIST=$HISTSIZE
HISTFILE="$HOME/.zsh_history"

# delimits words
WORDCHARS='*?[]~&;!#$%^(){}<>,|=+'

setopt auto_pushd
autoload -Uz compinit

zstyle ':completion:*' menu select

# Auto complete with case insenstivity
zstyle ':completion:*' matcher-list '' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'

zmodload zsh/complist
compinit
_comp_options+=(globdots)		# Include hidden files.

# remove duplicates in zsh_history
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS

setopt glob_dots
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY

# inline comments
setopt interactive_comments

export PATH="$HOME/.config/emacs/bin:$PATH"
export EDITOR="emacsclient -t"

alias b="batcat --wrap never"
alias ll='eza -lah'
alias fd="fdfind -H -I"

et(){ emacsclient --tty $@ }

source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/doc/fzf/examples/key-bindings.zsh

# sorts 3330 before 3330A
export LC_COLLATE=C

# bindings to ctrl shift arrow keys and ctrl alt backspace
source $HOME/.config/zsh/motions.zsh

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

# self-healing fzf-tab checkout: clone on first run (e.g. fresh machine),
# keep it updated in the background so shell startup never blocks on git
FZF_TAB_DIR="$HOME/.config/zsh/plugins/fzf-tab"
FZF_TAB_PLUGIN="$FZF_TAB_DIR/fzf-tab.plugin.zsh"

[[ -f $FZF_TAB_PLUGIN ]] || git clone --quiet --depth 1 https://github.com/Aloxaf/fzf-tab "$FZF_TAB_DIR"

if [[ -f $FZF_TAB_PLUGIN ]]; then
  source "$FZF_TAB_PLUGIN"

  zmodload -F zsh/stat b:zstat
  zmodload -F zsh/datetime p:EPOCHSECONDS

  fetch_head="$FZF_TAB_DIR/.git/FETCH_HEAD"
  fetch_mtime=0
  zstat -A fetch_mtime +mtime "$fetch_head" 2>/dev/null

  # update at most once every 3 days; touch FETCH_HEAD first so concurrent
  # shells started in the same window don't all race to spawn a pull
  if (( fetch_mtime[1] < EPOCHSECONDS - 3 * 24 * 60 * 60 )); then
    touch "$fetch_head" 2>/dev/null
    ( cd "$FZF_TAB_DIR" && git pull --quiet ) &>/dev/null &!
  fi
  unset fetch_head fetch_mtime
fi
unset FZF_TAB_DIR FZF_TAB_PLUGIN

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

# alt up arrow to move up directory
cd_up() { 
  cd ..
  zle reset-prompt
}
zle -N cd_up
bindkey '^[[1;3A' cd_up

bindkey '^[[1;5D' emacs-backward-word  # Ctrl + Left Arrow
bindkey '^[[1;5C' emacs-forward-word   # Ctrl + Right Arrow

bindkey '^Z' undo
bindkey '^Y' redo

# use alternate buffer for fzf fuzzy search of past commands
# by default ctrl+r binding provided with fzf shows results in the same buffer
# prevents bug when results don't get cleared up if called from the top
_fzf_history_widget_wrapper() {
    local row
    exec {tty}<>/dev/tty
    printf '\e[6n' >&$tty
    IFS='[;' read -rs -d'R' _ row _ <&$tty
    exec {tty}<&-

    if (( row <= LINES / 3 )); then
        FZF_CTRL_R_OPTS='--tmux top,60%'
    elif (( row >= LINES * 2 / 3 )); then
        FZF_CTRL_R_OPTS='--tmux bottom,60%'
    else
        FZF_CTRL_R_OPTS='--tmux center,100%,60%'
    fi

    fzf-history-widget
}
zle -N _fzf_history_widget_wrapper
bindkey '^R' _fzf_history_widget_wrapper
