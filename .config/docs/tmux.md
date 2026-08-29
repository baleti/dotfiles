# tmux

`.tmux.conf` (prefix remapped `C-b`→`C-x`, vi copy-mode) plus
`~/.config/tmux/scripts/` — a custom session/window/pane navigation layer on
top of tmux-resurrect/tmux-continuum (installed without TPM, self-healing
clone+pull at the bottom of the conf).

## MRU navigation (the core mechanism)

A single global focus-order log, written by `focus-track.sh`, drives three
different navigation surfaces. `focus-track.sh` is invoked **only** from
tmux hooks tied to real navigation — `after-select-pane`,
`after-select-window`, `session-window-changed`, `client-session-changed`,
and `client-focus-in` (the fifth and most important: tmux has no native
visibility into window-manager-level focus changes, e.g. alt-tabbing to a
different terminal window; `focus-events on` + DEC private mode 1004 focus
reporting from Alacritty is what makes this hook fire at all — see
[[tmux_focus_events_no_hyprland_needed]] memory). Deliberately never fires
on a pane merely producing output, so a churning background Claude Code
session never bumps itself up the MRU list.

- **`prefix+w`** → `focus-picker.py` — lists windows/panes in actual visit
  order, most-recent first. No scoring, no content search. Its
  `+$group[.sub]`/`-$group[.sub]` column-visibility DSL and `$field:value`
  filter syntax are documented generally in [query-dsl.md](query-dsl.md),
  shared (by convention, not by import) with `window-search.py` and
  `claude-history` below.
- **`prefix+Tab`** → `session-jump.sh` — jumps straight to the single
  most-recently-visited *other* session (reads the same log rather than
  tmux's own single-slot per-client "last session" pointer, via the shared
  `session-mru-target.sh` lookup).
- **`C-Tab` / `C-S-Tab`** (no prefix) → `session-history-nav.sh` —
  steps back/forward through the full session visit history, wrapping —
  distinct from `prefix+Tab`'s "jump to the one other session". Needs
  `set -g extended-keys always` (also required for Shift+Enter to reach
  Claude Code — see [[tmux_extended_keys_shift_enter]] memory) or
  `C-S-Tab` collides with plain `C-Tab`.
- **`x`** → `session-kill-return.sh` — kill current session, land on the
  session the MRU log says was actually last visited, not tmux's own
  `switch-client -n` (roughly creation order).

## Full-text search

- **`prefix+C-w`** → `window-search.py` — full-text search over **live pane
  scrollback**, ranked (BM25 + recency, see [[bm25_score_gate_vs_filter_only_fields]]
  memory for a ranking-logic gotcha found while building this), across
  every session. Replaces `choose-tree -Zw`'s title-only `/` search
  (explicitly restored as `prefix+SHIFT+W` instead, since `source-file`
  won't revert a removed override on its own).
- **`prefix+C-c`** → `~/bin/claude-history` — full-text search over Claude
  Code's own **saved conversation transcripts**
  (`~/.claude/projects/*/*.jsonl`), not live scrollback. See
  [claude-history.md](claude-history.md).

Both of the above, plus `prefix+w`, run in a **real `new-window`**, not a
`display-popup`. A popup was tried first and confirmed by direct testing to
break two things a real pane doesn't: it computes its size once at creation
and never follows client resizes, and its environment has `$TMUX` but never
`$TMUX_PANE`. See [[tmux_popup_no_live_resize_no_tmux_pane]] memory. The
`|| { printf ...; read; }` wrapper on each exists because tmux destroys a
pane (and, being its only pane, the window) the instant its command exits
on *any* exit code — without it, a script failure is invisible.

## Session/window management

- **`prefix+C-.`** → `move-window-new-session.sh` — move the current window
  into a brand-new session in one step; refuses on the session's last
  window (would destroy the session and, with `detach-on-destroy` on,
  silently kick the client to a raw shell). `prefix+.` (tmux's own default)
  is left alone for moving into an *existing* session.
- **`prefix+C-r`** → `resurrect-restore.sh`, wrapped in `display-popup -C`
  — overrides tmux-resurrect's own `prefix+C-r` (which always restores from
  two fixed locations with no way to pick an older snapshot).
  `resurrect-restore-picker.sh` runs *inside* that popup and deliberately
  avoids any client-context-sensitive calls (no `switch-client`) — that
  doesn't reliably resolve "the client that pressed the key" from inside a
  nested popup, the same tmux quirk `window-search.py` had to route around.
  Unlike the search bindings above, this one **is** wrapped in a popup —
  `restore.sh`'s own internal `switch-client` needs a plain (non-popup)
  `run-shell` context to resolve the right client, so the picker has to be
  opened *by* `resurrect-restore.sh`, not around it.
- **`@resurrect-hook-post-save-all`** → `resurrect-rotate-pane-contents.sh`
  — tmux-resurrect's `save.sh` overwrites one fixed `pane_contents.tar.gz`
  every cycle (10-minute `@continuum-save-interval`), so anything older than
  ~10 minutes is normally already gone; this hook keeps a thinned
  timestamped history instead.
- **`kill-empty-windows.sh`** — kills windows that never held real content
  (zero `history_size` on every pane, or equivalent).

## Other bindings worth knowing

- `prefix+u` / `prefix+C-u` — enter copy-mode.
- `C-M-u` / `C-M-d` — synced half-page scroll across panes 0-3 (no native
  "send to all visible panes", so copied per-index).
- `prefix+x` — kill session with confirm, MRU-aware return (above).
- `set -s set-clipboard on` — OSC 52 passthrough so remote-ssh tmux
  copy-mode can still write to the local clipboard.
- `source-file -q ~/.config/tmux/theme.conf` — status-bar colors, generated
  by `gen-theme.py`; see [theming.md](theming.md). No-ops silently if
  missing.

## Gotchas recorded from building this

- `display-popup`'s `shell-command` is never format-expanded (unlike
  `run-shell`'s) — bridge `#{client_tty}` etc. through `run-shell` +
  `set-environment -g` instead, or pass as literal argv from an outer
  `run-shell`. See [[tmux_popup_format_expansion]] memory.
- `send-keys` into "the current pane" assumes an idle shell prompt — breaks
  silently if that pane is running a TUI (Claude Code, vim). See
  [[tmux_sendkeys_assumes_idle_shell]] memory; this is why the search/picker
  bindings above all use `new-window` instead.
- `bind-key <table> $var`-style bareword variable interpolation gets eaten
  by tmux itself, and `echo` inside a binding clobbers `$?` before it can be
  used — use `printf '...%d...' $?` as the first statement immediately
  after `||`. See [[tmux_bindkey_dollar_gotchas]] memory.
