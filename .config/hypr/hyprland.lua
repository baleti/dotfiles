-- Main Hyprland config entry point.
-- See https://wiki.hypr.land/Configuring/Start/

---------------------
---- MY PROGRAMS ----
---------------------

terminal    = "alacritty"
fileManager = "dolphin"
menu        = "hyprlauncher"
mainMod     = "SUPER" -- Sets "Windows" key as main modifier

-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

local apps = require("apps")

-- Pinned app launchers (see apps.lua) are started hidden. This must only
-- apply to the windows opened by *this* autostart batch -- not to windows
-- from a later manual mainMod+N launch, and not to a dialog of an app that
-- is already running -- so it's a one-shot class->slug lookup consumed on
-- first match, rather than a persistent window rule.
--
-- Two things keep that "one-shot" honest, and both are load-bearing:
--   * the table is armed inside hyprland.start, not at file scope, because a
--     config reload re-runs this file but does not re-fire that event. Arming
--     at file scope re-armed every pinned class on each reload, so the next
--     window of such a class -- typically a dialog of a long-running app, e.g.
--     GIMP's "save before closing?" prompt -- silently vanished into the
--     scratch workspace.
--   * it expires, because an app that never maps a window at login (crashed,
--     not installed, quit before mapping) would otherwise leave its class
--     armed for the whole session, swallowing the window of a manual
--     mainMod+N launch hours later and making that launch look like a no-op.
-- The grace period only has to outlast this batch mapping its windows; the
-- flatpak/Electron apps here are the slow ones on a cold boot.
local AUTOSTART_HIDE_GRACE_MS = 120000

local pending_hide = {}
local autostart_hide_timer = nil -- kept referenced: a collected timer never fires

hl.on("window.open", function(win)
    local slug = pending_hide[win.class]
    if slug then
        pending_hide[win.class] = nil
        hl.dispatch(hl.dsp.window.move({ workspace = "special:scratch_" .. slug, window = win, follow = false }))
    end
end)

hl.on("hyprland.start", function()
    -- wl-paste tags copies flagged x-kde-passwordManagerHint=secret (app
    -- passwords, generated passwords, TOTP codes, etc.) with
    -- CLIPBOARD_STATE=sensitive, and cliphist silently skips storing those.
    -- The wrapper below deliberately overrides that too, so everything
    -- still lands in history -- retention is bounded instead by
    -- ~/.config/hypr/scripts/cliphist-expire.sh (see cliphist-expire.timer).
    --
    -- Routed through cliphist-store-logged.sh rather than `cliphist store`
    -- directly (as this used to be, via `exec` so wl-paste's stdin passed
    -- straight through) because cliphist itself keeps no per-entry
    -- timestamp - the wrapper also appends one to a small log, which is
    -- what clipboard-picker's $date: field reads from. See that script's
    -- own comment for how it correlates a log line to the right id.
    hl.exec_cmd([[wl-paste --watch ~/.config/hypr/scripts/cliphist-store-logged.sh]])
    -- notifyd owns org.freedesktop.Notifications. Replaced dunst
    -- (~/.claude2/plans/silly-percolating-rose.md): dunst invalidates a
    -- notification's actions the instant it closes, so mod+n / ctrl+mod+n
    -- could never invoke one after it left the screen; notifyd never
    -- discards that. Headless since 2026-08-30 -- the cards are drawn by
    -- quickshell (~/.config/quickshell/notifications/, off
    -- ~/.cache/notifyd/state.json). Rollback to dunst: revert this line to
    -- hl.exec_cmd("dunst") (the package is untouched, its unit masked).
    hl.exec_cmd("~/.config/hypr/notifyd/target/release/notifyd")
    -- Background sampler for the bar's hover-graphs and the alt+mod+n/p/t/m
    -- standalone popups (~/.config/hypr/sysmon). keybinds.lua's comments
    -- already claimed this was autostarted here -- it wasn't; this was
    -- only ever running because a dev-session build of it was left up.
    hl.exec_cmd("~/.config/hypr/sysmon/target/release/sysmond")
    -- Resident app-launcher daemon (~/.config/hypr/applauncher/): builds its
    -- wlr-layer-shell card once, then just shows/hides it on a socket
    -- message from `applauncher toggle` (mod+Super_l, see keybinds.lua).
    -- Replaced the quickshell launcher.
    hl.exec_cmd("~/.config/hypr/applauncher/target/release/applauncher")
    -- Load the theme's nsxiv colors (Nsxiv.* X resources) into the XWayland
    -- server now -- gen-theme.py also does this on every regen, but the
    -- wallpaper (hence that script) may not have changed yet this session.
    hl.exec_cmd("[ -f ~/.config/nsxiv/xresources ] && xrdb -merge ~/.config/nsxiv/xresources")
    -- Rotates through ~/pictures every 15 minutes via set-wallpaper.sh --
    -- a "for now" testing cadence (2026-08-28) to exercise the automatic
    -- re-theming above, not a considered final value. Remove this line to
    -- go back to a single static wallpaper.
    hl.exec_cmd("~/.config/hypr/scripts/wallpaper-rotate.sh")
    -- 2026-08-27: replaced by a custom quickshell bar (~/.config/quickshell/),
    -- built from scratch after trying and reverting caelestia-shell. Revert:
    -- uncomment this line, and kill/disable `qs -n -d` if it's running.
    -- hl.exec_cmd("waybar")
    hl.exec_cmd("qs -n -d")

    for _, app in ipairs(apps) do
        pending_hide[app.class] = app.slug
        hl.exec_cmd(app.cmd)
    end

    autostart_hide_timer = hl.timer(function()
        pending_hide = {}
    end, { timeout = AUTOSTART_HIDE_GRACE_MS, type = "oneshot" })
end)

require("environment")
require("monitors")
require("appearance")
require("input")
require("keybinds")
require("windowrules")
require("rdp-guard")
require("dolphin-vim")
