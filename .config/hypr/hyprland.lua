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
-- from a later manual mainMod+N launch -- so it's a one-shot class->slug
-- lookup consumed on first match, rather than a persistent window rule.
local pending_hide = {}
for _, app in ipairs(apps) do
    pending_hide[app.class] = app.slug
end

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

    for _, app in ipairs(apps) do
        hl.exec_cmd(app.cmd)
    end
end)

require("environment")
require("appearance")
require("input")
require("keybinds")
require("windowrules")
