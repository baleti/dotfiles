# Rust tools

Four independent Cargo workspaces live under `~/.config/hypr/`, each built
to `target/release/<bin>` and invoked directly by path from
`keybinds.lua`/`hyprland.lua` (not installed to `PATH`). **After editing any
of these you must `cargo build --release` and restart the running
process** — stale binaries/daemons are a common source of "my change didn't
take" confusion here.

## clipboard-picker

`~/.config/hypr/clipboard-picker/` — GTK3 + wlr-layer-shell picker engine,
two binaries sharing it:

- **`src/picker.rs`** — the shared engine: a search box over a `GtkListBox`
  with `$type` selectors, keyboard nav, and an activate callback. Extracted
  from the original clipboard picker so other pickers can reuse the same
  window/search/filter machinery.
- **`src/bin/clipboard-picker.rs`** (bound to `mainMod+V`) — cliphist picker
  on top of the engine; a Rust port of the older `scripts/clipboard-picker.py`
  that skips ~140ms of Python/GObject-introspection interpreter startup.
- **`src/bin/notification-picker.rs`** (bound to `mainMod+CTRL+n`) — browses
  notifyd's retained notification history (`notifyctl list`) and invokes a
  chosen entry's action. Doesn't need dunst's old "redisplay before invoke"
  workaround since notifyd never discards a notification's actions on close.

Second press of the launching keybind closes the open picker (pidfile +
SIGTERM convention, shared with sysmon-graph below).

## notifyd

`~/.config/hypr/notifyd/` — replaces dunst as the notification daemon,
because dunst invalidates a notification's actions the instant it closes
(even on timeout), which made `mainMod+n`/`mainMod+CTRL+n` unable to ever
invoke an action after the popup left the screen. As of "Phase 10" it owns
the real `org.freedesktop.Notifications` bus name (earlier phases developed
against a throwaway name so dunst kept serving real notifications
untouched until this was verified).

- **`src/main.rs`** — D-Bus service. Its `method_call` closures must be
  `Send + Sync` (gio's binding requirement) even though everything runs on
  one thread, so the D-Bus side only ever touches `SharedState`
  (`Arc<Mutex<..>>`) and hands off to the GTK side via a
  `glib::MainContext` channel — GTK widgets aren't `Send`.
- **`src/state.rs`** — the single `Mutex`-guarded shared state.
- **`src/popup.rs`** — GTK3 + gtk-layer-shell rendering. One independent
  layer-shell surface per notification (stacked via top-margin), not one
  tall multi-notification surface like dunst — visually near-identical,
  much simpler.
- **`src/config.rs`** — `~/.config/hypr/notifyd/notifyd.toml`. Every field's
  `Default` reproduces the equivalent dunstrc value exactly, so an
  absent/partial config still matches prior tested behaviour. Some things
  are deliberately *not* config-driven (`follow` is always focused-monitor
  — a structural choice, not a value).
- **`src/dbus_names.rs`** — bus/path/interface constants shared with
  `notifyctl`, kept GTK-free so the CLI doesn't link GTK.
- **`src/bin/notifyctl.rs`** — control CLI (`invoke-last`, `list`, and four
  more subcommands over `org.hypr.notifyd1.Control`) — deliberately no
  CLI-parsing crate, plain `std::env::args()`.

Windowrule: notifyd's popups use layer-shell namespace `^notifyd$`, matched
by `windowrules.lua`'s `blur-notifyd` rule (layer surfaces don't inherit
`appearance.lua`'s blur automatically).

## sysmon

`~/.config/hypr/sysmon/` — two binaries over a shared protocol crate
(`src/lib.rs`), kept dependency-light (no GTK) so `sysmond` never links a
GUI toolkit.

- **`src/lib.rs`** — shared types. `Tier` enum (`10m/30m/6h/7d/7w/7mo`) —
  every raw 1s sample folds into all five tiers at once, each capped at
  `TIER_CAPACITY = 600` stored points by progressively coarser averaging as
  the tier's span grows. **`ALL_TIERS` array order is the persisted
  history.json index order, not display order — new tiers must be
  appended**, or an existing history.json stops loading by position. `10m`
  is the default tier everywhere a panel first opens.
- **`src/bin/sysmond.rs`** — background sampler, autostarted from
  `hyprland.lua`. Serves history over a Unix socket
  (`$XDG_RUNTIME_DIR/sysmond.sock`); no persistence beyond the tiered
  history file, this is throwaway monitoring data plus a bounded history.
- **`src/bin/sysmon-graph.rs`** — the standalone `ALT+mainMod+n/p/t/m`
  popups (net/cpu/temp/mem), replacing the old KDE network-graph plasmoid.
  Reads `sysmond`'s socket rather than sampling itself, so history is warm
  the instant it opens. Same toggle/pidfile/monitor-targeting conventions
  as clipboard-picker.

The quickshell bar's own hover graphs (`GraphPill.qml`,
[quickshell-bar.md](quickshell-bar.md)) read the **same** `sysmond` socket
via `TieredSocket.qml`/`SysmonSvc.qml` — one daemon, two independent UI
surfaces (in-bar vs standalone GTK popup). Top-process rows
(`topcpu`/`topmem`/`topnet`) carry a `detail` field (cmdline tail + `~`-cwd
+ pid) so otherwise-identical rows (e.g. multiple `claude` processes) stay
distinguishable.

