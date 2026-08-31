-- Ctrl+h/j/k/l vim-style list navigation inside Dolphin: re-emits as
-- Left/Down/Up/Right. Dolphin's list view has no KActionCollection shortcut
-- for "move selection down/up" or "expand/collapse selected folder" -- those
-- are raw QAbstractItemView keyPressEvent handling, not configurable via
-- Dolphin's own Settings > Configure Shortcuts (confirmed against
-- dolphinui.rc: no action there is bound to any of Ctrl+h/j/k/l by default).
-- So this remaps at the Hyprland level instead, via send_shortcut, which
-- delivers a synthetic key event straight to the target client's
-- wl_keyboard -- Qt can't tell it apart from a real keypress.
--
-- Note: Ctrl+l IS a real Dolphin default (replace_location -- focus the
-- address bar, "Ctrl+L; Alt+D"), so this bind shadows it inside Dolphin;
-- only Alt+D still reaches the native shortcut. Deliberate trade-off for
-- vim-style navigation -- use Alt+D to edit the location bar instead.
--
-- Deliberately NOT a submap swap on window focus (unlike rdp-guard.lua):
-- a submap replaces the *entire* active keymap while it's active, which
-- would also silence mainMod launchers/volume keys/etc. whenever Dolphin is
-- focused -- way overkill just to add 4 chords. Instead each bind checks
-- focus at dispatch time and, outside Dolphin, re-emits the *original*
-- Ctrl+<key> chord via send_shortcut so apps that already use it keep
-- working -- e.g. Emacs binds Ctrl+j (newline-and-indent) by default, and a
-- global Hyprland bind on Ctrl+j would otherwise eat it everywhere, not
-- just in Dolphin.
local function dolphin_or_passthrough(orig_key, dolphin_mods, dolphin_key)
    return function()
        local win = hl.get_active_window()
        if win and win.class == "org.kde.dolphin" then
            hl.dispatch(hl.dsp.send_shortcut({ mods = dolphin_mods, key = dolphin_key }))
        else
            hl.dispatch(hl.dsp.send_shortcut({ mods = "CTRL", key = orig_key }))
        end
    end
end

hl.bind("CTRL + j", dolphin_or_passthrough("j", "", "Down"))
hl.bind("CTRL + k", dolphin_or_passthrough("k", "", "Up"))
hl.bind("CTRL + l", dolphin_or_passthrough("l", "", "Right"))
hl.bind("CTRL + h", dolphin_or_passthrough("h", "", "Left"))
