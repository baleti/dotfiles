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

# M-x normally runs execute-named-cmd, which prompts for a widget name via
# plain `read` rather than the completion system, so fzf-tab can't hook it.
# Replace it with a widget that fuzzy-picks from `zle -la` via fzf instead,
# with most-recently-used widgets listed first (zsh doesn't track this itself).
typeset -g _FZF_WIDGET_HISTORY_FILE="$HOME/.zsh_widget_history"
typeset -ga _FZF_WIDGET_HISTORY
[[ -s $_FZF_WIDGET_HISTORY_FILE ]] && _FZF_WIDGET_HISTORY=("${(@f)$(<$_FZF_WIDGET_HISTORY_FILE)}")

fzf-execute-widget() {
  local widget
  local -a all_widgets ordered
  all_widgets=(${(f)"$(zle -la)"})
  # known-recent widgets first (in recency order), then the rest alphabetically
  ordered=(${(M)_FZF_WIDGET_HISTORY:*all_widgets} ${all_widgets:|_FZF_WIDGET_HISTORY})
  widget=$(printf '%s\n' "${ordered[@]}" | fzf --tmux "$(_fzf_tmux_popup_opt)" --prompt="widget> ") || { zle redisplay; return 1 }
  zle "$widget"

  _FZF_WIDGET_HISTORY=($widget ${_FZF_WIDGET_HISTORY:#$widget})
  (( ${#_FZF_WIDGET_HISTORY} > 50 )) && _FZF_WIDGET_HISTORY=(${_FZF_WIDGET_HISTORY[1,50]})
  printf '%s\n' "${_FZF_WIDGET_HISTORY[@]}" > $_FZF_WIDGET_HISTORY_FILE
}
zle -N fzf-execute-widget
bindkey '\ex' fzf-execute-widget

autoload -Uz chpwd_recent_dirs cdr add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs

# 20 by default, 0 makes it infinite
zstyle ':chpwd:*' recent-dirs-max 0

# bind alt r to list recent directories
function _cdr_completion() {
  local choice=$(cdr -l | fzf)
  if [[ -z "$choice" ]]; then
    zle reset-prompt
    return
  fi
  local number=$(echo "$choice" | awk '{print $1}')
  BUFFER="cdr $number"
  zle accept-line
}
zle -N _cdr_completion
bindkey '^[r' _cdr_completion

# bind alt left and alt right to cd to previous and next directories,
# like browser back/forward. Kept as an explicit stack rather than reusing
# the chpwd_recent_dirs list, since that list gets reordered on every cd
# (including the ones these functions issue), which makes an index into it
# drift from the directory the user actually just left. Persisted to disk
# (like ~/.chpwd-recent-dirs) so the history survives shell restarts.
typeset -g _DIR_HISTORY_BACK_FILE="$HOME/.zsh_dir_history_back"
typeset -g _DIR_HISTORY_FORWARD_FILE="$HOME/.zsh_dir_history_forward"

typeset -ga _DIR_HISTORY_BACK
typeset -ga _DIR_HISTORY_FORWARD
typeset -g _DIR_HISTORY_NAVIGATING=0

[[ -s $_DIR_HISTORY_BACK_FILE ]] && _DIR_HISTORY_BACK=("${(@f)$(<$_DIR_HISTORY_BACK_FILE)}")
[[ -s $_DIR_HISTORY_FORWARD_FILE ]] && _DIR_HISTORY_FORWARD=("${(@f)$(<$_DIR_HISTORY_FORWARD_FILE)}")

function _dir_history_save() {
  printf '%s\n' "${_DIR_HISTORY_BACK[@]}" > $_DIR_HISTORY_BACK_FILE
  printf '%s\n' "${_DIR_HISTORY_FORWARD[@]}" > $_DIR_HISTORY_FORWARD_FILE
}

function _dir_history_chpwd() {
  (( _DIR_HISTORY_NAVIGATING )) && return
  [[ -n "$OLDPWD" ]] && _DIR_HISTORY_BACK+=("$OLDPWD")
  _DIR_HISTORY_FORWARD=()
  _dir_history_save
}
add-zsh-hook chpwd _dir_history_chpwd

function _cd_prev_dir() {
  (( ${#_DIR_HISTORY_BACK} == 0 )) && return
  _DIR_HISTORY_FORWARD+=("$PWD")
  local target=${_DIR_HISTORY_BACK[-1]}
  _DIR_HISTORY_BACK[-1]=()
  _DIR_HISTORY_NAVIGATING=1
  cd ${(Q)target}
  _DIR_HISTORY_NAVIGATING=0
  _dir_history_save
  zle reset-prompt
}

function _cd_next_dir() {
  (( ${#_DIR_HISTORY_FORWARD} == 0 )) && return
  _DIR_HISTORY_BACK+=("$PWD")
  local target=${_DIR_HISTORY_FORWARD[-1]}
  _DIR_HISTORY_FORWARD[-1]=()
  _DIR_HISTORY_NAVIGATING=1
  cd ${(Q)target}
  _DIR_HISTORY_NAVIGATING=0
  _dir_history_save
  zle reset-prompt
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

# popup fzf in a tmux floating pane near the cursor, rather than inline in
# the terminal buffer, so results don't get left behind when called from
# the top of the screen
_fzf_tmux_popup_opt() {
    local row
    exec {tty}<>/dev/tty
    printf '\e[6n' >&$tty
    IFS='[;' read -rs -d'R' _ row _ <&$tty
    exec {tty}<&-

    if (( row <= LINES / 3 )); then
        echo 'top,60%'
    elif (( row >= LINES * 2 / 3 )); then
        echo 'bottom,60%'
    else
        echo 'center,100%,60%'
    fi
}

# use alternate buffer for fzf fuzzy search of past commands
# by default ctrl+r binding provided with fzf shows results in the same buffer
# prevents bug when results don't get cleared up if called from the top
_fzf_history_widget_wrapper() {
    FZF_CTRL_R_OPTS="--tmux $(_fzf_tmux_popup_opt)"
    fzf-history-widget
}
zle -N _fzf_history_widget_wrapper
bindkey '^R' _fzf_history_widget_wrapper
