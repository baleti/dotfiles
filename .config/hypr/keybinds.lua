---------------------
---- KEYBINDINGS ----
---------------------

-- See https://wiki.hypr.land/Configuring/Basics/Binds/
-- terminal / fileManager / menu / mainMod come from the globals set in hyprland.lua

hl.bind(mainMod .. " + space", hl.dsp.exec_cmd(terminal), { description = "Open a terminal" })
hl.bind(mainMod .. " + Q",     hl.dsp.window.close(), { description = "Close the active window" })
hl.bind(mainMod .. " + E",     hl.dsp.exec_cmd(fileManager), { description = "Open the file manager" })
hl.bind(mainMod .. " + SHIFT + space", hl.dsp.window.float({ action = "toggle" }), { description = "Toggle floating for the active window" })
-- mod+R was `menu` (hyprlauncher); the quickshell launcher on mod+Super_l is
-- the primary app launcher, so the quickshell RSS reader is bound to
-- ALT+SHIFT+R instead (~/.config/quickshell/rssreader/; the curses
-- ~/.config/rssd/reader.py is still there for ssh/tty use, just not bound).
hl.bind("ALT + SHIFT + R",     hl.dsp.exec_cmd("qs ipc call rssReader toggle"), { description = "Toggle the RSS reader" })

-- Shortcuts help panel (mod+?, i.e. mod+SHIFT+/). Quickshell overlay
-- (~/.config/quickshell/keybinds/) that lists every bind carrying a
-- `description` here, read live from `hyprctl binds -j` on open. A second
-- press toggles it closed; Escape / click-away also close.
hl.bind(mainMod .. " + SHIFT + slash", hl.dsp.exec_cmd("qs ipc call keybindsHelp toggle"), { description = "Show this keyboard-shortcuts panel" })
-- mod+P used to be dwindle pseudotile toggle; moved to the CPU graph
-- widget (see the mod+t/d/n/p/m binds below) and dropped entirely rather
-- than rebound elsewhere, per instruction.

-- Move focus with mainMod + arrow keys
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }),  { description = "Focus the window to the left" })
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }), { description = "Focus the window to the right" })
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }),    { description = "Focus the window above" })
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }),  { description = "Focus the window below" })

-- Move active window to a workspace with mainMod + SHIFT + [0-9]
-- (mainMod + [1-9] is used for pinned app launchers below)
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }), { description = "Move window to workspace " .. i })
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
    hl.bind(mainMod .. " + " .. app.key, toggle_app(app.class, app.slug, app.cmd), { description = "Launch / toggle " .. app.slug })
end

-- Scroll through existing workspaces with mainMod + scroll
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { description = "Next workspace (scroll)" })
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }), { description = "Previous workspace (scroll)" })

-- Step back/forth between workspaces on the *current* monitor, using
-- Hyprland's built-in monitor-relative workspace selector ("r-1"/"r+1"):
-- it skips workspaces bound to any other monitor, so this never hops to a
-- workspace currently shown elsewhere, and creates a new one past the end
-- with no manual per-monitor bookkeeping needed.
hl.bind("CTRL + ALT + h", hl.dsp.focus({ workspace = "r-1" }), { repeating = false, description = "Previous workspace on this monitor" })
hl.bind("CTRL + ALT + l", hl.dsp.focus({ workspace = "r+1" }), { repeating = false, description = "Next workspace on this monitor" })

-- Move the active window along with you to the prev/next workspace on this monitor.
hl.bind(mainMod .. " + CTRL + SHIFT + h", hl.dsp.window.move({ workspace = "r-1" }), { repeating = false, description = "Move window to previous workspace on this monitor" })
hl.bind(mainMod .. " + CTRL + SHIFT + l", hl.dsp.window.move({ workspace = "r+1" }), { repeating = false, description = "Move window to next workspace on this monitor" })

-- Move/resize windows with mainMod + LMB/RMB and dragging
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, description = "Move window (drag with mouse)" })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Resize window (drag with mouse)" })

-- Laptop multimedia keys for volume and LCD brightness
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true, description = "Volume up" })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true, description = "Volume down" })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true, description = "Mute output" })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true, repeating = true, description = "Mute microphone" })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true, description = "Screen brightness up" })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true, description = "Screen brightness down" })

