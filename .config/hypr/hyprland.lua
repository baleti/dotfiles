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

hl.on("hyprland.start", function()
    hl.exec_cmd("wl-paste --watch cliphist store")
end)

require("environment")
require("appearance")
require("input")
require("keybinds")
require("windowrules")
