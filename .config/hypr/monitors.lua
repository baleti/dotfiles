-- Monitor layout.
-- See https://wiki.hypr.land/Configuring/Monitors/
--
-- Left to right: laptop panel -> AOC 2470W (HDMI) -> Philips 241V8 (USB-C).
-- eDP-2 is scaled 1.5x, so its logical width is 1920/1.5 = 1280 -- that's
-- where the next monitor's position starts.

hl.monitor({ output = "eDP-2",     mode = "1920x1080@240", position = "0x0",    scale = "1.5" })
hl.monitor({ output = "HDMI-A-1",  mode = "1920x1080@60",  position = "1280x0", scale = "1" })
hl.monitor({ output = "DP-1",      mode = "1920x1080@60",  position = "3200x0", scale = "1" })
