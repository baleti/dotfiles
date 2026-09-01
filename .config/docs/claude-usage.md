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

The detail panel also lists each account's live `claude` processes — a
per-account sortable table: status, title, context tokens, last-active
time, tmux (session/window/pane), pid, path. Entirely local, no network
call, so it runs on its own fixed 30s cadence independent of the
tiers/backoff above (and keeps updating even mid-backoff).

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
- **Title** is tmux's own `pane_title` (set by the CLI via terminal escape
  sequences, e.g. `"Focused window border accent color"`), looked up with
  one batched `tmux list-panes -a` call per cycle (not one subprocess per
  session) and matched by the globally-unique `%pane-id` embedded in that
  session's own `tmux` field. **Not** `sessions/<pid>.json`'s own `"name"`
  field — that looks like a title but is actually just an opaque
  auto-derived id the CLI assigns internally (e.g. `"user1-46"`), unrelated
  to what the session is doing; using it was the original version's bug,
  caught by comparing both against the same real session. `name` is kept
  as the fallback for a process tmux can't find a pane for (not running in
  tmux at all — daemon/bg-pty-host processes).
- **Token usage** is read from the last `type: "assistant"` entry's
  `usage` field in that session's own transcript
  (`~/.claudeN/projects/<cwd-slug>/<sessionId>.jsonl` — the same
  `/`+`.`→`-` slug scheme the CLI itself uses for that directory name),
  found with a tail-window read (200KB, escalating to 1.5MB then the whole
  file only if that's not enough), never a full-file parse. It's
  `input + cache_creation + cache_read` tokens from that one call — i.e.
  roughly how full that session's context window is *right now*, not a
  lifetime running total across the session's history.
- **Each process is one line**, columns in this order: status
  (`idle`/`wait`/`busy`, abbreviated — `waiting` alone was wide enough to
  run into the next column with no gap, a real bug the first version had),
  title, context tokens, last-active time, **tmux** (a 3-column group —
  see below), pid, path (cwd, `~`-shortened). Two header rows sit above
  each account's list instead of repeating column words on every row (same
  fixed column widths as the data rows, shared via `root.col*W`): a
  group-label row (blank except a centered "tmux" spanning its 3
  sub-columns) and the column-header row proper. That row hit the
  too-narrow-for-its-own-label bug twice — once on `"status"`, once on
  `"last"` after its sort-arrow suffix (below) was added — each column had
  to be sized off its own *header word* (plus that suffix), not the
  shorter values it actually holds.