**Socket reconnect gotcha**: quickshell's `Socket { connected: true }` is a
constant binding — if `sysmond` drops, the QML side never reconnects on its
own and graphs freeze silently until `qs` reloads. `TieredSocket.qml` and
`SysmonSvc.qml` each run a 2s `Timer` that re-asserts `connected` while
false; keep that pattern for any future `sysmond` socket consumer.

## winswitch

`~/.config/hypr/winswitch/` — grid-based Alt-Tab switcher with live window
thumbnails, bound to `ALT+Tab`/`ALT+SHIFT+Tab`.

- **`src/main.rs`** — decides whether this invocation opens the grid or
  (via `$XDG_RUNTIME_DIR/winswitch.sock`) just forwards a cycle command to
  an already-open instance. No pidfile — a successful `connect()` to the
  socket **is** the "already running" check.
- **`src/hyprctl.rs`** — thin `hyprctl` wrappers: the window list the grid
  is built from, and the one dispatch call that changes focus.
- **`src/query.rs`** — the `$column:value` filter DSL: whitespace-split
  tokens, `$col:val` fuzzy-matches column name and value independently
  (subsequence match), bare words substring-match title+class, multiple
  tokens AND together.
- **`src/ui.rs`** — the layer-shell `GtkFlowBox` grid. Two-phase key state
  machine: unlocked = Tab/Shift+Tab cycles selection, releasing Alt
  confirms; any other printable key locks into search mode
  (`GtkSearchEntry` + the `query.rs` DSL), Alt no longer confirms once
  locked, Enter/Escape confirm/cancel either way.
- **`src/wayland_capture.rs`** — live thumbnails via
  `hyprland-toplevel-export-v1`, on a wholly separate low-level
  `wayland-client` connection (GDK doesn't expose these extension
  protocols). Enumerates toplevels via
  `wlr-foreign-toplevel-management-unstable-v1`, resolves each to a
  Hyprland window `address` via `hyprland-toplevel-mapping-v1` (matched
  against `hyprctl clients -j`), then captures/streams decoded frames into
  the grid.
- **`src/protocol.rs`** — generated bindings from the vendored XML in
  `protocols/` (fetched from hyprwm/hyprland-protocols and
  swaywm/wlr-protocols, plus one staging protocol copied from the system's
  `wayland-protocols` package).

Needs the `screencopy` permission grant in `environment.lua` (see
[hyprland.md](hyprland.md)) to capture thumbnails at all.
