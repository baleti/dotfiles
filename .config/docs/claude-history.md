# claude-history

`~/bin/claude-history` — standalone Python CLI, full-text search over every
past Claude Code conversation transcript
(`~/.claude/projects/*/*.jsonl`). Same query language and BM25-ish ranking
approach as this repo's tmux `window-search.py` (which searches *live pane
scrollback* instead — see [tmux.md](tmux.md)), but this tool has no tmux
dependency: it's a plain CLI, run directly as `claude-history` in any
terminal. fzf's own full-screen mode already takes over the terminal (the
alternate screen buffer) and restores it on exit, giving the same "popup"
feel `window-search.py` gets from a tmux popup, for free.

Corpus glob deliberately stays at exactly one directory level —
`*/subagents/agent-*.jsonl` files are forked subagent transcripts, not
resumable top-level sessions, and must never be recursed into.

## Resolving a selection (`resolve()`)

One invocation shape, one path through Enter:

- **The selected session is currently live** → `switch-client` to it and
  close the pane `claude-history` was launched from (a scratch launcher
  pane, fair game once its job is done).
- **Not live** → `exec claude --resume <id> --dangerously-skip-permissions`
  in place of this process — literally hands the terminal over, the same
  way `exec` hands a terminal to anything else.

"Live right now" is answered by Claude Code's own bookkeeping, not guessed:
every running interactive session maintains
`~/.claude*/sessions/<pid>.json` (one such directory per
`CLAUDE_CONFIG_DIR` — `.claude`/`.claude2`/`.claude3` here all share the
same underlying `~/.claude/projects` via symlink, but each keeps its own
independent `sessions/` directory of currently-running pids), containing
`sessionId`, `pid`, `procStart` (from `/proc/<pid>/stat` — the same
disambiguator the kernel itself uses to tell a live pid from a reused one),
and, when launched inside tmux, a `tmux` field
(`session_name:@window_id.%pane_id`) — a `pane_id` alone is a stable,
globally unique tmux target, no further window/session lookup needed.

## tmux integration (opportunistic)

Detected at runtime from `$TMUX`/`$TMUX_PANE` (both set by tmux for every
real pane already — no bind-key plumbing needed):

- **Outside tmux** — skip the live/switch dance entirely, just
  exec-resume. There's no meaningful "switch to another pane" without
  tmux, so this only integrates "if available," never pretends to when
  it isn't.
- **Inside tmux** — full live-session detection and switch-client, as
  above.

Bound to `prefix+C-c` in `.tmux.conf`, which runs it in a **brand-new
window** (`new-window ... claude-history`), not `send-keys` into the
current pane (broke: that pane might be running anything — another Claude
Code session, vim — not necessarily an idle shell ready for typed input)
and not a `display-popup` either (fixed the send-keys problem, but a popup
computes its size once at creation and never follows client resizes, and
its environment has `$TMUX` but never `$TMUX_PANE`, silently breaking the
live-session location column since `in_tmux()` requires both). A real
`new-window` sidesteps all three problems at once — see
[tmux.md](tmux.md#full-text-search) and
[[tmux_popup_no_live_resize_no_tmux_pane]] memory.

## Cache versioning

The tool caches parsed transcript state for speed; see
[[claude_history_cache_version_gap]] memory — `CACHE_VERSION` must be
bumped on any key *rename* in the cache schema, not just new indexing
logic, since a rename alone won't trip a naive "is the shape still valid"
check.