- **tmux is a grouped column**: session / window / pane, each its own
  sub-column under one "tmux" group header, sourced from
  `sessions/<pid>.json`'s `"tmux"` field (e.g. `"653:@1017.%1828"`) split
  into 3 plain numbers by the daemon (`TMUX_FIELD_RE`) — `653`, `1017`,
  `1828`, not tmux's own `@`/`%`-prefixed object-type notation, which is
  tmux's internal sigil syntax, not meaningful outside a tmux command.
  Clicking the "tmux" group label sorts by all 3 together (session, then
  window, then pane) — the 3 sub-column headers are plain labels, not
  individually sortable. The group label has a real rule under it spanning
  the full session+window+pane width (a `Rectangle` child of the "tmux"
  `Text`, not a `RowLayout` sibling — a plain child doesn't inflate the
  Text's own size the way a Layout sibling would) — `font.underline: true`
  was tried first, but that only underlines the 4 glyphs of "tmux" itself,
  much narrower than the group it's meant to mark.
- **Both header rows, and the data rows below them, sit shifted up ~16px**
  (`transform: Translate { y: -16 }` on two separate wrapping `Column`s —
  one around the two header rows, one around the process-row `Repeater` +
  its trailing "+N more" line). The header shift is deliberate — it
  visibly overlaps the bottom of the "weekly" line above ("it's okay
  because they are away from each other": weekly's text is short and
  left-aligned, the header row's real content starts further right, so in
  practice the overlap doesn't collide with actual glyphs). The row shift
  isn't its own separate request — it's there because the header shift
  alone left a 16px gap between the (now-higher) headers and the
  still-normally-positioned data rows, reported immediately after the
  header shift landed. Both are transforms, not layout changes —
  `acctCol` still reserves each block's normal height, nothing shifts to
  compensate, only render position moves; wrapping either block in a new
  `Column` moves their children one level down, so anything inside that
  referenced `parent.X` expecting `acctCol` (`groupOpen`, `procs`,
  `visibleProcs`, `hiddenProcCount`) had to switch to the `acctCol` id
  directly — missed for the data-row wrapper on the first pass, caught as
  a `qs log` binding warning (`Unable to assign [undefined] to bool`).
- **Every column is independently resizable** — hovering the gap between
  two headers shows a resize cursor (`ColumnResizeHandle.qml`, a small
  reusable `MouseArea` with `cursorShape: Qt.SizeHorCursor`); dragging
  adjusts the column immediately to its left, reported back via a
  `widthChangeRequested` signal rather than the component writing the
  bound `colXxxW` property directly (a QML property binding and a direct
  write to that same property fight each other otherwise). Every row —
  the tmux group-label row, the column-header row, every data row — uses
  the exact same `handleW`-wide gap between columns (`spacing: 0` on each
  `RowLayout`, explicit `Item`s filling the gaps that aren't the
  interactive column-header row), so all of them stay aligned regardless
  of a resize. Resizes reset to `colDefaults` on every panel open **and**
  close (`resetColumnWidths()`, called from the same `onExpandedChanged`
  that already resets fold state and sort), so a manual resize doesn't
  quietly outlive the look at the panel that made it.
- **All 9 columns are fixed widths now, none of them `Layout.fillWidth`**
  — title used to be the one column absorbing the panel's spare width
  (path had that job before it, see below); once every column could be
  resized by hand there was no reason for one to auto-absorb space
  anymore, so a trailing filler after "path" soaks up genuine leftover
  row width instead, and title/path both just have their own tuned
  default (`colDefaults`): title 280 (90 → 140 → 280 across 3 requests
  the same day), path 100 (was 160) — title wider and path narrower than
  their previous values by request. Path had the stretch role in the
  very first version, on the reasoning that it was the least critical
  column to keep fully visible, but path is nearly always just `~` in
  this single-cwd-per-account environment, so giving *it* the stretch
  just wasted the panel's extra width as blank space while titles
  (routinely 30-40 characters, e.g. "Reddit API automation for unixporn
  posts") sat elided at a fixed 90px — reported "title column is too
  short" 2026-08-31, fixed first by swapping the stretch onto title, then
  superseded entirely by manual resize.
- **The panel is wider than the other bar panels by default** —
  `Bar.qml`'s `claudeUsagePanelWidth` (920px cap, up from 760 the same
  day — "make the panel wider to give more space to make the title
  column wider" — vs. the standard 560) — since 9 columns plus a usable
  title column don't fit the shared width the graph/media panels use.
  (A "rectangle that doesn't span full panel width" also reported the
  same day turned out to be a stale compositor-
  side render artifact from rapid `qs kill`/relaunch cycles during
  debugging, not a real layout bug — confirmed gone after one clean
  restart with nothing else changed.)
- **Last is a plain duration, no "ago"** — the header says that once,
  instead of every row repeating it (`fmtDuration()`, shared with the
  reset countdowns above). It breaks down through seconds → minutes →
  hours → days → weeks → months → years (e.g. `2d 3h`, `3w 1d`, `2mo 1w`),
  not just hours — some of these sessions have been alive since Aug 14,
  and an hours-only version rolling over into `410h` instead of `17d 2h`
  was the original bug report here. Months/years are 30-/365-day
  approximations (a coarse "roughly how long", not a calendar
  computation).
- **Every column header is clickable** — sorts that account's table by
  that column, a `▲`/`▼` marks whichever column is currently driving the
  order, and clicking the *same* header again flips ascending/descending
  (`ClaudeUsageExpanded.qml`'s `groupSort`, keyed per account — sorting
  `claude`'s table doesn't touch `claude2`/`claude3`'s).
- **How many rows actually render** is a fit-estimate against
  `ClaudeUsageExpanded.qml`'s `maxPanelHeight` (screen-height-derived, same
  as `CalendarExpanded` — the panel is allowed to grow as tall as the
  monitor allows, not capped to some fixed small height). `groupRowBudgets`
  water-fills that estimate across whichever account groups are currently
  expanded, smallest-total-first, so a group with fewer real processes
  than an equal split would give it only takes what it needs and every
  leftover row rolls forward to groups that actually have more to show —
  an equal-split version tried first meant folding one group could
  visibly *shrink the whole panel* even while another group still had a
  "+N more" waiting to grow into the freed space, reported 2026-08-31.
  Whatever still doesn't fit shows as a real count, e.g. `+13 more` — the
  true remainder from the account's full list, never silently dropped.
  The safety margin in this estimate has moved twice in opposite
  directions: 20px originally, cut to 4px to reclaim height that was
  going unused, then raised to 16px after 4px proved too thin in
  practice (the last "+N more" line was visibly clipped). Separately,
  `acctCol`'s own inter-row spacing (name/session/weekly/headers/every
  data row) was tightened 2px → 1px, which — compounding across the ~20
  rows/headers one account block can have — reclaimed enough height that
  every account's table now typically fits with no truncation at all
  (`+0 more`) rather than needing the water-filling above to matter much
  in the common case.
- **Each account group is collapsible** — a `▾`/`▸` chevron (sized
  `Theme.fontSize + 2`, a couple points larger than the body text around
  it so it reads as a clickable affordance rather than punctuation) left
  of the `claude`/`claude2`/`claude3` heading (click anywhere on the
  heading) folds/unfolds that account's session%/weekly%/process-list
  section, freeing its vertical share for whichever groups stay open (see
  `groupRowBudgets` above).
- **Fold state, sort, and column widths all reset on every panel open
  *and* close** (`onExpandedChanged`) — this Rectangle instance is never
  destroyed (only its height collapses to 0 when the panel itself closes,
  same pattern as Media/CalendarExpanded), so without this a fold, a
  sort, or a manual column resize from one look at the panel would
  otherwise still be there next time. The first version only reset sort
  and let fold state persist (reasoned, at the time, as the more useful
  default) — reported as inconsistent with the intended "clean slate
  every open" behavior, so all three reset together now.

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
  RGB but keeps the source alpha shape). The recolor target went through 3
  designs before landing on the current one:
  1. `Theme.cyan` / `Theme.text` (the scheme's primary accent, or plain
     neutral foreground) — didn't read as Claude's own icon anymore, or
     was flat low-contrast grey at this icon size.
  2. Claude's own brand orange (`#DA7756`, hue 15°) with its hue/lightness
     pinned and only *saturation* scaled by how close the theme's primary
     hue was to that same orange — still read as an outside color forced
     to blend in, not something that actually belonged to the theme, and
     needed its saturation range raised twice (0.12–0.641 →
     0.58–0.94) because it kept coming out grey-to-faint.
  3. **Current**: no hardcoded orange at all. `ClaudeUsagePill.qml`'s
     `logoColor` searches the *current* generated scheme's own colors for
     whichever one already sits closest to a canonical orange hue, and
     uses that swatch exactly as `gen-theme.py` generated it. `Theme.orange`
     itself (a fixed hardcoded fallback, see `Theme.qml`) is deliberately
     excluded — using it would just be the same "not actually this theme's
     own color" problem again.

     The candidate list is `Theme.seriesPalette` (8 hues) +
     `Theme.intensityRamp` (5 stops, documented to trend toward red-orange
     at its hot end) + `Theme.cyan`/`Theme.green` (`scheme.primary`/
     `secondary` — misleading names, they're just whatever hue the
     generator happened to land on for those 2 roles this time, not
     reliably cyan/green). That last pair was added after the first
     version — series+ramp only — landed on `seriesPalette`'s `#e8a400`
     (hue 42°, into yellow) on a scheme where `scheme.secondary` happened
     to be `#ffb693` (hue 19°, genuinely orange) but wasn't in the search
     at all, reported "too yellow, doesn't match any theme color"
     2026-08-31. Both accent roles are just as legitimately
     theme-generated as the series/ramp swatches, so excluding them was
     the actual bug, not the closest-hue approach itself.
- `bar/ClaudeUsageExpanded.qml` — per-account session%/weekly% + reset
  countdown + its own "active processes" table (see above), plus the
  current poll tier/backoff countdown and staleness ("updated Ns ago").
  Wired into `Bar.qml`'s shared panel-row layout system (`panelOrder` etc.
  — see quickshell-bar.md) the same way `CalendarExpanded`/`MediaExpanded`
  are, **including** `shell.qml`'s `HyprlandFocusGrab`/`holdsFocus`
  machinery (`Bar.qml`'s `openPanelCount` and the `claudeUsageExpanded`
  instance's `onExpandedChanged` both include it) — first version left
  this out entirely, reasoning nothing here needed arrow-key nav, but
  Escape-to-close was requested and that needs the same real focus grab
  the other panels use. `root.Keys.onPressed` in `Bar.qml` handles Escape
  while this is the open panel; toggling again (or clicking the pill)
  still works too.

  **Taking that focus grab surfaced a separate, real bug in
  `shell.qml`'s input mask**, not this panel's own doing but only visible
  once something rendered this tall: the mask used to be one rectangle,
  full monitor *width* regardless of which panel was actually open,
  sized in height off the tallest currently-open panel
  (`bar.panelGridHeight`). Media/Calendar's typically-modest heights never
  pushed that rectangle far enough to matter, but `ClaudeUsageExpanded`
  routinely reaches close to full monitor height now (see "How many rows
  actually render" above) — meaning that one rectangle became nearly the
  *entire screen*, silently swallowing clicks meant for whatever window
  was underneath, anywhere on screen, not just behind the visible panel.
  Reported "block[s] everything" 2026-08-31. Fixed by splitting the mask
  into two unioned rectangles (`Region`'s default `regions` list combines
  by default — see `Intersection.Combine`): the always-full-width bar-pill
  strip (unchanged, just the compact bar height), plus a *second*,
  narrower rectangle only as wide as where an open panel actually renders
  (`Bar.qml`'s new `openPanelsLeftEdge` — the leftmost x of any expanded
  panel's own rectangle — to the screen edge). `bar.totalHeight`/`overflow`
  (the old combined-height figures the single-rectangle mask read) had no
  remaining reader after this split, so they were removed rather than left
  as dead code.
- `bar/ColumnResizeHandle.qml` — the drag-to-resize `MouseArea` used
  between every pair of columns in the process table's header row (see
  "Every column is independently resizable" above). Standalone, no
  dependency on `ClaudeUsageExpanded` beyond the `targetWidth`/
  `widthChangeRequested` contract, so it's reusable for any other
  RowLayout-based table that wants the same behavior.

## Keybind

`CTRL+ALT+c` (`keybinds.lua` → `scripts/bar-toggle.sh toggleClaudeUsage` →
`Bar.qml`'s per-monitor `IpcHandler`) — free since the calendar panel moved
off it to `mainMod+CTRL+c`.

## Active-processes hover-thumbnail investigation (2026-09-01)

Before building a hover-preview + click-to-focus feature on the
active-processes table, benchmarked two candidate capture paths for a
single on-demand window thumbnail: shelling out to `winswitch`'s existing
`wayland_capture.rs` (cold connection each call) vs. Quickshell's own
built-in `ScreencopyView`/`ToplevelManager` (`Quickshell.Wayland`,
in-process, no new binary).

**Result: they're the same speed** — both hit the same ~20-30ms wall,
because both go through the compositor's GPU→SHM copy
(`hyprland-toplevel-export-v1`; Quickshell's plugin also links
`ext_image_copy_capture_v1`/`zwlr_screencopy`, but the toplevel-export path
is what's actually used here). winswitch's client-side setup (fresh
`Connection::connect_to_env()` + 3 roundtrips to bind globals/enumerate/map
addresses) is only ~1-2ms of its ~21ms; the rest is the compositor, so
optimizing that setup further wouldn't have mattered. Quickshell skips
process-spawn + dynamic-link cost (~10-15ms), so it's modestly faster
end-to-end for a hover-panel use case (~28ms vs ~30-50ms wall for shelling
out), and can keep a view warm (`live: true`) for free subsequent frames.
**Decision: use `ScreencopyView` in-process, no separate Rust binary** —
this reverses the original plan to duplicate winswitch's capture code into
its own binary; that plan assumed only a separate process could hit
acceptable latency, which the benchmark disproved.

**False lead worth recording:** the very first attempt at this benchmark
looked *permission-blocked*, not just slow — `ToplevelManager.toplevels`
stayed empty and `ScreencopyView` never got a frame, which matches the
documented behavior that `hl.permission()` grants in `environment.lua`
require a full Hyprland restart to take effect (not `hyprctl reload`), and
`/usr/bin/quickshell` has no such grant there. That diagnosis was **wrong**.
Direct retest on the same running (non-restarted, still-ungranted)
compositor succeeded once two unrelated bugs in the *test script itself*
were fixed:
- **`ScreencopyView` needs a real rendering surface.** The first script
  used a bare `ShellRoot` with no window — `ScreencopyView` silently never
  gets a "recording context" without one. A `PanelWindow` (any real
  layer-shell surface, e.g. `WlrLayershell.layer: WlrLayer.Background`,
  need not be visible/sized meaningfully) fixes it; the warning to watch
  for is `Cannot capture frame, as no recording context is ready`.
- **`ToplevelManager.toplevels` populates asynchronously.** A single
  fixed-delay check (e.g. one 500ms `Timer`) can read it before Quickshell
  has synced the compositor's toplevel list and see `length: 0` even
  though nothing is actually blocked — confirmed by rerunning the identical
  capture with a short retry loop (`toplevel count: 0` on the first
  ~300ms poll, `38` on the second). Poll/retry (a repeating `Timer`, not a
  one-shot) rather than trusting a single fixed delay.
No `hl.permission()` entry for quickshell was added in the end — screencopy
via `ScreencopyView` works with quickshell's default (ungranted) permission
state on this setup.
