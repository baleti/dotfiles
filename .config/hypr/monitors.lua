-- Monitor layout.
-- See https://wiki.hypr.land/Configuring/Monitors/
--
-- Left to right: laptop panel -> AOC 2470W (HDMI) -> Philips 241V8 (USB-C).
-- eDP-1 is scaled 1.5x, so its logical width is 1920/1.5 = 1280 -- that's
-- where the next monitor's position starts.
--
-- Fixed 2026-09-18: this used to say "eDP-2" at "1920x1080@240" and "DP-1"
-- -- names/mode from a different machine's ports, matching nothing on this
-- laptop (real connectors are eDP-1, max 60Hz, and DP-2), so these rules
-- silently never applied and Hyprland auto-placed outputs in connection
-- order instead, landing the laptop panel in the middle instead of
-- leftmost. Corrected to this machine's actual connector names.

hl.monitor({ output = "eDP-1",     mode = "1920x1080@60",  position = "0x0",    scale = "1.5" })
hl.monitor({ output = "HDMI-A-1",  mode = "1920x1080@60",  position = "1280x0", scale = "1" })
hl.monitor({ output = "DP-2",      mode = "1920x1080@60",  position = "3200x0", scale = "1" })
