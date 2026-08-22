-- Stops Hyprland's own mainMod-based binds (app launchers, rofi-on-tap,
-- alt-tab, etc.) from also firing while an xfreerdp window is focused, so
-- those keys reach the remote Windows session untouched instead of double-
-- firing here too.
--
-- Why this can't be a windowrule or an xfreerdp flag: xfreerdp is an
-- XWayland client (confirmed: `ldd $(which xfreerdp3)` links only
-- libX11/libxcb, no libwayland-client; `hyprctl clients` shows
-- xwayland:true for it). Its own keyboard grab (XGrabKeyboard) only
-- reaches XWayland's internal X server -- Hyprland's bind matching happens
-- upstream of that, with no visibility into it. Remmina, by contrast, is a
-- native Wayland client (links libwayland-client, xwayland:false) and can
-- request the real zwp_keyboard_shortcuts_inhibit_v1 protocol, which is why
-- mainMod combos are correctly captured there but leak through on xfreerdp.
--
-- Swapping to an emptied submap is the practical workaround: submaps
-- replace the active bind set rather than adding to it, so every global
-- bind -- not just the ones we know collide -- stops matching while this is
-- active, and falls through as raw input to whatever's focused.

-- Whether the guard is allowed to auto-arm on focus is a persisted
-- preference, not just in-memory state: without this, toggling off with
-- Pause would only last until the next focus change (window.active would
-- silently re-arm it the moment you looked away and back), and a Hyprland
-- restart/reboot would forget the choice entirely.
local STATE_FILE = os.getenv("HOME") .. "/.local/state/rdp-guard-enabled"

local function guard_enabled()
    local f = io.open(STATE_FILE, "r")
    if not f then
        return true -- default: on, matching original behavior before this existed
    end
    local v = f:read("*l")
    f:close()
    return v ~= "0"
end

local function set_guard_enabled(enabled)
    local f = io.open(STATE_FILE, "w")
    if f then
        f:write(enabled and "1" or "0")
        f:close()
    end
end

hl.define_submap("rdp-guard", function()
    -- Tap-to-release only (mirrors the existing mainMod + Super_l rofi-tap
    -- bind in keybinds.lua). Originally tried Right Ctrl (matching
    -- xfreerdp's own "release keyboard/mouse grab" hotkey), in two forms:
    -- bare "Control_R", and "CTRL + Control_R" (the modifier-flag +
    -- own-keysym pattern that mainMod + Super_l relies on). Neither ever
    -- fired -- confirmed with debug logging, kernel-level packet capture,
    -- and a source-level trace into Hyprland's own keybind dispatch
    -- (reported upstream: hyprwm/Hyprland#15952). Pause has no such issue
    -- and is confirmed working end-to-end.
    hl.bind("Pause", function()
        set_guard_enabled(false)
        hl.dispatch(hl.dsp.submap("reset"))
    end, { release = true })
end)

hl.on("window.active", function(win)
    if win and win.class == "xfreerdp" and guard_enabled() then
        hl.dispatch(hl.dsp.submap("rdp-guard"))
    else
        hl.dispatch(hl.dsp.submap("reset"))
    end
end)

-- Pause inside the guard submap drops back to normal binds and persists
-- that choice (see above). This is the other half: tapping Pause while
-- xfreerdp is focused (but the guard is currently off) re-arms it and
-- persists that too, making the two binds together a real toggle rather
-- than a one-way exit. A no-op everywhere else, since it only acts when
-- xfreerdp is focused.
hl.bind("Pause", function()
    local win = hl.get_active_window()
    if win and win.class == "xfreerdp" then
        set_guard_enabled(true)
        hl.dispatch(hl.dsp.submap("rdp-guard"))
    end
end, { release = true })
