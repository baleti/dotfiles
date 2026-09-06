# tmux/Hyprland disaster recovery: what we learned 2026-09-06

Findings from actually exercising [[desktop-snapshot]] + tmux-resurrect
after a real session-loss incident, for the first time. Supersedes the
"UNEXERCISED" caveat in `restore_plan.py`'s docstring for the pieces
covered here.

## The incident had two separate causes, not one

1. **~14:22** - the real mass-loss event. An old, untracked
   `tmux.service` (forking, `ExecStop=kill-server`) got pulled in by a
   `Wants=` dependency from a *new* systemd unit and killed the live
   server, taking ~107 sessions / 151 panes with it. Root cause and fix
   already covered by [[tmux_service_execstop_kill_server_footgun]] -
   this doc is about recovering the content, not that bug.
2. **~15:54**, over an hour later - a separate, deliberate `sudo reboot
   -h now` run from a live pane. Unrelated to (1); by this point only a
   handful of sessions existed (rebuilt since the fix), so it's a much
   smaller loss. Don't conflate the two when reading logs - `journalctl
   --list-boots` and `who -b` disambiguate a reboot from a service kill.

Lesson: when diagnosing "everything died," check `journalctl -u
tmux.service` around the actual drop in `desktop-snapshot`'s
`tmux.sessions` count, not just the most recent boot.

## Picking which resurrect snapshot to restore from

`~/.tmux/resurrect/last` and `pane_contents.tar.gz` reflect whatever was
saved *most recently* - which after a crash is often a near-empty
post-crash state, not the rich pre-crash one you want. The daemon here
also saves periodically (`snapshot.py daemon --resurrect-interval 300`),
so `last` can drift forward from under you mid-recovery (see gotcha
below).

Correct approach: pick the newest `pane_contents_<ts>.tar.gz` under
`~/.tmux/resurrect/pane_contents_history/` from *before* the crash
timestamp, then find the layout file
`tmux_resurrect_<ts>.txt` with the closest-preceding timestamp. This is
exactly what `~/.config/tmux/scripts/resurrect-restore-picker.sh` (bound
to prefix+C-r) already automates interactively via fzf - use it when
attached to a live client. When restoring from a detached/scripted
context instead:

```sh
d=~/.tmux/resurrect
cp -f "$d/pane_contents_history/pane_contents_<good-ts>.tar.gz" "$d/pane_contents.tar.gz"
ln -sf "tmux_resurrect_<good-ts-or-earlier>.txt" "$d/last"
```

Back up the live files first (they're small) rather than trusting you
can reconstruct them - `cp` to `pane_contents_history/` under a "now"
timestamp is what the interactive picker itself does before swapping.

## Gotcha: desktop-snapshot.service will clobber your staged files mid-recovery

`desktop-snapshot.service` runs `snapshot.py daemon --resurrect-interval
300` - every 5 minutes it calls tmux-resurrect's `save.sh` against
*current* (post-crash, sparse) state, overwriting `pane_contents.tar.gz`
and repointing `last`. If a manual recovery takes more than ~5 minutes
(it will), the daemon undoes your staging partway through with no
warning.

**`systemctl --user stop desktop-snapshot.service` before touching
`~/.tmux/resurrect/*` by hand, every time.** Restart it only after the
restore is fully verified.

## Gotcha: tmux-resurrect's restore.sh silently targets the wrong server when run detached

`scripts/helpers.sh`'s `tmux_socket()` is `echo $TMUX | cut -d',' -f1`.
`new_session()` (used for the *first* pane of each session) explicitly
does `TMUX="" tmux -S "$(tmux_socket)" new-session ...`. If you invoke
`restore.sh` from a shell that isn't attached to any tmux client, `$TMUX`
is empty, `tmux_socket()` returns `""`, and `-S ""` makes tmux bind an
**abstract-namespace socket** - a second, fully separate, real tmux
server that `tmux list-sessions` (default socket) will never show you.
Every session appears to restore fine (no errors beyond "no current
client" from unrelated title-setting calls), but they all land on this
invisible server. `new_window`/`new_pane` don't override `-S`, so they
correctly hit the real default socket - which is exactly why they then
fail with "can't find session: X" for sessions that only exist on the
phantom one.

**Fix**: export a `TMUX` value that resolves to the real socket before
invoking restore.sh from a detached context:

```sh
export TMUX="/tmp/tmux-$(id -u)/default,0,0"
bash ~/.tmux/plugins/tmux-resurrect/scripts/restore.sh
```

Diagnose this class of bug in general via `lsof -U 2>/dev/null | grep
tmux` - a second `tmux:` LISTEN entry with an abstract (`@`-prefixed, per
lsof's rendering of a leading NUL) address instead of a real path is the
tell. `TMUX="" tmux -S "" list-sessions` reconnects to it directly if you
need to inspect or `kill-server` it.

## Mapping a restored tmux pane back to its exact `claude --resume` UUID

`account_for_config_dir()` in `snapshot.py` labels a pane's Claude
account (`claude`/`claude2`/`claude3`) from `CLAUDE_CONFIG_DIR`, but
**the `-home-user1` project directory is the same inode under all three
`~/.claude*/projects/`** (verified via `stat -c %i`) - all accounts
share one transcript pool for a given cwd. Since most panes share
`cwd=/home/user1`, account + cwd cannot disambiguate which of several
concurrently-open sessions in that directory belongs to which pane.

The reliable source instead: `~/.tmux/resurrect/pane_contents_history/*.tar.gz`
captures each pane's actual on-screen scrollback, and Claude Code's
footer renders an OSC-8 hyperlink to
`https://claude.ai/code/session_<id>` for the active conversation. That
same `<id>` appears verbatim in the session's own jsonl transcript as
`"bridgeSessionId":"cse_<id>"`, sitting next to `"sessionId":"<uuid>"` -
the UUID `claude --resume` actually takes. So:

```sh
tar -xzf pane_contents_<ts>.tar.gz -C /tmp/x ./pane_contents/pane-<session>:<window>.<pane>
grep -o 'session_[A-Za-z0-9]*' /tmp/x/pane_contents/pane-<session>:<window>.<pane> | tail -1
grep -rl '<that-id>' ~/.claude3/projects/-home-user1/*.jsonl   # -> the real --resume uuid is the filename
```

This is exact, not inferred from timing/cwd - safe to script. One caveat
if scripting a *live* investigation this way: grepping for an ID you
just read out loud in the same Claude Code session will also match that
session's own transcript file (it now contains the ID as tool-output
text) - exclude the current session's own jsonl from candidate matches.

## Placing Alacritty windows on the right workspace/monitor without stealing focus

This Hyprland build is Lua-scriptable
([[hyprland_lua_binding_dispatch_syntax]]) - dispatch via `hyprctl eval`
+ `hl.dsp.*`, not stock `hyprctl dispatch`.

Verified safe (activewindow and every monitor's visible
`activeWorkspace` unchanged before/after, checked directly rather than
assumed):

- `hl.dsp.exec_cmd("[workspace N silent] <cmd>")` - spawns without
  stealing keyboard focus or changing what's currently on-screen
  anywhere, **but** a workspace that doesn't exist yet gets created on
  whatever Hyprland currently considers the focused monitor (tied to
  mouse position under `follow_mouse=1`), not any monitor you intended.
- `hl.dsp.workspace.move({ workspace = N, monitor = "NAME" })` -
  re-pins an *existing* workspace to a specific monitor. Despite
  flipping the monitor's `focused` boolean in `hyprctl monitors -j`,
  this does **not** move keyboard focus (`hyprctl activewindow`
  unchanged) and does **not** change any monitor's visible
  `activeWorkspace` - the `focused` flag here is cosmetic bookkeeping,
  not real input focus. Confirmed by checking `activewindow` directly
  before/after, not by inference.
- `hl.dsp.window.move({ workspace = N, window = w, follow = false })`
  (`w` from `hl.get_windows({})`, matched by `.pid`) - relocates one
  *existing* window without touching focus. Already the pattern used by
  this config's own scratchpad-toggle keybind
  ([[hyprland_lua_binding_dispatch_syntax]]) - reach for it first
  instead of rediscovering it under time pressure.

Correct order per target workspace, since **Hyprland auto-destroys a
workspace the moment its last window closes** (non-persistent,
`ispersistent: false`), which silently undoes any monitor pinning done
before that point:

1. Spawn *all* windows for that workspace first via
   `[workspace N silent]` (no monitor targeting yet - don't care which
   monitor it transiently lands on).
2. Only once real content lives there, pin the monitor once with
   `hl.dsp.workspace.move`.
3. Never let a target workspace go back to zero windows between steps 1
   and 2 (e.g. don't kill a placeholder/test window in it) - that
   destroys it and any later spawn recreates it on the wrong monitor
   again, requiring a repeat of step 2.

### Tiling order, not absolute position

Hyprland doesn't expose a direct "tiling tree order" IPC call, and
raw pixel coordinates (`at`/`size` from `hyprctl clients -j`) don't
survive a monitor swap or resolution change anyway. But for the
`master` layout, a freshly spawned window becomes master if its
workspace was empty, otherwise it joins the stack - so **replaying
spawns in the same relative order reproduces the layout**, with no
coordinates needed at all.

`snapshot.py` derives this at capture time: within each workspace, sort
its windows left-to-right/top-to-bottom (master conventionally occupies
the leftmost/largest area, stack members ordered top-to-bottom to its
right) and store the resulting rank as `tile_order` on each client. On
restore, sort by that rank before spawning, per workspace - master-layout
placement then falls out for free.

Session -> workspace -> monitor mapping comes from a **pre-crash**
`desktop-snapshot` JSON's `hyprland.clients[].tmux_session` (already
computed by `snapshot.py`'s tty-ownership matching) joined against
`hyprland.workspaces[].monitor`. A post-crash snapshot has none of this,
so keep/back up the last few pre-crash snapshots rather than relying on
`latest.json` once trouble starts.

## Recovery order (validated end to end for a single workspace)

1. `systemctl --user stop desktop-snapshot.service`
2. Stage the pre-crash `pane_contents.tar.gz` + `last` symlink (see
   above), backing up the live ones first.
3. `export TMUX="/tmp/tmux-$(id -u)/default,0,0"; bash
   .../tmux-resurrect/scripts/restore.sh` - restores all sessions/panes
   with pre-crash scrollback onto the real server.
4. Build the session -> workspace -> monitor table from a pre-crash
   `desktop-snapshot` JSON.
5. Per workspace: spawn `alacritty -e tmux attach -t <session>` for
   every session mapped to it (`[workspace N silent]`, no monitor
   bracket), then pin the workspace's monitor once via
   `hl.dsp.workspace.move`.
6. Only for sessions where the actual Claude conversation (not just the
   tmux pane) needs resuming: resolve the `--resume` UUID via the
   pane-contents OSC-8 footer method above, then run `claude --resume
   <uuid>` inside the now-attached pane.
7. Restart `desktop-snapshot.service` once fully verified.

Test this on one workspace before batching all of them - confirm
`activewindow`/`activeWorkspace` are unaffected on your own machine's
config before trusting the general claim above on a different box.
