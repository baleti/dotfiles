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
    hl.exec_cmd("wl-paste --watch cliphist store")
    hl.exec_cmd("dunst")
    hl.exec_cmd("waybar")

    for _, app in ipairs(apps) do
        pending_hide[app.class] = app.slug
        hl.exec_cmd(app.cmd)
    end

    autostart_hide_timer = hl.timer(function()
        pending_hide = {}
    end, { timeout = AUTOSTART_HIDE_GRACE_MS, type = "oneshot" })
end)

require("environment")
require("appearance")
require("input")
require("keybinds")
require("windowrules")
