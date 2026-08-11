# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Enable colors and change prompt:
autoload -U colors && colors

PROMPT='%F{245}%~%f %F{38}$%f '

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

alias b="bat --wrap never"
alias ll='eza -lah'
alias fd="fd -H -I"

et(){ emacsclient --tty $@ }

source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh 2>/dev/null
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh 2>/dev/null
source /usr/share/fzf/key-bindings.zsh
source /usr/share/zsh/plugins/fzf-tab-git/fzf-tab.plugin.zsh 2>/dev/null

# sorts 3330 before 3330A
export LC_COLLATE=C

# bindings to ctrl shift arrow keys and ctrl alt backspace
source $HOME/.config/zsh/motions.zsh

[[ -z $TMUX ]] && tmux new-session && exit

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

autoload -Uz add-zsh-hook
zmodload zsh/datetime 2>/dev/null

# unified chronological cd history, mirroring how .zsh_history works with
# SHARE_HISTORY + INC_APPEND_HISTORY: one shared append-only file, tagged
# with which shell wrote each line so entries can be told apart, that every
# shell reads in full on startup and then keeps merging into live (checked
# once per prompt, same timing zsh uses to import shared command history).
# Both alt+r (fuzzy-pick any past directory) and alt+left/right (per-shell
# back/forward stack) read from this same file, so they stay in sync instead
# of being two disconnected mechanisms.
typeset -g _DIR_HISTORY_FILE="$HOME/.zsh_dir_history"
typeset -g _DIR_HISTORY_SESSION_ID="${TTY:t}-$$"
typeset -g _DIR_HISTORY_NAVIGATING=0
typeset -g _DIR_HISTORY_LINES=0

typeset -ga _DIR_HISTORY_BACK
typeset -ga _DIR_HISTORY_FORWARD

if [[ -f $_DIR_HISTORY_FILE ]]; then
  _DIR_HISTORY_LINES=$(wc -l < $_DIR_HISTORY_FILE)
  _DIR_HISTORY_BACK=("${(@f)$(cut -f3 $_DIR_HISTORY_FILE)}")
fi

function _dir_history_append() {
  printf '%s\t%s\t%s\n' "$EPOCHSECONDS" "$_DIR_HISTORY_SESSION_ID" "$1" >> $_DIR_HISTORY_FILE
  (( _DIR_HISTORY_LINES++ ))
}

# pull in lines appended by other shells since we last looked
function _dir_history_sync() {
  [[ -f $_DIR_HISTORY_FILE ]] || return
  local total=$(wc -l < $_DIR_HISTORY_FILE)
  (( total <= _DIR_HISTORY_LINES )) && return
  local line path
  for line in "${(@f)$(tail -n +$((_DIR_HISTORY_LINES + 1)) $_DIR_HISTORY_FILE)}"; do
    path="${line##*$'\t'}"
    [[ -n "$path" ]] && _DIR_HISTORY_BACK+=("$path")
  done
  _DIR_HISTORY_LINES=$total
}
add-zsh-hook precmd _dir_history_sync

function _dir_history_chpwd() {
  (( _DIR_HISTORY_NAVIGATING )) && return
  if [[ -n "$OLDPWD" ]]; then
    _DIR_HISTORY_BACK+=("$OLDPWD")
    _dir_history_append "$OLDPWD"
  fi
  _DIR_HISTORY_FORWARD=()
}
add-zsh-hook chpwd _dir_history_chpwd

function _cd_prev_dir() {
  local target
  while (( ${#_DIR_HISTORY_BACK} )); do
    target=${_DIR_HISTORY_BACK[-1]}
    _DIR_HISTORY_BACK[-1]=()
    # skip entries that are the dir we're already in, or that no longer
    # exist (history spans deleted temp dirs, unmounted crypt volumes, etc.)
    [[ $target == $PWD || ! -d $target ]] && continue
    _DIR_HISTORY_FORWARD+=("$PWD")
    _DIR_HISTORY_NAVIGATING=1
    cd $target
    _DIR_HISTORY_NAVIGATING=0
    break
  done
  zle reset-prompt
}

function _cd_next_dir() {
  local target
  while (( ${#_DIR_HISTORY_FORWARD} )); do
    target=${_DIR_HISTORY_FORWARD[-1]}
    _DIR_HISTORY_FORWARD[-1]=()
    [[ $target == $PWD || ! -d $target ]] && continue
    _DIR_HISTORY_BACK+=("$PWD")
    _DIR_HISTORY_NAVIGATING=1
    cd $target
    _DIR_HISTORY_NAVIGATING=0
    break
  done
  zle reset-prompt
}

zle -N _cd_prev_dir
zle -N _cd_next_dir

bindkey '^[[1;3C' _cd_next_dir
bindkey '^[[1;3D' _cd_prev_dir

# bind alt r to fuzzy-pick any directory ever visited (any shell), most
# recent visit of each directory first
function _cdr_completion() {
  [[ -f $_DIR_HISTORY_FILE ]] || { zle reset-prompt; return }
  local choice
  choice=$(awk -F'\t' '{ d[$3]=NR } END { for (p in d) print d[p], p }' $_DIR_HISTORY_FILE \
    | sort -rn | cut -d' ' -f2- | fzf)
  if [[ -z "$choice" ]]; then
    zle reset-prompt
    return
  fi
  BUFFER="cd ${(qq)choice}"
  zle accept-line
}
zle -N _cdr_completion
bindkey '^[r' _cdr_completion

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
    ["$HOME/revit-ballet|net"]=baleti-github-ssh-key
    ["$HOME/bin|net"]=baleti-github-ssh-key
    ["$HOME|net"]=baleti-github-ssh-key
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
