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
HISTFILE=/home/user1/.zsh_history

# delimits words
WORDCHARS='*?[]~&;!#$%^(){}<>,|=+'

# change location of .zcompdump
export ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/.zcompdump-${ZSH_VERSION}"

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

# Edit line in buffer ctrl-v
# autoload -z edit-command-line
# zle -N edit-command-line
# bindkey '^v' edit-command-line

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

export GPG_TTY=$TTY
# export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.config/emacs/bin:$PATH"
export EDITOR="emacsclient --create-frame"
export XDG_CURRENT_DESKTOP=KDE
# use gpg-agent emulation of ssh-agent
export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh 2>/dev/null
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh 2>/dev/null
source /usr/share/fzf/key-bindings.zsh
source /usr/share/zsh/plugins/fzf-tab-git/fzf-tab.plugin.zsh 2>/dev/null

alias b="bat --wrap never"
alias fd='fd -H -I'
alias ll='eza -lah'
alias l='eza -lh'
alias ls='eza'
alias o=xdg-open
alias winepath='winepath 2>/dev/null'

# overwrite pass coffin open command to close after 1 minute by default
# https://superuser.com/questions/105375/how-to-use-spaces-in-a-bash-alias-name
pass() {
  if [[ $@ == "open" ]] && [[ "$#" -eq 1 ]]; then
    command pass open -t 1min
  else
    command pass "$@"
  fi
}

e(){ (emacsclient --create-frame $@ &) }
ec(){ (emacsclient --create-frame $@ && exit) }
et(){ (emacsclient --tty $@) }

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

export LIBVIRT_DEFAULT_URI='qemu:///system'

[[ -z $TMUX ]] && tmux new-session && exit

bindkey '^[[1;5D' emacs-backward-word  # Ctrl + Left Arrow
bindkey '^[[1;5C' emacs-forward-word   # Ctrl + Right Arrow

# bindings to ctrl shift arrow keys and ctrl alt backspace
source $HOME/.config/zsh/motions.zsh

bindkey '^Z' undo
bindkey '^Y' redo

