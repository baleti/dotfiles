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
  with a `$field:value` selector DSL (autocompleted, see below), keyboard
  nav, and an activate callback. Extracted from the original clipboard
  picker so other pickers can reuse the same window/search/filter
  machinery. `Entry::fields` is where a caller's named data lives (e.g.
  clipboard-picker's `type`/`date`, notification-picker's `app`/`date`);
  `PickerConfig::field_names` is what `$`-autocomplete offers. The DSL
  itself is a by-hand port of winswitch's `query.rs` (quote-aware
  tokenizing, subsequence field/value matching, the same
  `trailing_field_fragment`/`trailing_value_fragment`/`*_suggestions`
  shape) — see [query-dsl.md](query-dsl.md) for the full spec and for the
  one place this diverges from winswitch: bare (non-`$`) free words here
  join into a single literal phrase rather than ANDing independently, the
  original clipboard-picker behaviour, left as-is. Selection also follows
  a shared convention now: the list opens with nothing selected, the first
  arrow/Tab lands on the top visible entry, and `Enter` with nothing
  explicitly selected still activates it (see query-dsl.md's Design
  principles). The window carries a 1px accent frame (`window { border }`
  in the `CssProvider`, colour interpolated from `scheme.json`'s `primary`
  via `load_accent_hex` — GTK's `@accent_color` lives in the theme's own
  provider and won't resolve from here) so every picker built on the
  engine matches the quickshell launcher / rss reader cards.
- **`src/bin/clipboard-picker.rs`** (bound to `mainMod+V`) — cliphist picker
  on top of the engine; a Rust port of the older `scripts/clipboard-picker.py`
  that skips ~140ms of Python/GObject-introspection interpreter startup.
  Its `$type:image`/`$type:text` field is derived from cliphist's preview
  text (cliphist itself only distinguishes images, see `looks_like_image`).
  Its `$date:` field reads `~/.local/state/cliphist-expire/timestamps`, a
  log `cliphist-store-logged.sh` (wired into hyprland.lua's
  `wl-paste --watch`, replacing a direct `cliphist store` call) appends an
  exact copy-time to on every store — cliphist itself keeps none, see that
  script's own comment for how it correlates a log line to the id cliphist
  just assigned. `cliphist-expire.sh` prunes this log in step with
  whatever entries it expires.
- **`src/bin/notification-picker.rs`** (bound to `mainMod+CTRL+n`) — browses
  notifyd's retained notification history (`notifyctl list`) and invokes a
  chosen entry's action. Doesn't need dunst's old "redisplay before invoke"
  workaround since notifyd never discards a notification's actions on close.
  Its `$app:` field replaces what used to be a bare `$appname` selector;
  `$date:` needed no new plumbing since `notifyctl list` already reports a
  real per-notification `timestamp`.

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
- **`src/bin/sysmon-graph.rs`** — the standalone `ALT+mainMod+n/t/m`
  popups (net/temp/mem; the `cpu` mode still works but its bind was
  removed 2026-09-01), replacing the old KDE network-graph plasmoid.
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
- **`src/query.rs`** — the `/field:value` filter DSL (v2 — see
  [query-dsl.md](query-dsl.md), which covers this and every other
  implementation's syntax in full). Quote-aware whitespace-split tokens
  (a `"..."` run stays one token, letting a field/group name or value
  contain spaces); `/field:val` and nested `/group/sub:val` fuzzy-match
  both name and value independently (subsequence both ways); bare words
  substring-match title+class (subsequence instead, spanning whitespace,
  if quoted); multiple tokens AND together. Also carries three things that
  used to be elsewhere or didn't exist: `active_columns` (`/+path`/`/-path`
  column visibility, generalized here from focus-picker.py's v1-only
  `+$`/`-$`), `parse_actions`/`compare_with_direction` (`/sort`/`/reverse`,
  including the shape-aware comparator that handles plain-int and
  `humanize_ago`-bucket fields correctly — see query-dsl.md's "direction
  trap"), and `completion_context`/`completion_candidates`, one entry
  point covering the DSL's full five-stage autocomplete cascade (field/
  group/action name → visibility path → sort target → sort direction →
  filter value) that `ui.rs`'s suggestions popup is built on.
- **`src/enrich.rs`** — cross-references an open terminal window against
  the live tmux server and any Claude Code session running in it
  (`TmuxClaudeMeta`: `tmux/session`, `tmux/window`, `tmux/title`,
  `claude/title`, `claude/path`, `claude/session`, `claude/contents` —
  the `/group/sub` fields `query.rs` filters/sorts/displays on). Runs
  entirely off the main thread, spawned right after the grid's first
  paint, and streams results in via a channel polled every 50ms — the grid
  has to stay instant to open even if tmux is slow or a transcript is
  large, so nothing here is ever on the critical path. A panic inside the
  enrichment thread is caught and optionally logged (`touch
  ~/.cache/winswitch-enrich-debug`) rather than silently vanishing, since
  an unlogged panic there and "still enriching, give it a moment" look
  identical from the grid's side.
- **`src/ui.rs`** — the layer-shell `GtkFlowBox` grid. Two-phase key state
  machine: unlocked = Tab/Shift+Tab cycles selection, releasing Alt
  confirms; any other printable key locks into search mode
  (`GtkSearchEntry` + the `query.rs` DSL), Alt no longer confirms once
  locked, Enter/Escape confirm/cancel either way. A trailing `/fragment` at
  any of the DSL's five stages opens the shared autocomplete popup (a
  plain `GtkListBox` under the search entry, not a `GtkPopover` —
  gtk-layer-shell has no xdg_popup positioner to anchor one to):
  `Ctrl+j`/`Ctrl+k` move the highlight, `Tab` accepts it, `Escape`
  dismisses just the popup. See [query-dsl.md](query-dsl.md#autocompletion).
  Each cell's label is rebuilt from `active_columns` on every keystroke
  (`render_label`) instead of hardcoding workspace+title, so `/+`/`/-`
  actually changes what's shown. **Worth knowing before touching
  filtering/sorting/selection here**: since `/sort` can now visually
  reorder the grid, `FlowBoxChild::index()` (a child's *current* position)
  can no longer be trusted to mean "this window's index into
  `state.windows`" the way it always safely did before — every lookup from
  a child back to its window goes through `child_window_idx`, which reads
  a stable index stashed in the child's `widget_name` at creation instead.
  `state.selected` itself stays a *visual* grid position (what arrow keys
  spatially mean), resolved to an actual window only at the point of
  confirming (`confirm()`). The grid window carries the same 1px accent
  frame as the clipboard-picker engine (`window { border }`, colour from
  `scheme.json`'s `primary` via `load_accent_hex`) to match the quickshell
  launcher / rss reader cards.
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
