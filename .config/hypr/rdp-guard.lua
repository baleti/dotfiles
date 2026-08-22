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

hl.define_submap("rdp-guard", function()
    -- Tap-to-release only (mirrors the existing mainMod + Super_l rofi-tap
    -- bind in keybinds.lua). Originally tried Right Ctrl (matching
    -- xfreerdp's own "release keyboard/mouse grab" hotkey), in two forms:
    -- bare "Control_R", and "CTRL + Control_R" (the modifier-flag +
    -- own-keysym pattern that mainMod + Super_l relies on). Neither ever
    -- fired -- confirmed with debug logging, and confirmed independent of
    -- xfreerdp (tested the CTRL+Control_R form globally, unscoped). Root
    -- cause unconfirmed; best guess is Hyprland's modifier-tap-alone
    -- handling isn't as reliable for Ctrl as it is for Super. Pause has no
    -- such issue and is confirmed working end-to-end.
    hl.bind("Pause", hl.dsp.submap("reset"), { release = true })
end)

hl.on("window.active", function(win)
    if win and win.class == "xfreerdp" then
        hl.dispatch(hl.dsp.submap("rdp-guard"))
    else
        hl.dispatch(hl.dsp.submap("reset"))
    end
end)

-- Pause inside the guard submap drops back to normal binds (see above), but
-- window.active only re-arms the guard on an actual focus transition -- it
-- won't fire again just because you're still looking at the same xfreerdp
-- window. This is the other half: tapping Pause while xfreerdp is focused
-- (but the guard is currently off) re-arms it, making the two binds
-- together a real toggle rather than a one-way exit. A no-op everywhere
-- else, since it only acts when xfreerdp is focused.
hl.bind("Pause", function()
    local win = hl.get_active_window()
    if win and win.class == "xfreerdp" then
        hl.dispatch(hl.dsp.submap("rdp-guard"))
    end
end, { release = true })
