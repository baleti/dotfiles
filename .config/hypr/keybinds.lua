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
-- mod+P used to be dwindle pseudotile toggle; moved to the CPU graph
-- widget (see graph_tier_widget below) and dropped entirely rather than
-- rebound elsewhere, per instruction.

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

-- Step back/forth between workspaces on the *current* monitor, using
-- Hyprland's built-in monitor-relative workspace selector ("r-1"/"r+1"):
-- it skips workspaces bound to any other monitor, so this never hops to a
-- workspace currently shown elsewhere, and creates a new one past the end
-- with no manual per-monitor bookkeeping needed.
hl.bind("CTRL + ALT + h", hl.dsp.focus({ workspace = "r-1" }), { repeating = false })
hl.bind("CTRL + ALT + l", hl.dsp.focus({ workspace = "r+1" }), { repeating = false })

-- Move the active window along with you to the prev/next workspace on this monitor.
hl.bind(mainMod .. " + CTRL + SHIFT + h", hl.dsp.window.move({ workspace = "r-1" }), { repeating = false })
hl.bind(mainMod .. " + CTRL + SHIFT + l", hl.dsp.window.move({ workspace = "r+1" }), { repeating = false })

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
-- KDE's [mediacontrol] kglobalshortcuts had these bound to the same keys at 5s seek (~/.config/kglobalshortcutsrc)
hl.bind("XF86AudioRewind",  hl.dsp.exec_cmd("playerctl position 5-"), { locked = true, repeating = true })
hl.bind("XF86AudioForward", hl.dsp.exec_cmd("playerctl position 5+"), { locked = true, repeating = true })

hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("~/.config/hypr/clipboard-picker/target/release/clipboard-picker"))
hl.bind("Print",           hl.dsp.exec_cmd("hyprshot -m region -r | satty -f - --actions-on-enter save-to-clipboard --actions-on-escape exit"))

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

-- Custom grid alt-tab switcher (~/.config/hypr/winswitch): holding Alt and
-- tapping Tab/Shift+Tab cycles a thumbnail grid; a second tap while already
-- open forwards a cycle command over a Unix socket to the running instance
-- instead of spawning another one (see winswitch/src/main.rs).
hl.bind("ALT + Tab",         hl.dsp.exec_cmd("~/.config/hypr/winswitch/target/release/winswitch next"))
hl.bind("ALT + SHIFT + Tab", hl.dsp.exec_cmd("~/.config/hypr/winswitch/target/release/winswitch prev"))

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
hl.bind("ALT + n", hl.dsp.exec_cmd("~/.config/hypr/notifyd/target/release/notifyctl invoke-last"))

-- notifications: open the full action list (e.g. Thunderbird's Activate/
-- Mark as Read/Delete) instead of just invoking the default one
hl.bind(mainMod .. " + SHIFT + n", hl.dsp.exec_cmd("~/.config/hypr/scripts/notifyd-actions-menu.sh"))

-- notifications: browse/search all retained notification history and
-- invoke the chosen one's default action -- no redisplay needed, unlike
-- the old dunst-backed version of this picker. Shares the clipboard-picker's
-- GTK+layer-shell picker engine (~/.config/hypr/clipboard-picker/src/picker.rs).
hl.bind(mainMod .. " + CTRL + n", hl.dsp.exec_cmd("~/.config/hypr/clipboard-picker/target/release/notification-picker"))

