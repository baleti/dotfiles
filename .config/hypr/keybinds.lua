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

-- Move active window to a workspace with mainMod + SHIFT + [0-9]
-- (mainMod + [1-9] is used for pinned app launchers below)
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

--------------------------------
---- PINNED APP LAUNCHERS ----
--------------------------------
-- App list (class/slug/cmd) lives in apps.lua, shared with windowrules.lua
-- (spawn hidden) and hyprland.lua (autostart).
-- Not running -> launch. Hidden in scratch -> pull to this workspace and
-- focus. On another normal workspace -> switch to that workspace (don't
-- pull it here). Focused -> hide on a per-app special workspace.
local apps = require("apps")

-- An app is all of its windows, not just the first one get_windows returns:
-- GIMP's dialogs are separate toplevels sharing the class, so hiding or
-- summoning only one of them splits the app across workspaces and leaves the
-- rest stranded (invisibly, if the leftovers are the ones in scratch).
local function toggle_app(class, slug, launch_cmd)
    local scratch = "special:scratch_" .. slug
    return function()
        local windows = hl.get_windows({ class = class })
        if #windows == 0 then
            hl.dispatch(hl.dsp.exec_cmd(launch_cmd))
            return
        end

        -- Lowest focus_history_id == most recently focused (0 is the active
        -- window), so this is the window you actually last looked at -- which
        -- for a multi-window app is often a dialog, not windows[1].
        local primary = windows[1]
        local active = false
        for _, win in ipairs(windows) do
            active = active or win.active
            if (win.focus_history_id or math.huge) < (primary.focus_history_id or math.huge) then
                primary = win
            end
        end

        if active then
            for _, win in ipairs(windows) do
                hl.dispatch(hl.dsp.window.move({ workspace = scratch, window = win, follow = false }))
            end
        elseif primary.workspace and primary.workspace.special then
            local cur_ws = hl.get_active_workspace()
            for _, win in ipairs(windows) do
                if win.workspace and win.workspace.special then
                    hl.dispatch(hl.dsp.window.move({ workspace = cur_ws, window = win, follow = false }))
                end
            end
            hl.dispatch(hl.dsp.focus({ window = primary }))
        else
            -- Already on a normal workspace: switch to it rather than pulling
            -- it here, but first reclaim any window of this app still sitting
            -- in scratch (a dialog that opened while it was hidden, or a
            -- leftover from an earlier partial move) so the app is never split
            -- between a visible workspace and an invisible one.
            for _, win in ipairs(windows) do
                if win.workspace and win.workspace.special and primary.workspace then
                    hl.dispatch(hl.dsp.window.move({ workspace = primary.workspace, window = win, follow = false }))
                end
            end
            hl.dispatch(hl.dsp.focus({ window = primary }))
        end
    end
end

for _, app in ipairs(apps) do
    hl.bind(mainMod .. " + " .. app.key, toggle_app(app.class, app.slug, app.cmd))
end

-- Scroll through existing workspaces with mainMod + scroll
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Step back/forth between workspaces belonging to the *current* monitor only
-- -- monitors are independent, so this never hops to a workspace that's
-- currently shown on another monitor. Forward past this monitor's highest
-- workspace first tries to reclaim an orphaned workspace (one that exists,
-- has windows, but isn't displayed on any monitor right now -- e.g. one you
-- stepped away from earlier); only if none exists does it create a fresh one.
local function monitor_workspace_ids(mon)
    local ids = {}
    for _, ws in ipairs(hl.get_workspaces()) do
        if not ws.special and ws.monitor and ws.monitor.id == mon.id then
            table.insert(ids, ws.id)
        end
    end
    return ids
end

local function global_max_workspace_id()
    local max_id = 0
    for _, ws in ipairs(hl.get_workspaces()) do
        if not ws.special and ws.id > max_id then
            max_id = ws.id
        end
    end
    return max_id
end

-- Lowest-id workspace that exists, isn't special, isn't already ours, and
-- isn't currently displayed on any monitor -- i.e. free to be reclaimed.
local function orphan_workspace_id(mon)
    local best = nil
    for _, ws in ipairs(hl.get_workspaces()) do
        if not ws.special and not ws.visible and ws.monitor and ws.monitor.id ~= mon.id then
            if best == nil or ws.id < best then
                best = ws.id
            end
        end
    end
    return best
end

-- Shared with the mainMod+CTRL+SHIFT+h/l window-move binds below, so "next"/
-- "prev" means the same thing whether you're stepping focus or dragging the
-- active window along with you.
local function prev_workspace_id(mon, cur)
    local prev_id = nil
    for _, id in ipairs(monitor_workspace_ids(mon)) do
        if id < cur.id then prev_id = id end
    end
    return prev_id
end

-- Resolves (and, if reclaiming an orphan, relocates) the next workspace id;
-- does not focus or move anything itself so both focus-step and
-- window-move binds can share it.
local function next_workspace_id(mon, cur)
    local next_id = nil
    for _, id in ipairs(monitor_workspace_ids(mon)) do
        if id > cur.id and (next_id == nil or id < next_id) then
            next_id = id
        end
    end
    if next_id then return next_id end

    local orphan = orphan_workspace_id(mon)
    if orphan then
        hl.dispatch(hl.dsp.workspace.move({ workspace = orphan, monitor = mon.name }))
        return orphan
    end

    return global_max_workspace_id() + 1
