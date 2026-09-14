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
    -- wl-clip-persist, notifyd and sysmond used to be started here via
    -- hl.exec_cmd -- moved to systemd --user units (2026-09-13) so a crash
    -- gets Restart=always instead of staying dead until the next full
    -- Hyprland restart. WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE are
    -- confirmed present in `systemctl --user show-environment` and in the
    -- environ of already-running graphical-session.target-gated units
    -- (desktop-snapshot.service, claude-usage.service), so the Wayland
    -- connection at startup isn't a race here. See:
    --   ~/.config/systemd/user/wl-clip-persist.service
    --   ~/.config/systemd/user/notifyd.service -- owns
    --     org.freedesktop.Notifications, replaced dunst (dunst's package is
    --     untouched, its unit masked; rollback: `systemctl --user disable
    --     --now notifyd`, re-enable `dunst.service`). Headless since
    --     2026-08-30 -- cards are drawn by quickshell
    --     (~/.config/quickshell/notifications/, off
    --     ~/.cache/notifyd/state.json).
    --   ~/.config/systemd/user/sysmond.service -- feeds the bar's
    --     hover-graphs and the alt+mod+n/p/t/m popups. Every consumer
    --     (SysmonSvc's TieredSocket/ProcHistSocket and its topCpu/Mem/Net/
    --     Disk sockets) already carries a 2s reconnect timer (2026-08-29,
    --     a5240aede1) that re-asserts `connected = true` while wanted, so a
    --     sysmond restart is picked back up on its own -- no `qs kill`
    --     needed.
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
require("winswitch")
require("dolphin-vim")