# https://www.reddit.com/r/zsh/comments/12ft7om/conditional_rewriting_parts_of_the_command_line/
# https://linux.die.net/man/1/zshexpn
rclone-path-convert(){
    # split buffer using "shell semantics" (quotes will be recognized)
    local words=(${(z)BUFFER})
    local newwords=()
    # (Q) - Remove one level of quotes from the resulting words.
    for word ( ${(Q)words} ) {
        if [[ ! -e $word ]] {
            newwords+=($word)
            continue
        }
        rclone_fs_name=$(df "$word" | sed 1d | awk '{print $1}')
        rclone_mount_path=$(df "$word" | sed 1d | awk '{print $NF}')
        rclone_rel_path=${"$(readlink -f $word)"#$rclone_mount_path}
        newwords+=\'$rclone_fs_name$rclone_rel_path\'
    }
    # join array with " " whitespace character
    BUFFER=${(j: :)newwords}
    CURSOR=$#BUFFER
}
zle -N rclone-path-convert

rclone-path-variable(){
    # split buffer using "shell semantics" (quotes will be recognized)
    local words=(${(z)BUFFER})
    local newwords=()
    # (Q) - Remove one level of quotes from the resulting words.
    for word ( ${(Q)words} ) {
        if [[ ! -e $word ]] {
            newwords+=($word)
            continue
        }
        rclone_fs_name=$(df "$word" | sed 1d | awk '{print $1}')
        mountpoint=$(df "$word" | sed 1d | awk '{print $NF}')
        # / slash at the end removes it from the beginning of rclone_rel_path
        rclone_rel_path=${"$(readlink -f $word)"#$mountpoint/}
        newwords+=$rclone_fs_name\$rclone_rel_path
    }
    # join array with " " whitespace character
    BUFFER='rclone_rel_path='\'$rclone_rel_path\''; '${(j: :)newwords}
    CURSOR=$#BUFFER
}
zle -N rclone-path-variable

rclone-crypt-path-variable(){
    # split buffer using "shell semantics" (quotes will be recognized)
    local words=(${(z)BUFFER})
    local newwords=()
    # (Q) - Remove one level of quotes from the resulting words.
    for word ( ${(Q)words} ) {
        if [[ ! -e $word ]] {
            newwords+=($word)
            continue
        }
        rclone_fs_name=$(df "$word" | sed 1d | awk '{print $1}')
        rclone_fs_mountpoint=$(df "$word" | sed 1d | awk '{print $NF}')
        # / slash at the end removes it from the beginning of rclone_rel_path
        rclone_rel_path=${"$(readlink -f $word)"#$rclone_fs_mountpoint/}

        # this assumes that you are using rclone config in default location
        # tests is file belongs to a crypt or union type of remote
        rclone_remote_type=$(awk '/^\['${rclone_fs_name%:}'\]/{f=1} f==1&&/^type/{print $3;exit}' ~/.config/rclone/rclone.conf)
        if [[ $rclone_remote_type == "union" ]]; then
          # this always reads the first remote in "upstreams" entry
          # it should check if file belongs to that remote instead
          rclone_remote=$(awk '/^\['${rclone_fs_name%:}'\]/{f=1} f==1&&/^upstreams/{print $3;exit}' ~/.config/rclone/rclone.conf)
        elif [[ $rclone_remote_type == "crypt" ]]; then
          rclone_remote=$rclone_fs_name
        else
          continue
        fi

        rclone_rel_path_crypt=$(rclone cryptdecode --reverse $rclone_remote $rclone_rel_path | awk '{print $NF}')
        newwords+='gdrive:crypt/'\$rclone_rel_path_crypt
    }
    # join array with " " whitespace character
    BUFFER='rclone_rel_path_crypt='\'$rclone_rel_path_crypt\''; '${(j: :)newwords}
    CURSOR=$#BUFFER
}
zle -N rclone-crypt-path-variable

rclone-restore-aws-crypt(){
    local words=(${(z)BUFFER})
    local newwords=()
    for word ( ${(Q)words} ) {
        if [[ ! -e $word ]] {
            newwords+=($word)
            continue
        }
        rclone_fs_name=$(df "$word" | sed 1d | awk '{print $1}')
        rclone_fs_mountpoint=$(df "$word" | sed 1d | awk '{print $NF}')
        # / slash at the end removes it from the beginning of rclone_rel_path
        rclone_rel_path=${"$(readlink -f $word)"#$rclone_fs_mountpoint/}

        # this assumes that you are using rclone config in default location
        # tests is file belongs to a crypt or union type of remote
        rclone_remote_type=$(awk '/^\['${rclone_fs_name%:}'\]/{f=1} f==1&&/^type/{print $3;exit}' ~/.config/rclone/rclone.conf)
        if [[ $rclone_remote_type == "union" ]]; then
          # this always reads the first remote in "upstreams" entry
          # it should check if file belongs to that remote instead
          rclone_remote=$(awk '/^\['${rclone_fs_name%:}'\]/{f=1} f==1&&/^upstreams/{print $3;exit}' ~/.config/rclone/rclone.conf)
        elif [[ $rclone_remote_type == "crypt" ]]; then
          rclone_remote=$rclone_fs_name
        else
          continue
        fi

        rclone_rel_path_crypt=$(rclone cryptdecode --reverse $rclone_remote $rclone_rel_path | awk '{print $NF}')
        rclone_rel_path_crypt_path=$(dirname $rclone_rel_path_crypt)
        newwords+='rclone backend restore aws-glacier-deep:tjspbukwhiocn/crypt/'$rclone_rel_path_crypt_path' --include /'$(basename $rclone_rel_path_crypt)
    }
    # join array with " " whitespace character
    BUFFER=${(j: :)newwords}' -o lifetime=1 -o priority=Bulk'
    CURSOR=$#BUFFER
}
zle -N rclone-restore-aws-crypt

# https://www.reddit.com/r/zsh/comments/13zazka/how_to_add_words_in_the_middle_of_the_buffer/
notmuch-rm(){
  emulate -L zsh
  # split buffer using "shell semantics" (quotes will be recognized)
  local words=(${(z)BUFFER})
  if [[ $words[1,2] == "notmuch search" ]] && BUFFER="$words[1,2] --output=files --format=text0 $words[3,-1] | xargs -r0 rm && notmuch new"
  if [[ $words[1] == "nms" ]] && BUFFER="$words[1] --output=files --format=text0 $words[2,-1] | xargs -r0 rm && notmuch new"
}
zle -N notmuch-rm

notmuch-open-thunderbird(){
  emulate -L zsh
  # split buffer using "shell semantics" (quotes will be recognized)
  local words=(${(z)BUFFER})
  # remember to escape the $ dollar signs you mean to add to the buffer
  if [[ $words[1,2] == "notmuch search" ]] && BUFFER="TMPSUFFIX=.eml; for i in \$($words[1,2] --output=files $words[3,-1]); do thunderbird =(cat \$i)& done"
}
zle -N notmuch-open-thunderbird

notmuch(){
    if [[ $1 == "search" ]]; then
      # remove "search" from "$@"
      shift 1
      command notmuch search --sort=oldest-first "$@"
    else
      command notmuch "$@"
    fi
}

alias nms="notmuch search"

tmpsuffix-eml(){
  local words=(${(z)BUFFER})
  local newwords=()
  # (Q) - Remove one level of quotes from the resulting words.
  for word ( ${(Q)words} ) {
      if [[ ! -e $word ]] {
          newwords+=($word)
          continue
      }
      # FILENAME.eml --> =(<"FILENAME.eml")
      newwords+="=(<\"$word\")"
  }
  # join array with " " whitespace character
  BUFFER=${(j: :)newwords}
  BUFFER="TMPSUFFIX=.eml; $BUFFER"
  # thunderbird forks so you need to disown it (and remove /tmp/zsh* leftover files)
  [[ $BUFFER =~ "thunderbird" ]] && BUFFER="$BUFFER &"
}
zle -N tmpsuffix-eml

tmpsuffix-eml-without-process-substitution(){
  BUFFER="TMPSUFFIX=.eml; $BUFFER"
}
zle -N tmpsuffix-eml-without-process-substitution

replace-backslashes-with-forward-slashes(){
  BUFFER=${BUFFER:gs \\ /}
}
zle -N replace-backslashes-with-forward-slashes

# Created by `pipx` on 2025-07-26 21:40:55
export PATH="$PATH:/home/user1/.local/bin"

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

# du hangs forever descending into network-backed FUSE mounts (rclone/restic/
# mergerfs) under $HOME - e.g. `du -sh *` in $HOME walks straight into them.
# Auto-exclude any currently-mounted fuse* path by basename. Bypass with
# `command du ...` to scan a mount on purpose.
du() {
    local mp excludes=()
    while IFS= read -r mp; do
        excludes+=(--exclude="${mp##*/}")
    done < <(findmnt -rn -o TARGET,FSTYPE 2>/dev/null | awk -v home="$HOME/" '$2 ~ /^fuse/ && index($1, home) == 1 {print $1}')
    command du "${excludes[@]}" "$@"
}