-- system monitor popups (~/.config/hypr/sysmon): small graph overlay for the
-- last 10 minutes of network/cpu/temperature/memory, replacing the KDE
-- alt+n network widget. sysmond (autostarted in hyprland.lua) samples
-- continuously so the graph has history the instant the popup opens; a
-- second press of the same keybind closes it (same pidfile+SIGTERM toggle
-- as clipboard-picker). "m" for memory added 2026-08-27 alongside the
-- quickshell bar's own hover graphs, which share this same daemon.
hl.bind("ALT + " .. mainMod .. " + n", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph net"))
hl.bind("ALT + " .. mainMod .. " + p", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph cpu"))
hl.bind("ALT + " .. mainMod .. " + t", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph temp"))
hl.bind("ALT + " .. mainMod .. " + m", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph mem"))

-- Toggle the *quickshell bar's own* hover-graph panels open/closed on
-- whichever monitor is focused (~/.config/hypr/scripts/bar-toggle.sh), AND
-- enter a shared "graph_nav" submap: while active, 1-6 (no modifier) jumps
-- the last-toggled-on panel's history tier straight to 10m/30m/6h/7d/7w/
-- 7mo, and left/right step it one tier at a time, via bar-set-tier.sh ->
-- Bar.qml's setXxxTier() IpcHandler functions (same tier-setting path
-- GraphPill's own tier buttons use).
--
-- Originally each widget got its OWN private submap (entered on its entry
-- key, holding only that widget's own tier/Escape/entry-key binds). That
-- meant entering e.g. graph_temp's submap left mod+d totally unbound --
-- Hyprland submaps replace the *entire* active keymap -- so a second panel
-- could never be opened without first Escaping back to the normal keymap
-- (reported 2026-08-29, broke the "show several panels at once" flow).
-- Fixed by folding every widget's entry key into one shared submap: any
-- entry key works from inside it, each toggling its own panel and
-- becoming the tier-key target, so panels layer up freely (Bar.qml's
-- stackRight() lays out however many are open).
--
-- temp, disk, mem, and cpu moved from ALT+t/s/m/p to mod+t/d/m/p (disk later
-- moved off mod+s to mod+d). mod+m
-- collided with the media widget's own mod+m (below) - resolved by moving
-- media to mod+CTRL+m. mod+p collided with window.pseudo() (dwindle) -
-- resolved by dropping that binding entirely (told to, not guessed). See
-- feedback_hyprland_chord_via_submap memory. net was left on ALT+n because
-- mod+n was notifyctl invoke-last (above) - swapped 2026-08-29 so net
-- matches the other widgets on plain mod+n, and invoke-last moved to ALT+n.
local GRAPH_TIERS = { "10m", "30m", "6h", "7d", "7w", "7mo" }

local GRAPH_WIDGETS = {
    temp = { key = mainMod .. " + t", toggle = "toggleTemp", tier = "setTempTier" },
    disk = { key = mainMod .. " + d", toggle = "toggleDisk", tier = "setDiskTier" },
    net  = { key = mainMod .. " + n", toggle = "toggleNet",  tier = "setNetTier" },
    cpu  = { key = mainMod .. " + p", toggle = "toggleCpu",  tier = "setCpuTier" },
    mem  = { key = mainMod .. " + m", toggle = "toggleMem",  tier = "setMemTier" },
}

-- active_widget: whichever panel 1-6/left/right currently act on -- the
-- most recently *opened* one, not just most recently pressed (closing a
-- panel falls back to another still-open one, if any). widget_open mirrors
-- GraphPill's pinned state from the keybind side only -- toggling a panel
-- by clicking its pill directly can desync this, same limitation the old
-- per-widget submaps already had.
local widget_open = {}
for name in pairs(GRAPH_WIDGETS) do widget_open[name] = false end
local active_widget = nil
local tier_index = {}
for name in pairs(GRAPH_WIDGETS) do tier_index[name] = 1 end

local function set_tier(name, index)
    index = math.max(1, math.min(#GRAPH_TIERS, index))
    tier_index[name] = index
    hl.dispatch(hl.dsp.exec_cmd(
        "~/.config/hypr/scripts/bar-set-tier.sh " .. GRAPH_WIDGETS[name].tier .. " " .. GRAPH_TIERS[index]))
end

local function toggle_widget(name)
    hl.dispatch(hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh " .. GRAPH_WIDGETS[name].toggle))
    widget_open[name] = not widget_open[name]

    if widget_open[name] then
        active_widget = name
    elseif active_widget == name then
        active_widget = nil
        for n, open in pairs(widget_open) do
            if open then
                active_widget = n
                break
            end
        end
    end

    -- Nothing left open -> drop back to the normal keymap automatically
    -- (mirrors the old "entry key again exits" feel); otherwise stay in
    -- nav mode so the remaining open panel(s) keep their tier keys live.
    local any_open = false
    for _, open in pairs(widget_open) do
        any_open = any_open or open
    end
    hl.dispatch(hl.dsp.submap(any_open and "graph_nav" or "reset"))
end

hl.define_submap("graph_nav", function()
    for name, w in pairs(GRAPH_WIDGETS) do
        hl.bind(w.key, function() toggle_widget(name) end)
    end

    for i, code in ipairs(GRAPH_TIERS) do
        hl.bind(tostring(i), function()
            if active_widget then set_tier(active_widget, i) end
        end)
    end
    hl.bind("left", function()
        if active_widget then set_tier(active_widget, tier_index[active_widget] + 1) end
    end)
    hl.bind("right", function()
        if active_widget then set_tier(active_widget, tier_index[active_widget] - 1) end
    end)

    hl.bind("Escape", function() hl.dispatch(hl.dsp.submap("reset")) end)
end)

for name, w in pairs(GRAPH_WIDGETS) do
    hl.bind(w.key, function() toggle_widget(name) end)
end
-- mod+CTRL+m opens the media widget AND enters the "media_seek" submap:
-- while active, bare 0-9 (no modifier -- Hyprland binds match one
-- non-modifier key at a time, so a real simultaneous "mod+ctrl+m+2"
-- four-key chord isn't expressible; a submap is the idiomatic equivalent --
-- press mod+CTRL+m once to enter, then tap digits freely) jump to that
-- decile of the current track (2 -> 20%, 9 -> 90%, ...), via
-- playerctl-seek-percent.sh against whichever player
-- ~/.config/playerctl-current names. Escape or mod+CTRL+m again exits back
-- to the normal keymap (and mod+CTRL+m also re-closes the widget, mirroring
-- its toggle behavior outside the submap). Not plain mod+m: that's the
-- memory graph widget above (caught live before this ever shipped wrong).
hl.define_submap("media_seek", function()
    for i = 0, 9 do
        hl.bind(tostring(i), hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-seek-percent.sh " .. i))
    end
    hl.bind("Escape", function() hl.dispatch(hl.dsp.submap("reset")) end)
    hl.bind(mainMod .. " + CTRL + m", function()
        hl.dispatch(hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleMedia"))
        hl.dispatch(hl.dsp.submap("reset"))
    end)
end)

hl.bind(mainMod .. " + CTRL + m", function()
    hl.dispatch(hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleMedia"))
    hl.dispatch(hl.dsp.submap("media_seek"))
end)
-- Moved from CTRL+ALT+c to mod+CTRL+c. No Hyprland submap needed here
-- (unlike media_seek/graph_*): once open, CalendarExpanded.qml gets real
-- WlrKeyboardFocus.OnDemand focus (shell.qml) the same way the media panel
-- already does for its own arrow-seek/space/escape keys, so bare
-- Tab/arrows/Enter/Escape just reach the QML panel directly - no global
-- digit-style interception required. See CalendarExpanded.qml's
-- handleKey() for the year-picker (Tab enters it; arrows navigate/zoom;
-- Enter drills in or confirms; Escape exits).
hl.bind(mainMod .. " + CTRL + c", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleCalendar"))

-- bluetooth
hl.bind(mainMod .. " + CTRL + b", hl.dsp.exec_cmd("bluetoothctl disconnect"))

-- music
hl.bind("ALT + CTRL + m", hl.dsp.exec_cmd("alacritty -e ncmpcpp"))
hl.bind(mainMod .. " + CTRL + SHIFT + p", hl.dsp.exec_cmd("playerctl --player=$(cat ~/.config/playerctl-current) play-pause"), { repeating = true })
hl.bind(mainMod .. " + CTRL + x", hl.dsp.exec_cmd("playerctl --player=$(cat ~/.config/playerctl-current) next"), { repeating = true })
hl.bind(mainMod .. " + CTRL + z", hl.dsp.exec_cmd("playerctl --player=$(cat ~/.config/playerctl-current) previous"), { repeating = true })
-- restored from the old KDE setup (net.local.playerctl-2/5.desktop, kglobalshortcutsrc: Meta+Ctrl+Shift+Z/X).
-- ~/.config/hypr/scripts/playerctl-seek.sh keeps the original Exec='s pause+play "kick" after
-- seeking, but only resumes play if the player was actually playing before the seek.
hl.bind(mainMod .. " + CTRL + SHIFT + z", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-seek.sh -"), { repeating = true })
hl.bind(mainMod .. " + CTRL + SHIFT + x", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-seek.sh +"), { repeating = true })
hl.bind("ALT + CTRL + SHIFT + m", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-picker.sh"), { repeating = true })
-- ~/.config/hypr/scripts/playerctl-volume.sh: local sink, unless
-- playerctl-current is pixel6, in which case its MPRIS Volume (-> phone
-- STREAM_MUSIC) instead. See pixel6-mpris-bridge.py for the MPRIS side.
hl.bind(mainMod .. " + F11", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-volume.sh -"), { repeating = true })
hl.bind(mainMod .. " + F12", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-volume.sh +"), { repeating = true })

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

-- promote the focused window to master (swaps it with whatever is currently
-- master, per master layout's "swap" default mode)
hl.bind(mainMod .. " + Return", hl.dsp.layout("swapwithmaster"))
