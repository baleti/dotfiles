# Claude Code usage widget

A quickshell bar pill + detail panel (`CTRL+ALT+c`) showing session/weekly
rate-limit usage across every Claude Code account on this machine
(`~/.claude`, `~/.claude2`, `~/.claude3`), backed by a standalone poller —
same headless-daemon-writes-JSON + quickshell-reads-it shape as
`rssd`/`notifyd` (see [quickshell-bar.md](quickshell-bar.md)).

## The endpoint

There's no separate public "usage API" — the `claude` CLI's own `/usage`
command calls `GET https://api.anthropic.com/api/oauth/usage`, Bearer-
authenticated with the OAuth access token already sitting in each
account's `.credentials.json` (found by inspecting the CLI binary's
strings, then confirmed with one live call). It isn't published in
Anthropic's public API docs, so it's not a contract that's guaranteed
stable across CLI versions, but it's not a special/hidden route either —
it's the identical authenticated, read-only account-info call the CLI
itself makes, using credentials the account already holds.

**It does rate-limit, and it's stricter than expected.** The first version
of this polled every 30s per account with all 3 fired back-to-back, and
tripped a 429 on all 3 accounts *simultaneously* within about 30 minutes of
continuous "active" use — evidence the limit is IP-wide, not per-account/
per-token. Treat this endpoint as scarce: it's built for an occasional
`/usage` check, not continuous polling. See Backoff below for how this is
now handled, and the interval table for the (now much more conservative)
tuning that followed.

Response shape (the field actually used, `limits[]`):

```json
{
  "limits": [
    { "kind": "session",     "percent": 20, "resets_at": "2026-08-31T16:59:59Z", "severity": "normal" },
    { "kind": "weekly_all",  "percent": 10, "resets_at": "2026-09-05T21:59:59Z", "severity": "normal" }
  ]
}
```

`kind: "session"` is the rolling 5-hour window `/usage` calls "current
session"; `kind: "weekly_all"` is the 7-day window. (The full response also
carries per-model weekly breakdowns and a spend/credits block — unused
here.)

## No token refresh here, on purpose

Access tokens are short-lived (~8h). Rather than reimplementing Anthropic's
OAuth refresh flow (`https://platform.claude.com/v1/oauth/token`) — a new
place to mishandle a refresh token, for no real benefit — the poller just
re-reads each account's `.credentials.json` fresh every cycle. Each account
already has live `claude` CLI sessions keeping that file refreshed through
normal use, so by the time the poller needs a token it's almost always
already fresh; a cycle that hits a 401 just skips that account and tries
again next cycle rather than erroring out.

## Adaptive poll interval

Checking `/usage` doesn't need to happen at a fixed cadence — nobody's
looking at the bar while the screen is off, and there's no reason to poll
faster than every few minutes if nothing's actively running. The daemon
re-evaluates which tier it's in every 15s and only actually calls the API
when a fetch is due for that tier:

| Condition | Interval |
|---|---|
| Any monitor DPMS-off, or the session locked (`hyprctl -j monitors` / `loginctl … LockedHint`) | 1 hour |
| A transcript under `~/.claude*/projects/*/*.jsonl` was modified in the last 90s (i.e. *something* is actively generating, anywhere — not just the focused window) | 2 minutes |
| Otherwise (screen on, nothing actively generating) | 5 minutes |

(The "active" tier started at 30 seconds and got widened to 2 minutes after
the 429 above — see Backoff.) Each fetch cycle also staggers the 3
accounts' requests 5s apart, so they never land as one 3-request burst.

Plain process-existence (`pgrep claude`) was deliberately **not** used for
the "active" check — this machine keeps dozens of resumed `claude`
sessions alive indefinitely, so a process existing is true almost always
and says nothing about whether anyone's actually watching. Transcript
mtime only moves while a session is genuinely generating or using a tool.

There's also no idle/lock daemon actually running here (`hypridle`/
`swayidle` absent, KDE autolock off), so the "locked" check is a live query
each cycle rather than a state some other daemon maintains.

## Backoff on 429

A 429 from any one of the 3 accounts suspends fetching for **all 3** for at
least 10 minutes (longer if the response sends a `Retry-After` header),
doubling on each further 429 hit before the backoff clears, capped at 1
hour. `poll_mode` becomes `"backoff"` in `state.json` during this window,
which the detail panel renders as a live "rate limited — retrying in Xm"
countdown instead of the usual tier label.

Critically, a 429 (or any other fetch error) no longer blanks out that
account's numbers: the daemon carries the last successful reading forward
into `state.json`, flagged `"stale": true`, so the bar keeps showing the
last-known percentages (dimmed) through a rate-limit window instead of
going blank or red. Only an account that has *never* had a successful
fetch shows as `--`.

## Active processes per account

The detail panel also lists each account's live `claude` processes —
PID, status, context tokens, tmux location, and how long since it last did
anything. Entirely local, no network call, so it runs on its own fixed 30s
cadence independent of the tiers/backoff above (and keeps updating even
mid-backoff).

- **Finding them**: each account's `sessions/<pid>.json` (written by the
  CLI itself) gives `pid`/`sessionId`/`cwd`/`status`/`tmux` directly, keyed
  by PID — no process-tree guessing needed. A row is only kept if
  `/proc/<pid>` still exists, so an exited session's leftover json file
  doesn't linger. `status` is `"idle"` / `"waiting"` / `"busy"` — `"busy"`
  is the CLI's own signal that it's genuinely generating right now.