-- Requires playerctl
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true, description = "Media: next track" })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Media: play / pause" })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Media: play / pause" })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true, description = "Media: previous track" })
-- KDE's [mediacontrol] kglobalshortcuts had these bound to the same keys at 5s seek (~/.config/kglobalshortcutsrc)
hl.bind("XF86AudioRewind",  hl.dsp.exec_cmd("playerctl position 5-"), { locked = true, repeating = true, description = "Media: seek back 5s" })
hl.bind("XF86AudioForward", hl.dsp.exec_cmd("playerctl position 5+"), { locked = true, repeating = true, description = "Media: seek forward 5s" })

hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("~/.config/hypr/clipboard-picker/target/release/clipboard-picker"), { description = "Clipboard history picker" })
hl.bind("Print",           hl.dsp.exec_cmd("hyprshot -m region -r | satty -f - --actions-on-enter save-to-clipboard --actions-on-escape exit"), { description = "Screenshot a region (annotate)" })

-- Global menu prototype (KDE's mod+a equivalent): flattens the focused
-- window's AT-SPI accessible menu tree into a rofi picker and activates
-- the chosen item. AT-SPI rather than com.canonical.AppMenu.Registrar/
-- dbusmenu because that scheme keys off X11 window IDs, and every client
-- here runs native Wayland (no XWayland id to register with). Coverage
-- depends on the app exposing a real accessible menu tree -- confirmed
-- working against LibreOffice; GTK apps with a classic menu bar should
-- work too, Electron/Gecko apps are unlikely to unless they force their
-- a11y bridge on.
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd("python3 ~/.config/hypr/scripts/appmenu-atspi.py"), { description = "Show the focused window's menu (global menu)" })

hl.bind(mainMod .. " + Tab", hl.dsp.window.cycle_next(), { description = "Cycle to the next window" })
hl.bind("CTRL + escape",     hl.dsp.exec_cmd("alacritty -e htop"), { description = "Open htop" })

-- Custom grid alt-tab switcher (~/.config/hypr/winswitch): holding Alt and
-- tapping Tab/Shift+Tab cycles a thumbnail grid; a second tap while already
-- open forwards a cycle command over a Unix socket to the running instance
-- instead of spawning another one (see winswitch/src/main.rs).
hl.bind("ALT + Tab",         hl.dsp.exec_cmd("~/.config/hypr/winswitch/target/release/winswitch next"), { description = "Window switcher (next)" })
hl.bind("ALT + SHIFT + Tab", hl.dsp.exec_cmd("~/.config/hypr/winswitch/target/release/winswitch prev"), { description = "Window switcher (previous)" })

-- window groups (tabs): toggle a group, then step through it like tabs.
-- confirmed field names/signatures from src/config/lua/bindings/LuaBindingsDispatchers.cpp
-- (hlGroupToggle/hlGroupNext/hlGroupPrev/hlGroupLockActive), all take no required args.
hl.bind(mainMod .. " + G",         hl.dsp.group.toggle(), { description = "Toggle window group (tabs)" })
hl.bind(mainMod .. " + bracketleft",  hl.dsp.group.prev(), { description = "Previous window in group" })
hl.bind(mainMod .. " + bracketright", hl.dsp.group.next(), { description = "Next window in group" })
hl.bind(mainMod .. " + SHIFT + G", hl.dsp.group.lock_active(), { description = "Lock / unlock the active group" })

-- emacs
hl.bind(mainMod .. " + SHIFT + e", hl.dsp.exec_cmd("alacritty -e tmux new-session emacsclient --tty"), { description = "Open Emacs (in tmux)" })

-- old .conf used "fullscreen, 1" (maximize); confirmed field names from
-- src/config/lua/bindings/LuaBindingsDispatchers.cpp: mode = "fullscreen"|"maximized", action defaults to "toggle"
hl.bind(mainMod .. " + f", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }), { description = "Maximize the active window" })

-- waybar: SIGUSR1 toggles visibility (waybar(5), "SIGNALS"). The bar is
-- configured non-exclusive (~/.config/waybar/config.jsonc), so it overlays
-- windows and toggling it does not reflow the layout.
hl.bind(mainMod .. " + b", hl.dsp.exec_cmd("killall -SIGUSR1 waybar"), { description = "Toggle the status bar" })

