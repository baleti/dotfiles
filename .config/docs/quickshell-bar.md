# quickshell bar

`~/.config/quickshell/` — a from-scratch QML status bar, run as
`qs -n -d` (autostarted in `hyprland.lua`). Replaced caelestia-shell, then
replaced waybar (2026-08-27; waybar's own autostart line is now commented
out — see [desktop-apps.md](desktop-apps.md#waybar-legacy)). Layout
deliberately mirrors the old `~/.config/waybar/config.jsonc`: modules-left
(workspaces, submap indicator), modules-right (tray, media, controls,
network/cpu/mem/disk/temp, clock), each its own rounded pill/island. No
window-title module (removed 2026-08-27).

## Structure

```
quickshell/
├── shell.qml              entry point (ShellRoot)
├── background/Background.qml
├── bar/
│   ├── Bar.qml             per-monitor bar root
│   ├── Workspaces.qml, Submap.qml, Tray.qml
│   ├── Clock.qml, Media.qml, MediaExpanded.qml
│   ├── BatteryPill.qml, GraphPill.qml, CalendarExpanded.qml
├── osd/VolumeOsd.qml       side volume popup (mainMod+F11/F12)
├── components/             BarIcon, BarText, Graph, Pill (generic building blocks)
├── services/                BatterySvc, Players, SysmonSvc, TieredSocket
└── theme/                   Theme, Icons
```

## `shell.qml`

`ShellRoot` with one `Background {}` plus a `Variants` over
`Quickshell.screens` — one `PanelWindow` (top-anchored, `exclusiveZone: 38`)
per monitor, each embedding a `Bar { screen: ... }`. `implicitHeight: 800`
is fixed rather than reactively resized (resizing the real layer-shell
surface caused visible flicker on collapse); a `mask` region tracks
`bar.totalHeight` instead so clicks still pass through the empty area to
windows underneath. The media panel's `WlrLayershell.keyboardFocus` flips
`OnDemand`↔`None` with `mediaPanel.expanded`, so `mainMod+CTRL+m` gets real
keyboard control (arrow-seek, space play/pause) without ever permanently
grabbing input — it reverts to `None` the instant the panel closes. (Not
plain `mainMod+m` — that opens the memory graph panel instead; see
`hyprland.md`'s keybind list for why.)

## Background

`background/Background.qml` — one plain background-layer window per
monitor holding a static `Image`, sourced from the fixed path
`~/.local/state/quickshell/wallpaper.png`. No wallpaper manager
(hyprpaper/swaybg/swww) was ever set up on this system before this file —
confirmed by inspection (2026-08-26). No picker UI, transitions, or
audio-reactive effects — deliberately kept minimal. `scripts/set-wallpaper.sh`
is the only sanctioned way to change the source file; see
[theming.md](theming.md).

## Bar / hover panels

`GraphPill.qml` — the compact "icon + value" pill that expands downward
into a `Graph` (`components/Graph.qml`) on hover, backed by `sysmond`'s
rolling history via `services/SysmonSvc.qml`. Visually matches the
standalone `ALT+mainMod+n/p/t/m` `sysmon-graph` popups
([rust-tools.md](rust-tools.md)) since both read the same daemon.
`bar-toggle.sh` (`ALT+n`, `mainMod+t/s/m/p`, `mainMod+CTRL+c`) toggles these
panels open/closed per-monitor by talking to each `Bar` instance's own
`IpcHandler` target `bar-<screen name>` — one shared target would collide
across multi-monitor instances, so the toggle script resolves the focused
monitor's name first. The graph-widget entry keys also drop into a
per-widget `graph_<name>` Hyprland submap (`keybinds.lua`) where bare `1`-`6` jumps
straight to a tier via the new `bar-set-tier.sh` → `setXxxTier()` functions
on that same `IpcHandler` — see `hyprland.md` for the full submap writeup.

`services/TieredSocket.qml` — reconnects with a fresh `"<metric>:<tier>\n"`
request whenever `tier` changes, since `sysmond`'s protocol is
request-once-then-stream, not a live query parameter. Default tier is
`10m`; switching to `30m/6h/7d/7w/7mo` means closing and reopening the
connection, not sending a second request on the same stream.

**Both `TieredSocket.qml` and `SysmonSvc.qml` run a 2s re-connect `Timer`**
because quickshell's `Socket { connected: true }` is a constant binding —
if `sysmond` restarts or drops, the QML side never reconnects on its own
and the graphs silently freeze until `qs` itself reloads. Keep this pattern
for any new socket consumer.

## Theme

`theme/Theme.qml` (singleton) — a `FileView` on
`~/.local/state/quickshell/scheme.json` (`watchChanges: true`), the Material
You scheme `gen-theme.py` writes on every wallpaper change (see
[theming.md](theming.md)). Falls back to hardcoded values matching
`appearance.lua`'s cyan→green gradient if that file is missing, so the bar
still looks right before the theme script has ever run. `Theme.rampColor(f)`
maps a metric's 0..1 magnitude onto the scheme's 5-stop `intensityRamp`
(calm→hot); `Bar.qml` sets each pill's `valueFraction` from the live metric
value, so cpu/mem/net/disk/temp pills recolor by how "hot" they currently
are. `BatteryPill` inverts this (low charge = hot). `Graph.qml` draws flat
1px overlay lines, not gradient fills (rejected 2026-08-29); a `dashed`
field on a series means "de-emphasised twin" (drawn faded-solid at 0.62
alpha, not an actual dashed stroke) — used for tx/write/cached counterparts.
A many-series overlay (e.g. per-core CPU) renders as one faint envelope
wash, not per-series fills.

## Services

- **`SysmonSvc.qml`** — bar-side wrapper over the `sysmond` socket (see
  above); shared data source with the standalone `sysmon-graph` popups.
- **`BatterySvc.qml`** — feeds `BatteryPill.qml`; only shown while on
  battery power (see the `bar+theme` commit re-adding it).
- **`Players.qml`** — MPRIS player state for `Media.qml`/`MediaExpanded.qml`,
  including the phone bridge (`pixel6-mpris-bridge.py`, see
  [[android_companion_app_and_adb_setup]] memory).

## Related keybinds

See [hyprland.md](hyprland.md#keybinds-keybindslua) for the full bind list;
the bar-specific ones are `ALT+n` and `mainMod+t/s/m/p` (per-metric panel
toggle + `graph_<name>` tier submap), `mainMod+CTRL+m` (media panel +
`media_seek` submap), `mainMod+CTRL+c` (calendar panel + keyboard month/
year nav and year-picker, no submap needed), `mainMod+F11/F12` (volume, see
below), and the calendar/graph pills' own click-to-pin behavior (matching
each other, added 2026-08-28/29).

## Volume OSD

`osd/VolumeOsd.qml` — one click-through `PanelWindow` per monitor (own
`IpcHandler` target `volume-osd-<screen name>`, same per-monitor pattern as
`Bar`'s), showing an icon/bar/percent card near the right edge that
auto-hides after 1.2s. `scripts/playerctl-volume.sh` (`mainMod+F11/F12`)
adjusts volume — pixel6's MPRIS `Volume` property when it's the current
player (`playerctl-current`), the local sink otherwise — then calls
`display(percent, muted)` on whichever monitor the *active window* is on
(`hyprctl activewindow`'s monitor, not `hyprctl monitors`' "focused" field,
which tracks the mouse under this compositor's `follow_mouse=1`).

**Known issue (2026-08-29, unresolved):** the OSD's layer-shell surface
only reliably maps on one monitor here (DP-1) — confirmed via `hyprctl
layers` independent of anchoring style, layer level (`Top` vs `Overlay`),
`Variants` vs a single hardcoded instance, and a full `qs` process restart.
Looks like a Hyprland/wlroots-side per-output state issue, not a bug in
this file; testing further needs a full Hyprland restart (kills every
window on the machine), not done unilaterally. See the
`quickshell_panelwindow_ipc_gotchas` memory for the full investigation.
