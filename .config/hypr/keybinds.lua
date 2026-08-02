---------------------
---- KEYBINDINGS ----
---------------------

-- See https://wiki.hypr.land/Configuring/Basics/Binds/
-- terminal / fileManager / menu / mainMod come from the globals set in hyprland.lua

hl.bind(mainMod .. " + space", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + Q",     hl.dsp.window.close())
hl.bind(mainMod .. " + E",     hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + SHIFT + space", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + R",     hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + P",     hl.dsp.window.pseudo()) -- dwindle

-- Move focus with mainMod + arrow keys
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- Switch workspaces with mainMod + [0-9]
-- Move active window to a workspace with mainMod + SHIFT + [0-9]
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- Special workspace (scratchpad)
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

-- Scroll through existing workspaces with mainMod + scroll
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Move/resize windows with mainMod + LMB/RMB and dragging
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Laptop multimedia keys for volume and LCD brightness
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true, repeating = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true })

-- Requires playerctl
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("cliphist list | wofi --dmenu | cliphist decode | wl-copy"))
hl.bind("Print",           hl.dsp.exec_cmd("hyprshot -m region --clipboard-only"))

hl.bind(mainMod .. " + Tab", hl.dsp.window.cycle_next())
hl.bind("CTRL + escape",     hl.dsp.exec_cmd("alacritty -e htop"))

-- emacs
hl.bind(mainMod .. " + SHIFT + e", hl.dsp.exec_cmd("emacsclient -e '(evil-buffer-new)' -c"))

-- old .conf used "fullscreen, 1" (maximize); confirmed field names from
-- src/config/lua/bindings/LuaBindingsDispatchers.cpp: mode = "fullscreen"|"maximized", action defaults to "toggle"
hl.bind(mainMod .. " + f", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))

-- bluetooth
hl.bind(mainMod .. " + b",        hl.dsp.exec_cmd("bluetoothctl connect 95:05:BB:28:EE:00"))
hl.bind(mainMod .. " + CTRL + b", hl.dsp.exec_cmd("bluetoothctl disconnect"))

-- music
hl.bind("ALT + CTRL + m", hl.dsp.exec_cmd("alacritty -e ncmpcpp"))
hl.bind(mainMod .. " + CTRL + SHIFT + p", hl.dsp.exec_cmd("playerctl --player=$(cat ~/.config/playerctl-current) play-pause"), { repeating = true })
hl.bind("ALT + CTRL + SHIFT + m", hl.dsp.exec_cmd("zenity --text='Choose player' --column='' --list $(playerctl --list-all) > ~/.config/playerctl-current"), { repeating = true })
hl.bind(mainMod .. " + F11", hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%-"), { repeating = true })
hl.bind(mainMod .. " + F12", hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+"), { repeating = true })

-- move windows (reflow the active window's tiled position in a direction,
-- without swapping places with whatever was there -- equivalent to the old
-- .conf's "movewindow" dispatcher; window.swap is the true two-window trade)
hl.bind(mainMod .. " + CTRL + h", hl.dsp.window.move({ direction = "left" }))
hl.bind(mainMod .. " + CTRL + j", hl.dsp.window.move({ direction = "down" }))
hl.bind(mainMod .. " + CTRL + k", hl.dsp.window.move({ direction = "up" }))
hl.bind(mainMod .. " + CTRL + l", hl.dsp.window.move({ direction = "right" }))

-- resize (old .conf: "resizeactive, -80 0" -- a relative pixel delta)
-- confirmed field names from LuaBindingsDispatchers.cpp: x, y (numbers), relative (bool, default false)
hl.bind("SHIFT + ALT + h", hl.dsp.window.resize({ x = -80, y = 0,  relative = true }))
hl.bind("SHIFT + ALT + j", hl.dsp.window.resize({ x = 0,   y = 80, relative = true }))
hl.bind("SHIFT + ALT + k", hl.dsp.window.resize({ x = 0,   y = -80, relative = true }))
hl.bind("SHIFT + ALT + l", hl.dsp.window.resize({ x = 80,  y = 0,  relative = true }))

-- hjkl focus
hl.bind(mainMod .. " + h", hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + j", hl.dsp.focus({ direction = "down" }))
hl.bind(mainMod .. " + k", hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + l", hl.dsp.focus({ direction = "right" }))

-- rofi
hl.bind(mainMod .. " + Super_l", hl.dsp.exec_cmd("pkill rofi || rofi -show drun"), { release = true })

-- master/stack layout cycling
-- NOTE: this rebinds mainMod + R, already bound above to launch $menu. Same conflict existed
-- in the original .conf (last bind wins), so mainMod + R currently cycles the master layout
-- orientation rather than launching the menu. Preserved as-is -- flag if this wasn't intentional.
hl.bind(mainMod .. " + R",         hl.dsp.layout("orientationcycle"))
hl.bind(mainMod .. " + SHIFT + R", hl.dsp.layout("orientationprev"))