-- notifications: invoke the last notification's default action (mirrors
-- dunstrc's mouse_left_click = do_action) -- works even if it already
-- closed/timed out, since notifyd (replacing dunst -- see
-- ~/.claude2/plans/silly-percolating-rose.md) never discards a
-- notification's actions on close, unlike dunst.
hl.bind("ALT + n", hl.dsp.exec_cmd("~/.config/hypr/notifyd/target/release/notifyctl invoke-last"), { description = "Invoke the last notification's default action" })

-- notifications: open the full action list (e.g. Thunderbird's Activate/
-- Mark as Read/Delete) instead of just invoking the default one
hl.bind(mainMod .. " + SHIFT + n", hl.dsp.exec_cmd("~/.config/hypr/scripts/notifyd-actions-menu.sh"), { description = "Open the last notification's full action list" })

-- notifications: browse/search all retained notification history and
-- invoke the chosen one's default action -- no redisplay needed, unlike
-- the old dunst-backed version of this picker. Shares the clipboard-picker's
-- GTK+layer-shell picker engine (~/.config/hypr/clipboard-picker/src/picker.rs).
hl.bind(mainMod .. " + CTRL + n", hl.dsp.exec_cmd("~/.config/hypr/clipboard-picker/target/release/notification-picker"), { description = "Search all notification history" })

-- notifications: clear all on-screen cards without touching history --
-- notifyctl close-all only drops the render order, it never removes
-- entries from state.json/ListHistory (see the DismissPopup/CloseAll
-- doc comments in notifyd/src/main.rs).
hl.bind("CTRL + ALT + z", hl.dsp.exec_cmd("~/.config/hypr/notifyd/target/release/notifyctl close-all"), { description = "Clear all on-screen notification cards" })

