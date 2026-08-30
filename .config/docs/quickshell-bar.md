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

## Panel width sizing

Every popup panel that pops out of the bar — `CalendarExpanded`,
`MediaExpanded`, and all 5 `GraphPill` expand panels (net/cpu/mem/disk/
temp) — shares **one** dynamic-width layout system in `Bar.qml`, always on
a single row, not per-panel hardcoded pixel widths or separate positioning
math. This used to be two independent systems (media/calendar ran a
single-row `stackRight` sweep with no left-edge clamp, while the 5 graph
pills had their own row-*wrapping* system added 2026-08-29); the two
disagreeing about a panel's real width/position once panels from both
groups were open together is what let a panel get pushed off the left edge
of the screen, and let calendar render directly on top of an open graph
panel instead of shifting clear of it (both reported 2026-08-30) — merged
into one system rather than patched independently again. A row-wrapping
version of the merged system was tried next and rejected (reported
2026-08-30, unusable) — **there is deliberately no second row**: every
open panel always shares the one row, and width just divides evenly among
however many are open, shrinking with no floor-triggered fallback. All 7
open at once on a ~1920px monitor lands around 260px each; that's
considered an acceptable, rare edge case (see `Bar.qml`'s comment on
`openPanels` for why spilling onto a neighboring monitor's own bar was
floated and deliberately skipped — it would need real IPC between separate
per-monitor `Bar.qml` instances, since each one's layer-shell surface is
tied to a single output).

`Bar.qml`'s `panelOrder` (`["media", "net", "cpu", "mem", "disk", "temp",
"calendar"]`, bar-visual left-to-right order — calendar's trigger is the
clock, the rightmost item) is the single ordering the whole system is built
on:

- `openPanels`/`openCount` — which of those 7 are currently expanded.
- `rowRightAnchor` — the rightmost open panel's own natural pill position
  (not the raw screen edge — see its comment for why that overstated
  available room and ran the leftmost panel off the left edge).
- `panelWidth` — one shared width every open panel gets: divides
  `panelAreaWidth` evenly among `openCount`, clamped only against
  `maxPanelWidth` (560px, the one-panel-alone case) and a `minPanelWidth`
  sanity floor (40px, not a legibility target — there's nowhere left to
  wrap to).
- `layoutFor(name)` — `{right}` for one open panel: panels fill
  right-to-left within the row, matching the pills' own left-to-right order
  in the bar.
- `overflowHeightFor(name)`/`panelYFor(name)` — each panel's own current
  expand height (`GraphPill.overflowHeight`, or plain `.height` for
  `MediaExpanded`/`CalendarExpanded`, since their `implicitHeight` already
  collapses to 0 when not expanded); `panelYFor` is just the shared
  `panelY` baseline now (kept as a named function, not inlined at each
  binding site, so a future panel kind that genuinely needs to differ has
  one place to change).
- `panelGridHeight` — the tallest currently-open panel's own expand height;
  this is `overflow` (and so `totalHeight`) directly.

Every panel binds to this the same way: `GraphPill`'s `expandWidth`/
`targetRight`/`targetY` and `CalendarExpanded`/`MediaExpanded`'s own
`panelWidth`/`x`/`y` all read `root.panelWidth`/`root.layoutFor(name).right`/
`root.panelYFor(name)`. A future single-instance popup panel should become
a member of this same pool (add its name to `panelOrder`, wire
`panelExpandedFor`/`naturalRightFor`/`overflowHeightFor` for it, bind its
width/position the same way) rather than inventing its own sizing or
positioning — that's exactly the split that caused the bug this section
describes.

**This is a different problem from winswitch's Alt-Tab grid sizing**
(`~/.config/hypr/winswitch/src/ui.rs`'s `grid_dims`/`typical_aspect`, see
[rust-tools.md](rust-tools.md#winswitch)): that one packs an *unknown
number of items of varying aspect ratio* into a grid and picks a column
count to match their shape. This one shares a fixed, screen-relative width
pool among a handful of named, fixed-content panels, always on one row. A
future widget that lays out N variable-aspect items in a grid (a dock, a
gallery, another picker) should port winswitch's algorithm instead of this
one.

**Restarting after a structural edit to `Bar.qml`:** quickshell's hot
reload only re-binds *expressions*; it doesn't recreate already-running
root object instances. Renaming or removing a root-level `function`/
`property` (as this system's own refactors did twice, 2026-08-30) leaves
long-running instances' meta-objects stuck with the old names — `qs log`
shows `TypeError: Property 'x' ... is not a function` and `Unable to
assign [undefined] to double` even though the file on disk is correct.
Fix: `qs kill` then relaunch the same way `hyprland.lua` does
(`qs -n -d`) — a plain value/expression change never needs this, only a
changed function/property *signature*.

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