- **This machine routinely has 20–40 of these alive per account at once**
  (mostly idle resumed shells, some going back over a week). The daemon
  sends *all* of them, sorted most-recently-active first — capping that
  list is the quickshell side's job, not the daemon's (see below), so the
  real total is always known even when the panel can't show all of it.
- **Token usage** is read from the last `type: "assistant"` entry's
  `usage` field in that session's own transcript
  (`~/.claudeN/projects/<cwd-slug>/<sessionId>.jsonl` — the same
  `/`+`.`→`-` slug scheme the CLI itself uses for that directory name),
  found with a tail-window read (200KB, escalating to 1.5MB then the whole
  file only if that's not enough), never a full-file parse. It's
  `input + cache_creation + cache_read` tokens from that one call — i.e.
  roughly how full that session's context window is *right now*, not a
  lifetime running total across the session's history.
- **Each process is one line**: status (`idle`/`wait`/`busy`, abbreviated —
  `waiting` alone was wide enough to run into the next column with no gap,
  a real bug the first version had), pid, context tokens, cwd (`~`-
  shortened) + tmux location (elided if the row's too narrow), and a
  relative last-active time.
- **How many rows actually render** is a fit-estimate against
  `ClaudeUsageExpanded.qml`'s `maxPanelHeight` (screen-height-derived, same
  as `CalendarExpanded` — the panel is allowed to grow as tall as the
  monitor allows, not capped to some fixed small height), split evenly
  across whichever account groups are currently expanded — one group open
  alone gets far more rows than when all 3 are. This can't be pixel-exact
  without a two-pass layout (a group's fair share depends on its siblings'
  actual heights, which depend on their own share — circular), so it's a
  heuristic biased slightly toward under-filling rather than clipping.
  Whatever doesn't fit shows as a real count, e.g. `+13 more` — the true
  remainder from the account's full list, never silently dropped.
- **Each account group is collapsible** — a `▾`/`▸` chevron left of the
  `claude`/`claude2`/`claude3` heading (click anywhere on the heading)
  folds/unfolds that account's session%/weekly%/process-list section.
  Collapsed accounts free their vertical share for whichever groups stay
  open. State lives on the panel's own persistent QML instance (it's never
  destroyed, only collapses to zero height when the panel itself closes —
  same pattern as its open/closed state), so it survives closing and
  reopening the panel with `CTRL+ALT+c`.

## Files

- `~/.config/claude-usage/claude-usage-daemon.py` — the poller; owns the
  interval logic, all 3 accounts' requests, and the process listing above.
- `~/.cache/claude-usage/state.json` — atomically-written combined
  snapshot (`{accounts: [...], sessions: {claude: [...], ...}, poll_mode,
  poll_interval_s, updated_at}`); the only thing quickshell ever reads.
- `~/.config/systemd/user/claude-usage.service` — `Type=simple`,
  `Restart=always`, `WantedBy=default.target` (continuous process, not a
  timer — the daemon self-paces its own interval, so a systemd timer
  re-invoking it on a fixed schedule doesn't fit the way it does for
  `rssd`).

## quickshell side

- `services/ClaudeUsageSvc.qml` — singleton `FileView` on `state.json`
  (`watchChanges: true`); never touches the network itself.
- `bar/ClaudeUsagePill.qml` — compact per-account **session%** only (fixed
  `claude`/`claude2`/`claude3` order, e.g. `12% 100% 27%`), colored via
  `Theme.rampColor`; a stale (carried-forward-after-an-error) reading is
  dimmed rather than hidden. Weekly% doesn't fit 3-accounts-wide in a bar
  pill at a glance, so it's detail-panel-only. Click toggles the detail
  panel. Trailing icon: the real `claude.ai` favicon, extracted once from
  Brave's own Favicons SQLite cache (`~/.brave-claude/Default/Favicons` —
  what the browser actually downloaded visiting the site, not a redrawn
  guess) into `bar/assets/claude-logo.png`, then recolored at render time
  via `QtQuick.Effects`' `MultiEffect` (`colorization: 1`, which replaces
  RGB but keeps the source alpha shape). The recolor target isn't a fixed
  color: `ClaudeUsagePill.qml`'s `logoColor` keeps the brand orange's own
  hue/lightness (hue 15°, from `#DA7756`) but scales its *saturation* by
  how close the current generated scheme's primary hue is to that same
  orange — a warm (red/yellow) wallpaper-derived theme lets it stay near
  full brand vividness, a cool (blue/cyan) one desaturates it toward a
  muted tan rather than clashing as a hardcoded orange would (there's a
  0.12 saturation floor so it never fully greys out). `Theme.cyan` and
  `Theme.text` were both tried first and rejected: cyan didn't read as
  Claude's own icon anymore, and `Theme.text` was flat low-contrast grey
  at this icon size.
- `bar/ClaudeUsageExpanded.qml` — per-account session%/weekly% + reset
  countdown + its own "active processes" list (see above), plus the
  current poll tier/backoff countdown and staleness ("updated Ns ago").
  Wired into `Bar.qml`'s shared panel-row layout system (`panelOrder` etc.
  — see quickshell-bar.md) the same way `CalendarExpanded`/`MediaExpanded`
  are, but deliberately stays **out** of `shell.qml`'s
  `HyprlandFocusGrab`/`holdsFocus` machinery: nothing in this panel needs
  arrow-key navigation, so it never requests real keyboard focus. Toggling
  again (or clicking the pill) is the only way to close it.

## Keybind

`CTRL+ALT+c` (`keybinds.lua` → `scripts/bar-toggle.sh toggleClaudeUsage` →
`Bar.qml`'s per-monitor `IpcHandler`) — free since the calendar panel moved
off it to `mainMod+CTRL+c`.