-- system monitor popups (~/.config/hypr/sysmon): small graph overlay for the
-- last 10 minutes of network/cpu/temperature/memory, replacing the KDE
-- alt+n network widget. sysmond (autostarted in hyprland.lua) samples
-- continuously so the graph has history the instant the popup opens; a
-- second press of the same keybind closes it (same pidfile+SIGTERM toggle
-- as clipboard-picker). "m" for memory added 2026-08-27 alongside the
-- quickshell bar's own hover graphs, which share this same daemon.
hl.bind("ALT + " .. mainMod .. " + n", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph net"), { description = "Network graph popup (last 10 min)" })
hl.bind("ALT + " .. mainMod .. " + p", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph cpu"), { description = "CPU graph popup (last 10 min)" })
hl.bind("ALT + " .. mainMod .. " + t", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph temp"), { description = "Temperature graph popup (last 10 min)" })
hl.bind("ALT + " .. mainMod .. " + m", hl.dsp.exec_cmd("~/.config/hypr/sysmon/target/release/sysmon-graph mem"), { description = "Memory graph popup (last 10 min)" })

-- Toggle the *quickshell bar's own* hover-graph panels open/closed on
-- whichever monitor is focused (~/.config/hypr/scripts/bar-toggle.sh). Just
-- a plain toggle each -- no submap. 1-6/left-right tier switching and
-- Escape-to-close now go straight to whichever panel holds real keyboard
-- focus, handled in GraphPill.qml's own Keys.onPressed, the same
-- HyprlandFocusGrab-based mechanism the calendar/media panels already used
-- (see shell.qml). That replaces an earlier "graph_nav" Hyprland submap
-- that tracked which panel(s) were open on the Lua side in parallel with
-- (and prone to desyncing from -- reported 2026-08-29 twice) each pill's
-- own real state; routing keys to the actually-focused QML item needs no
-- such tracking at all, so this entire block collapsed down to five binds.
--
-- temp, disk, mem, and cpu moved from ALT+t/s/m/p to mod+t/d/m/p (disk later
-- moved off mod+s to mod+d; cpu briefly moved to mod+c / ALT+mod+c but moved
-- back to mod+p / ALT+mod+p when mod+c was wanted for the calendar panel).
-- mod+m
-- collided with the media widget's own mod+m (below) - resolved by moving
-- media to mod+CTRL+m. mod+p collided with window.pseudo() (dwindle) -
-- resolved by dropping that binding entirely (told to, not guessed). See
-- feedback_hyprland_chord_via_submap memory. net was left on ALT+n because
-- mod+n was notifyctl invoke-last (above) - swapped 2026-08-29 so net
-- matches the other widgets on plain mod+n, and invoke-last moved to ALT+n.
hl.bind(mainMod .. " + t", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleTemp"), { description = "Toggle the bar's temperature panel" })
hl.bind(mainMod .. " + d", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleDisk"), { description = "Toggle the bar's disk panel" })
hl.bind(mainMod .. " + n", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleNet"), { description = "Toggle the bar's network panel" })
hl.bind(mainMod .. " + p", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleCpu"), { description = "Toggle the bar's CPU panel" })
hl.bind(mainMod .. " + m", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleMem"), { description = "Toggle the bar's memory panel" })
-- mod+CTRL+m just toggles the media widget open/closed -- not plain mod+m,
-- that's the memory graph widget above (caught live before this ever
-- shipped wrong). No submap: 0-9 decile-seek used to be a separate
-- "media_seek" Hyprland submap running alongside the arrow-seek/space/
-- escape keys, which already reached Bar.qml's Keys.onPressed directly via
-- real WlrKeyboardFocus.OnDemand focus (shell.qml) -- the bar's Submap{}
-- indicator would visibly show "media_seek" whenever it was live, which is
-- how the leftover got noticed (reported 2026-08-30). Digits now go
-- through that same Keys.onPressed as everything else.
hl.bind(mainMod .. " + CTRL + m", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleMedia"), { description = "Toggle the bar's media panel" })

-- Moved CTRL+ALT+c -> mod+CTRL+c -> mod+c (cpu, which had briefly taken
-- mod+c, went back to mod+p). No Hyprland submap needed here
-- either: once open, CalendarExpanded.qml gets real WlrKeyboardFocus.OnDemand
-- focus (shell.qml) the same way the media panel does for its own keys, so
-- bare Tab/arrows/Enter/Escape just reach the QML panel directly - no
-- global digit-style interception required. See CalendarExpanded.qml's
-- handleKey() for the year-picker (Tab enters it; arrows navigate/zoom;
-- Enter drills in or confirms; Escape exits).
hl.bind(mainMod .. " + c", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleCalendar"), { description = "Toggle the calendar / agenda panel" })

-- Claude Code usage panel (session/weekly % for each of the 3 accounts on
-- this machine) -- CTRL+ALT+c was free since calendar moved off it (above).
-- No real keyboard focus grab, unlike calendar/media: ClaudeUsageExpanded.qml
-- has no arrow-key navigation, so it never asks for
-- WlrKeyboardFocus.OnDemand -- toggling again (or clicking the pill) is the
-- only way to close it. Backed by claude-usage-daemon.py (systemd user
-- service), not queried directly here.
hl.bind("CTRL + ALT + c", hl.dsp.exec_cmd("~/.config/hypr/scripts/bar-toggle.sh toggleClaudeUsage"), { description = "Toggle the Claude Code usage panel" })

-- bluetooth
hl.bind(mainMod .. " + CTRL + b", hl.dsp.exec_cmd("bluetoothctl disconnect"), { description = "Disconnect Bluetooth" })

-- music
hl.bind("ALT + CTRL + m", hl.dsp.exec_cmd("alacritty -e ncmpcpp"), { description = "Open ncmpcpp" })
hl.bind(mainMod .. " + CTRL + SHIFT + p", hl.dsp.exec_cmd("playerctl --player=$(cat ~/.config/playerctl-current) play-pause"), { repeating = true, description = "Media: play / pause (current player)" })
hl.bind(mainMod .. " + CTRL + x", hl.dsp.exec_cmd("playerctl --player=$(cat ~/.config/playerctl-current) next"), { repeating = true, description = "Media: next track (current player)" })
hl.bind(mainMod .. " + CTRL + z", hl.dsp.exec_cmd("playerctl --player=$(cat ~/.config/playerctl-current) previous"), { repeating = true, description = "Media: previous track (current player)" })
-- restored from the old KDE setup (net.local.playerctl-2/5.desktop, kglobalshortcutsrc: Meta+Ctrl+Shift+Z/X).
-- ~/.config/hypr/scripts/playerctl-seek.sh keeps the original Exec='s pause+play "kick" after
-- seeking, but only resumes play if the player was actually playing before the seek.
hl.bind(mainMod .. " + CTRL + SHIFT + z", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-seek.sh -"), { repeating = true, description = "Media: seek back (current player)" })
hl.bind(mainMod .. " + CTRL + SHIFT + x", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-seek.sh +"), { repeating = true, description = "Media: seek forward (current player)" })
-- Player picker: reimplemented as a themed quickshell overlay
-- (quickshell/bar/MprisPicker.qml), driven by the single top-level
-- `mprisPicker` IpcHandler in shell.qml. Still writes the same bare player
-- name to ~/.config/playerctl-current. A second press toggles it closed --
-- same feel as the bar's own panels / the clipboard picker -- so no
-- `repeating` (it's a one-shot toggle now, not a held dialog).
hl.bind("ALT + CTRL + SHIFT + m", hl.dsp.exec_cmd("qs ipc call mprisPicker toggle"), { description = "MPRIS player picker" })
-- ~/.config/hypr/scripts/playerctl-volume.sh: local sink, unless
-- playerctl-current is pixel6, in which case its MPRIS Volume (-> phone
-- STREAM_MUSIC) instead. See pixel6-mpris-bridge.py for the MPRIS side.
hl.bind(mainMod .. " + F11", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-volume.sh -"), { repeating = true, description = "Player / phone volume down" })
hl.bind(mainMod .. " + F12", hl.dsp.exec_cmd("~/.config/hypr/scripts/playerctl-volume.sh +"), { repeating = true, description = "Player / phone volume up" })

-- move windows (reflow the active window's tiled position in a direction,
-- without swapping places with whatever was there -- equivalent to the old
-- .conf's "movewindow" dispatcher; window.swap is the true two-window trade)
hl.bind(mainMod .. " + CTRL + h", hl.dsp.window.move({ direction = "left" }),  { description = "Move window left" })
hl.bind(mainMod .. " + CTRL + j", hl.dsp.window.move({ direction = "down" }),  { description = "Move window down" })
hl.bind(mainMod .. " + CTRL + k", hl.dsp.window.move({ direction = "up" }),    { description = "Move window up" })
hl.bind(mainMod .. " + CTRL + l", hl.dsp.window.move({ direction = "right" }), { description = "Move window right" })

-- resize (old .conf: "resizeactive, -80 0" -- a relative pixel delta)
-- confirmed field names from LuaBindingsDispatchers.cpp: x, y (numbers), relative (bool, default false)
hl.bind("SHIFT + ALT + h", hl.dsp.window.resize({ x = -80, y = 0,  relative = true }), { description = "Resize window: narrower" })
hl.bind("SHIFT + ALT + j", hl.dsp.window.resize({ x = 0,   y = 80, relative = true }), { description = "Resize window: taller" })
hl.bind("SHIFT + ALT + k", hl.dsp.window.resize({ x = 0,   y = -80, relative = true }), { description = "Resize window: shorter" })
hl.bind("SHIFT + ALT + l", hl.dsp.window.resize({ x = 80,  y = 0,  relative = true }), { description = "Resize window: wider" })

-- hjkl focus
hl.bind(mainMod .. " + h", hl.dsp.focus({ direction = "left" }),  { description = "Focus the window to the left" })
hl.bind(mainMod .. " + j", hl.dsp.focus({ direction = "down" }),  { description = "Focus the window below" })
hl.bind(mainMod .. " + k", hl.dsp.focus({ direction = "up" }),    { description = "Focus the window above" })
hl.bind(mainMod .. " + l", hl.dsp.focus({ direction = "right" }), { description = "Focus the window to the right" })

-- app launcher (quickshell, ~/.config/quickshell/launcher/ -- replaced
-- `rofi -show drun`). A second tap toggles it closed; Escape also closes.
hl.bind(mainMod .. " + Super_l", hl.dsp.exec_cmd("qs ipc call launcher toggle"), { release = true, description = "Open the app launcher" })

-- master/stack layout cycling
-- NOTE: this rebinds mainMod + R, already bound above to launch $menu. Same conflict existed
-- in the original .conf (last bind wins), so mainMod + R currently cycles the master layout
-- orientation rather than launching the menu. Preserved as-is -- flag if this wasn't intentional.
hl.bind(mainMod .. " + R",         hl.dsp.layout("orientationcycle"), { description = "Cycle master-layout orientation" })
hl.bind(mainMod .. " + SHIFT + R", hl.dsp.layout("orientationprev"), { description = "Cycle master-layout orientation (reverse)" })

-- promote the focused window to master (swaps it with whatever is currently
-- master, per master layout's "swap" default mode)
hl.bind(mainMod .. " + Return", hl.dsp.layout("swapwithmaster"), { description = "Swap the active window with the master window" })
