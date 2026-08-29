# Hyprland config

`~/.config/hypr/` — Lua-scriptable Hyprland config (this build exposes an
`hl.*` Lua API, not the stock `hyprland.conf` dispatch syntax). Entry point
is `hyprland.lua`, which `require()`s the rest in order:

```
hyprland.lua
├── environment.lua   env vars + permissions
├── monitors.lua      output layout
├── appearance.lua    borders, decoration, animations, gradients
├── input.lua         keyboard/touchpad/gestures/per-device
├── keybinds.lua       all binds
├── windowrules.lua    window/layer rules
└── rdp-guard.lua       xfreerdp keybind-passthrough guard
```

`apps.lua` is a shared data table (not `require()`d from `hyprland.lua`
directly) consumed by three of the above: `hyprland.lua` (autostart-hidden),
`keybinds.lua` (toggle/summon binds), and `windowrules.lua`-adjacent logic.

## Autostart (`hyprland.lua`, `hyprland.start` event)

Fires once per Hyprland session start (not on every config reload — that
distinction matters for the pinned-app hide logic, see the file's own
comments). Starts, in order:

1. `wl-paste --watch scripts/cliphist-store-logged.sh` — clipboard history,
   with `CLIPBOARD_STATE=sensitive` deliberately overridden (inside the
   wrapper script now, not inline here) so password-manager copies are
   still retained (retention is bounded by `cliphist-expire` instead, see
   below). Wraps a plain `cliphist store` call to also log an exact
   copy-time per entry, since cliphist itself keeps none — see
   [rust-tools.md](rust-tools.md)'s clipboard-picker entry for what reads
   that log (`$date:` in the picker's own query DSL).
2. `notifyd/target/release/notifyd` — see [rust-tools.md](rust-tools.md).
3. `sysmon/target/release/sysmond` — see [rust-tools.md](rust-tools.md).
4. `scripts/wallpaper-watch.sh` — see [theming.md](theming.md).
5. `xrdb -merge ~/.config/nsxiv/xresources` (if present) — loads nsxiv's X
   resources into XWayland immediately, since wallpaper-watch.sh might not
   fire again this session.
6. `scripts/wallpaper-rotate.sh` — rotates `~/wallpapers` every 6h (moved
   2026-08-29 from a 15-min "for now" testing cadence). Plain
   `hl.exec_cmd`/`sleep`-loop, not a systemd unit — see
   [theming.md](theming.md) for why, and what to reconsider if it's ever
   seen crashing.
7. `qs -n -d` — the quickshell bar. **waybar's autostart line is commented
   out here** (2026-08-27) in favor of this; see
   [desktop-apps.md](desktop-apps.md#waybar-legacy) for its current status
   and the rollback note.
8. Every `apps.lua` entry launches hidden into its own
   `special:scratch_<slug>` workspace (a one-shot class→slug table armed
   for `AUTOSTART_HIDE_GRACE_MS` = 120s, to avoid swallowing a later manual
   launch's window — see the file's comments for why arming has to happen
   inside the `hyprland.start` handler, not at file scope).

## Pinned app launchers (`apps.lua` + `keybinds.lua`)

`apps.lua` is a flat list of `{ key, slug, class, cmd }`, currently:
FSearch (1), Element (2), Thunderbird (3), GIMP (4), Signal (5, via
flatpak), Inkscape (6), Recoll (7). `mainMod+<key>` toggles each one through
`toggle_app()` in `keybinds.lua`: not-running → launch, hidden in scratch →
pull to current workspace + focus, on another workspace → switch to it
(without pulling), focused → hide to scratch. Multi-window apps (GIMP
dialogs) are treated as one unit so a summon/hide never splits the app
across workspaces.

## Environment (`environment.lua`)

- `XCURSOR_SIZE`/`HYPRCURSOR_SIZE=24`, `AQ_DRM_DEVICES` (multi-GPU: Intel +
  nvidia + displaylink), `QT_QPA_PLATFORMTHEME=kde`.
- `LC_TIME=en_GB.UTF-8` — a real Plasma session sources
  `~/.config/plasma-localerc` for this; Hyprland doesn't, so it's forced
  here to keep KDE apps' date columns in day/month order.
- `XDG_MENU_PREFIX=plasma-` — **load-bearing** for Dolphin/KIO default-app
  resolution. Without it, `kbuildsycoca6` builds an incomplete KSycoca cache
  and `KApplicationTrader::preferredService()` silently returns null, so
  Dolphin falls through to an empty xdg-desktop-portal-kde chooser instead
  of launching the configured default app. Must be present in the
  *querying* process's own environment, not just baked into the cache — see
  [[ksycoca_menu_prefix_poisoning]] memory for the runtime-heal command
  (`env XDG_MENU_PREFIX=plasma- kbuildsycoca6`).
- Permissions block (`hl.permission`, requires a full Hyprland restart to
  apply): screencopy allowed for `grim`/hyprshot, xdg-desktop-portal-hyprland,
  `wf-recorder`, and `winswitch`'s own binary (it captures live window
  thumbnails via `hyprland-toplevel-export-v1`); `plugin` allowed for
  `hyprpm`; `keyboard` allowed for `wtype`.

## Monitors (`monitors.lua`)

Laptop panel (`eDP-2`, 1920x1080@240, scale 1.5 → logical 1280 wide) on the
left, AOC 2470W on HDMI (1920x1080@60) at `1280x0`, Philips 241V8 on USB-C/DP
(1920x1080@60) at `3200x0`.

## Input (`input.lua`)

GB keyboard layout, `follow_mouse=1`, touchpad natural-scroll off, 3-finger
horizontal swipe = workspace switch, per-device sensitivity override example
for `epic-mouse-v1`.

## Window/layer rules (`windowrules.lua`)

- Suppress all maximize requests globally.
- Blur `notifyd`'s layer-shell popup namespace (`^notifyd$`) — layer
  surfaces don't inherit `appearance.lua`'s decoration blur automatically.
- XWayland drag fix (no-focus for empty-class/title floating XWayland
  windows).
- Float+position the `hyprland-run` launcher.
- Float+center the playerctl zenity picker.
- No-focus for `ArchitectJobAutomation`-classed windows — the headed
  Playwright/Chromium browser used by the job-search automation
  (`~/.local/share/architect-job-search/lib/browser.js`, not part of this
  repo), so it never steals focus while popping up mid-session.

## RDP focus guard (`rdp-guard.lua`)

xfreerdp is an XWayland client (confirmed via `ldd`/`hyprctl clients`), so
its own `XGrabKeyboard` can't stop Hyprland's global binds from
double-firing while a remote session has focus. The workaround: swap to an
empty submap (`rdp-guard`) whenever an `xfreerdp`-classed window becomes
active, which replaces the whole active bind set rather than adding to it,
so *every* global bind — not just known collisions — falls through as raw
input. `Pause` toggles the guard on/off (tap-to-release); the choice is
persisted to `~/.local/state/rdp-guard-enabled` so it survives focus
changes and Hyprland restarts. (Right Ctrl was tried first to match
xfreerdp's own release hotkey and never fired — reported upstream as
hyprwm/Hyprland#15952.)

## Keybinds (`keybinds.lua`)

Full list lives in the file; highlights not covered by their own project
docs:

- `mainMod+space/Q/E/R` — terminal/close/file-manager/menu.
- `mainMod+arrows` / `mainMod+hjkl` — focus; `mainMod+SHIFT+hjkl` /
  `mainMod+CTRL+hjkl` — move window in tiling / reflow position.
- `mainMod+SHIFT+[0-9]` — move window to workspace N.
- `CTRL+ALT+h/l` — step to prev/next workspace *on this monitor*
  (`r-1`/`r+1`, monitor-relative so it never hops to a workspace shown on
  another monitor).
- `mainMod+G` / `[`/`]` / `SHIFT+G` — window groups (tabs): toggle,
  prev/next, lock-active.
- `mainMod+f` — fullscreen (maximized mode, toggle).
- `mainMod+A` — global-menu prototype: flattens the focused window's AT-SPI
  accessible menu tree into a rofi picker (`scripts/appmenu-atspi.py`).
  Coverage depends on the app exposing a real a11y tree — confirmed with
  LibreOffice; see [desktop-apps.md](desktop-apps.md) for the
  `--force-renderer-accessibility`/`GNOME_ACCESSIBILITY=1` overrides that
  make Brave/LibreWolf expose theirs.
- `Print` — `hyprshot -m region -r | satty ...`.
- Media/volume/brightness keys — `wpctl`/`brightnessctl`/`playerctl`, plus a
  restored-from-KDE 5s seek pair with a "kick" removed as unnecessary (see
  `scripts/playerctl-seek.sh`'s header — confirmed actively harmful for the
  phone bridge).
- `mainMod+CTRL+SHIFT+p/x/z` and friends — playerctl against
  `~/.config/playerctl-current`, the "currently selected player" file
  written by `scripts/playerctl-picker.sh` (`ALT+CTRL+SHIFT+m`).
- `mainMod+V` / `mainMod+CTRL+n` — clipboard/notification pickers (the Rust
  binaries; see [rust-tools.md](rust-tools.md)).
- `mainMod+n` / `mainMod+SHIFT+n` — invoke last notification's default
  action / open its full action list.
- `ALT+mainMod+n/p/t/m` — standalone `sysmon-graph` popups.
- Bare `ALT+n` and `mainMod+t/s/m/p` — toggle the quickshell bar's own
  in-bar hover panels (net stayed on `ALT`; temp/disk/mem/cpu on `mainMod`;
  same `sysmond` data as the popups above, different UI surface) via
  `scripts/bar-toggle.sh`, **and** enter a per-widget `graph_<name>` submap
  (`keybinds.lua`): while active, bare `1`-`6` (no modifier) jumps straight
  to that panel's `10m/30m/6h/7d/7w/7mo` history tier via
  `scripts/bar-set-tier.sh` → `Bar.qml`'s `setXxxTier()` IpcHandler
  functions. `Escape` or the entry key again exits. `mainMod+p` used to be
  dwindle `window.pseudo()` — dropped entirely (told to) so CPU could move
  there. `mainMod+n` is still notify-invoke-last (pre-existing, not given
  up), so net stayed on `ALT+n` but still gained the tier submap.
- `mainMod+CTRL+c` — toggle the calendar panel (moved from `CTRL+ALT+c`).
  No submap — it gets real keyboard focus instead (same mechanism as the
  media panel below), so bare keys reach it directly:
  `Left/Right` = prev/next month, `Up/Down` = prev/next year, `Tab` enters
  a year-picker (a 10-cell grid at one of four spans — 10/20/50/100 years
  total, so 1/2/5/10 years per cell — `Left/Right` move the highlight,
  `Up/Down` zoom out/in a level re-centered on it, `Enter` drills into a
  coarse cell or confirms a single year, `Escape`/`Tab` cancel back
  unchanged), `Escape` closes the panel. See `CalendarExpanded.qml`.
- `mainMod+CTRL+m` — media widget + a `media_seek` submap: bare `0`-`9`
  jumps to that decile of the current track (`playerctl-seek-percent.sh`,
  against whichever player `~/.config/playerctl-current` names). Not plain
  `mainMod+m` — that's the mem graph panel above; a real simultaneous
  multi-key chord isn't expressible in Hyprland binds, so a submap (press
  the entry combo once, then tap keys freely) is the general pattern used
  for the tier/seek widgets above instead. Calendar doesn't need one since
  it gets real keyboard focus (see above).
- `mainMod+F11/F12` — volume down/up. Routes to pixel6's MPRIS `Volume`
  property (`scripts/pixel6-mpris-bridge.py`) instead of the local sink
  when `playerctl-current` names it, and flashes a side OSD
  (`quickshell/osd/VolumeOsd.qml`) on the *active window's* monitor (not
  `hyprctl`'s own "focused" monitor — this compositor runs
  `follow_mouse=1`, so those can differ). The OSD currently only reliably
  renders on one monitor (DP-1 here) — a `hyprctl layers` per-output
  layer-shell issue that survived a full `qs` restart, not a bug in the
  QML; see `quickshell-bar.md`.