end

hl.bind("CTRL + ALT + h", function()
    local mon = hl.get_active_monitor()
    local cur = hl.get_active_workspace(mon)
    if not (mon and cur) then return end

    local prev_id = prev_workspace_id(mon, cur)
    if prev_id then
        hl.dispatch(hl.dsp.focus({ workspace = prev_id }))
    end
end, { repeating = false })

hl.bind("CTRL + ALT + l", function()
    local mon = hl.get_active_monitor()
    local cur = hl.get_active_workspace(mon)
    if not (mon and cur) then return end

    hl.dispatch(hl.dsp.focus({ workspace = next_workspace_id(mon, cur) }))
end, { repeating = false })

-- Move the active window along with you to the prev/next workspace, using
-- the exact same "next" resolution (orphan reclaim, then create) as
-- CTRL+ALT+h/l above.
hl.bind(mainMod .. " + CTRL + SHIFT + h", function()
    local mon = hl.get_active_monitor()
    local cur = hl.get_active_workspace(mon)
    if not (mon and cur) then return end

    local prev_id = prev_workspace_id(mon, cur)
    if prev_id then
        hl.dispatch(hl.dsp.window.move({ workspace = prev_id }))
    end
end, { repeating = false })

hl.bind(mainMod .. " + CTRL + SHIFT + l", function()
    local mon = hl.get_active_monitor()
    local cur = hl.get_active_workspace(mon)
    if not (mon and cur) then return end

    hl.dispatch(hl.dsp.window.move({ workspace = next_workspace_id(mon, cur) }))
end, { repeating = false })

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

hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("~/.config/hypr/clipboard-picker/target/release/clipboard-picker"))
hl.bind("Print",           hl.dsp.exec_cmd("hyprshot -m region --clipboard-only"))

-- Global menu prototype (KDE's mod+a equivalent): flattens the focused
-- window's AT-SPI accessible menu tree into a rofi picker and activates
-- the chosen item. AT-SPI rather than com.canonical.AppMenu.Registrar/
-- dbusmenu because that scheme keys off X11 window IDs, and every client
-- here runs native Wayland (no XWayland id to register with). Coverage
-- depends on the app exposing a real accessible menu tree -- confirmed
-- working against LibreOffice; GTK apps with a classic menu bar should
-- work too, Electron/Gecko apps are unlikely to unless they force their
-- a11y bridge on.
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd("python3 ~/.config/hypr/scripts/appmenu-atspi.py"))

hl.bind(mainMod .. " + Tab", hl.dsp.window.cycle_next())
hl.bind("CTRL + escape",     hl.dsp.exec_cmd("alacritty -e htop"))

-- window groups (tabs): toggle a group, then step through it like tabs.
-- confirmed field names/signatures from src/config/lua/bindings/LuaBindingsDispatchers.cpp
-- (hlGroupToggle/hlGroupNext/hlGroupPrev/hlGroupLockActive), all take no required args.
hl.bind(mainMod .. " + G",         hl.dsp.group.toggle())
hl.bind(mainMod .. " + bracketleft",  hl.dsp.group.prev())
hl.bind(mainMod .. " + bracketright", hl.dsp.group.next())
hl.bind(mainMod .. " + SHIFT + G", hl.dsp.group.lock_active())

-- emacs
hl.bind(mainMod .. " + SHIFT + e", hl.dsp.exec_cmd("alacritty -e tmux new-session emacsclient --tty"))

-- old .conf used "fullscreen, 1" (maximize); confirmed field names from
-- src/config/lua/bindings/LuaBindingsDispatchers.cpp: mode = "fullscreen"|"maximized", action defaults to "toggle"
hl.bind(mainMod .. " + f", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))

-- waybar: SIGUSR1 toggles visibility (waybar(5), "SIGNALS"). The bar is
-- configured non-exclusive (~/.config/waybar/config.jsonc), so it overlays
-- windows and toggling it does not reflow the layout.
hl.bind(mainMod .. " + b", hl.dsp.exec_cmd("killall -SIGUSR1 waybar"))

-- notifications: invoke the last notification's default action (mirrors
-- dunstrc's mouse_left_click = do_action) -- works even if it already
-- closed/timed out, since notifyd (replacing dunst -- see
-- ~/.claude2/plans/silly-percolating-rose.md) never discards a
-- notification's actions on close, unlike dunst.
hl.bind(mainMod .. " + n", hl.dsp.exec_cmd("~/.config/hypr/notifyd/target/release/notifyctl invoke-last"))

-- notifications: open the full action list (e.g. Thunderbird's Activate/
-- Mark as Read/Delete) instead of just invoking the default one
hl.bind(mainMod .. " + SHIFT + n", hl.dsp.exec_cmd("~/.config/hypr/scripts/notifyd-actions-menu.sh"))

-- notifications: browse/search all retained notification history and
-- invoke the chosen one's default action -- no redisplay needed, unlike
-- the old dunst-backed version of this picker. Shares the clipboard-picker's
-- GTK+layer-shell picker engine (~/.config/hypr/clipboard-picker/src/picker.rs).
hl.bind(mainMod .. " + CTRL + n", hl.dsp.exec_cmd("~/.config/hypr/clipboard-picker/target/release/notification-picker"))

-- bluetooth
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
