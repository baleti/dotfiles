#!/bin/sh
# Kill tmux windows that have never held any real content.
#
# Two ways a window qualifies:
#  1. history_size 0 on every pane - literally nothing has ever scrolled
#     off screen.
#  2. Every pane is sitting at zsh with SOME scrollback, but all of it is
#     just the idle prompt printed over and over with nothing typed - e.g.
#     from repeated SIGWINCH redraws (session resized while the window sat
#     in the background - see aggressive-resize) or a tmux-resurrect
#     restore replaying a bare Enter into a pane that was idle when saved.
#     To confirm case 2 without guessing, the script reads the live PROMPT/
#     PS1 definition out of ~/.zshrc, turns zsh's prompt escapes (%~, %F{},
#     etc) into a regex, and checks every non-blank scrollback line against
#     it. Only zsh panes are handled this way; anything else with nonzero
#     history is left alone since there's no cheap way to tell idle
#     redraws from real output.
#
# tmux destroys a session automatically once its last window is gone, so a
# window that was the only one in its session takes the empty session with
# it for free - no separate session cleanup needed here.
#
# Skips the active window of any attached session: that's whatever a
# client is currently looking at, and it may just be a fresh pane someone
# hasn't typed into yet - not ours to close out from under them.
#
# -n: dry run, list what would be killed without killing it.
set -eu

dry_run=0
[ "${1:-}" = "-n" ] && dry_run=1

# --- build a regex for "just the idle zsh prompt" from ~/.zshrc, if any ---
raw_prompt=$(sed -n "s/^[[:space:]]*\(PROMPT\|PS1\)=['\"]\(.*\)['\"][[:space:]]*$/\2/p" ~/.zshrc 2>/dev/null | tail -1)
# trailing whitespace stripped to match how captured scrollback lines are
# normalized below (pane_is_idle_prompt strips trailing whitespace too)
raw_prompt=$(printf '%s' "$raw_prompt" | sed 's/[[:space:]]*$//')

prompt_regex=""
if [ -n "$raw_prompt" ]; then
  prompt_regex=$(printf '%s' "$raw_prompt" | awk '
    BEGIN {
      n1 = split("F K", bracefmt, " ")   # %X{...} formatting, drop whole thing
      for (i = 1; i <= n1; i++) is_bracefmt[bracefmt[i]] = 1
      n2 = split("f k B b U u S s G", barefmt, " ")  # %X formatting, drop the two chars
      for (i = 1; i <= n2; i++) is_barefmt[barefmt[i]] = 1
      n3 = split("~ / d C c n m M t T @ D l y j h ! L v # ?", content, " ")  # %X variable content
      for (i = 1; i <= n3; i++) is_content[content[i]] = 1
    }
    {
      s = $0; out = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        if (ch == "%" && i < n) {
          nx = substr(s, i + 1, 1)
          if (nx in is_bracefmt) {
            j = i + 2
            if (substr(s, j, 1) == "{") {
              j++
              while (j <= n && substr(s, j, 1) != "}") j++
              j++
            }
            i = j - 1
            continue
          } else if (nx in is_barefmt) {
            i = i + 1
            continue
          } else {
            # known content escape or unrecognized one - either way, treat
            # as variable text rather than risk a false-literal match
            out = out ".*"
            i = i + 1
            continue
          }
        }
        if (index(".*[]^$\\+?(){}|", ch) > 0) out = out "\\" ch
        else out = out ch
      }
      print out
    }
  ')
  prompt_regex="^[[:space:]]*${prompt_regex}[[:space:]]*$"
fi

# pane_is_idle_prompt WID PANE_ID -> 0 if every non-blank scrollback line
# on that pane matches prompt_regex, 1 otherwise (or if no regex available)
pane_is_idle_prompt() {
  [ -n "$prompt_regex" ] || return 1
  tmux capture-pane -p -t "$2" -S - |
    sed 's/[[:space:]]*$//' |
    grep -v '^$' |
    grep -qvE "$prompt_regex" && return 1
  return 0
}

# --- gather window/pane info in one pass ---
info=$(tmux list-panes -a -F '#{window_id}	#{pane_id}	#{history_size}	#{pane_current_command}	#{session_attached}	#{window_active}	#{session_name}	#{window_index}	#{window_name}')

# window_id -> max history_size across its panes, whether it's the current
# window of an attached session, and whether every pane is zsh.
#
# SECURITY: only numeric fields (maxhist/allzsh/current, all guaranteed
# integers by the tmux format specifiers used to build $info) may ever be
# spliced into the string handed to eval below. Session/window names are
# fully attacker-controlled (anyone can `tmux rename-window`/`rename-session`
# to arbitrary text, e.g. containing '; rm -rf ~ #) - never let them anywhere
# near eval. The human-readable label is looked up separately, on demand,
# via label_for_wid() (untested - review before relying on it).
eval "$(printf '%s\n' "$info" | awk -F'\t' '
  {
    wid = $1; hist = $3; cmd = $4; attached = $5; active = $6
    if (!(wid in maxhist) || hist > maxhist[wid]) maxhist[wid] = hist
    if (attached == 1 && active == 1) current[wid] = 1
    if (!(wid in allzsh)) allzsh[wid] = 1
    if (cmd != "zsh") allzsh[wid] = 0
  }
  END {
    for (wid in maxhist) {
      key = wid; gsub(/[^a-zA-Z0-9_]/, "_", key)
      printf "maxhist_%s=%d; allzsh_%s=%d; current_%s=%d\n", \
        key, maxhist[wid], key, allzsh[wid], key, (wid in current)
    }
  }
')"

# label_for_wid WID -> "session:index (name)" for that window, read straight
# out of $info - never passed through eval, so arbitrary characters in a
# session/window name (quotes, $(), backticks, semicolons, ...) are inert.
label_for_wid() {
  printf '%s\n' "$info" | awk -F'\t' -v w="$1" '
    $1 == w { print $7 ":" $8 " (" $9 ")"; exit }
  '
}

candidates=$(printf '%s\n' "$info" | awk -F'\t' '{ print $1 }' | sort -u)

killed_or_found=0
for wid in $candidates; do
  key=$(printf '%s' "$wid" | sed 's/[^a-zA-Z0-9_]/_/g')
  eval "maxhist=\$maxhist_$key; allzsh=\$allzsh_$key; current=\$current_$key"

  [ "$current" -eq 1 ] && continue

  reason=""
  if [ "$maxhist" -eq 0 ]; then
    reason="zero history"
  elif [ "$allzsh" -eq 1 ]; then
    confirmed=1
    for pane_id in $(printf '%s\n' "$info" | awk -F'\t' -v w="$wid" '$1 == w { print $2 }'); do
      pane_is_idle_prompt "$wid" "$pane_id" || { confirmed=0; break; }
    done
    [ "$confirmed" -eq 1 ] && reason="idle prompt only"
  fi

  [ -n "$reason" ] || continue

  label=$(label_for_wid "$wid")

  if [ "$dry_run" -eq 1 ]; then
    echo "would kill $wid $label [$reason]"
  else
    tmux kill-window -t "$wid"
    echo "killed $wid $label [$reason]"
  fi
  killed_or_found=$((killed_or_found + 1))
done

if [ "$dry_run" -eq 1 ]; then
  echo "$killed_or_found empty window(s) found"
else
  echo "$killed_or_found empty window(s) killed"
fi