- `ALT+Tab` / `ALT+SHIFT+Tab` — winswitch grid alt-tab.
- `mainMod+b` — `killall -SIGUSR1 waybar` (legacy — see
  [desktop-apps.md](desktop-apps.md#waybar-legacy)).

## Scripts (`hypr/scripts/`)

Small, mostly single-purpose bash/python glue invoked by the binds/autostart
above:

| Script | Purpose |
|---|---|
| `bar-toggle.sh` | Resolves the focused monitor's quickshell `Bar` instance and toggles one of its hover panels via its per-monitor `IpcHandler` target |
| `cliphist-expire.sh` | Age-based expiry for cliphist (no timestamps in cliphist's DB, so a monotonic-id watermark recorded each run stands in for "older than N hours"); driven by `cliphist-expire.timer`/`.service` |
| `notifyd-actions-menu.sh` | rofi picker over one notification's actions (replaces `dunstctl context`) |
| `playerctl-picker.sh` | zenity player picker for `ALT+CTRL+SHIFT+m`; never truncates `playerctl-current` on cancel (a bug in the old one-liner it replaced) |
| `playerctl-seek.sh` | 5s seek without a pause/play "kick" — confirmed unnecessary and harmful for the phone MPRIS bridge |
| `set-wallpaper.sh` | The *sole* sanctioned way to change the wallpaper — see [theming.md](theming.md) |
| `wallpaper-cycle.sh` / `wallpaper-rotate.sh` / `wallpaper-watch.sh` | See [theming.md](theming.md) |
| `waybar-mpris.sh` | waybar's mpris module poller — legacy, see [desktop-apps.md](desktop-apps.md#waybar-legacy) |
| `appmenu-atspi.py` | AT-SPI → rofi global menu (`mainMod+A`) |
| `clipboard-picker.sh`, `clipboard-picker.py` | Superseded pickers (wofi-based, then GTK3+layer-shell) — **not** what `mainMod+V` runs today; that binds directly to the Rust `clipboard-picker` binary. Kept in tree, not archived. |
| `gen-theme.py`, `pixel6-mpris-bridge.py` | Own docs: [theming.md](theming.md), [[android_companion_app_and_adb_setup]] memory |

## Systemd units tracked in this repo

Only two systemd user units live in the git repo (everything else under
`~/.config/systemd/user/` — backups, mail sync, the flight tracker,
peer-agent, rclone/restic mounts — is local-only, not tracked):

- `cliphist-expire.service` + `.timer` — runs `cliphist-expire.sh` every 15
  minutes (`OnCalendar=*:0/15`), finer than the 3h expiry window needs on
  its own so no entry can live past ~4h under the watermark scheme.
- `pixel6-mpris-bridge.service` — see [[android_companion_app_and_adb_setup]]
  memory; not itself part of this repo's Rust/QML projects, it's the
  desktop-facing half of the PeerAgent Companion Android app.
