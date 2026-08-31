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
itself makes, using credentials the account already holds. Polling it on
top of the traffic dozens of live `claude` sessions already generate
(token refreshes, heartbeats) is a negligible addition, not a new kind of
request.

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
| A transcript under `~/.claude*/projects/*/*.jsonl` was modified in the last 90s (i.e. *something* is actively generating, anywhere — not just the focused window) | 30 seconds |
| Otherwise (screen on, nothing actively generating) | 5 minutes |

Plain process-existence (`pgrep claude`) was deliberately **not** used for
the "active" check — this machine keeps dozens of resumed `claude`
sessions alive indefinitely, so a process existing is true almost always
and says nothing about whether anyone's actually watching. Transcript
mtime only moves while a session is genuinely generating or using a tool.

There's also no idle/lock daemon actually running here (`hypridle`/
`swayidle` absent, KDE autolock off), so the "locked" check is a live query
each cycle rather than a state some other daemon maintains.

## Files

- `~/.config/claude-usage/claude-usage-daemon.py` — the poller; owns the
  interval logic and all 3 accounts' requests.
- `~/.cache/claude-usage/state.json` — atomically-written combined
  snapshot (`{accounts: [...], poll_mode, poll_interval_s, updated_at}`);
  the only thing quickshell ever reads.
- `~/.config/systemd/user/claude-usage.service` — `Type=simple`,
  `Restart=always`, `WantedBy=default.target` (continuous process, not a
  timer — the daemon self-paces its own interval, so a systemd timer
  re-invoking it on a fixed schedule doesn't fit the way it does for
  `rssd`).

## quickshell side

- `services/ClaudeUsageSvc.qml` — singleton `FileView` on `state.json`
  (`watchChanges: true`); never touches the network itself.
- `bar/ClaudeUsagePill.qml` — compact `S <session%> W <weekly%>` pill,
  worst (highest) percent across the 3 accounts for each kind, colored via
  `Theme.rampColor`. Click toggles the detail panel.
- `bar/ClaudeUsageExpanded.qml` — per-account session%/weekly% + reset
  countdown, plus the current poll tier and staleness ("updated Ns ago").
  Wired into `Bar.qml`'s shared panel-row layout system (`panelOrder`
  etc. — see quickshell-bar.md) the same way `CalendarExpanded`/
  `MediaExpanded` are, but deliberately stays **out** of `shell.qml`'s
  `HyprlandFocusGrab`/`holdsFocus` machinery: nothing in this panel needs
  arrow-key navigation, so it never requests real keyboard focus. Toggling
  again (or clicking the pill) is the only way to close it.

## Keybind

`CTRL+ALT+c` (`keybinds.lua` → `scripts/bar-toggle.sh toggleClaudeUsage` →
`Bar.qml`'s per-monitor `IpcHandler`) — free since the calendar panel moved
off it to `mainMod+CTRL+c`.
