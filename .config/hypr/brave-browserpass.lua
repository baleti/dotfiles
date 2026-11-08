-- Ctrl+Shift+L -> Ctrl+Shift+Y inside Brave, so the browserpass extension
-- (its popup command is bound to Ctrl+Shift+Y, see ~/.browserpass-ext/manifest.json)
-- opens on the shortcut the user wants. Brave swallows a real Ctrl+Shift+L
-- before extension commands see it (wev confirmed the compositor delivers it
-- fine), so remap at the Hyprland level via send_shortcut, same technique as
-- dolphin-vim.lua. Outside Brave the original chord is re-emitted untouched.
hl.bind("CTRL + SHIFT + l", function()
    local win = hl.get_active_window()
    if win and win.class == "brave-browser" then
        hl.dispatch(hl.dsp.send_shortcut({ mods = "CTRL SHIFT", key = "y" }))
    else
        hl.dispatch(hl.dsp.send_shortcut({ mods = "CTRL SHIFT", key = "l" }))
    end
end, { description = "Brave: Ctrl+Shift+L opens browserpass (sent as Ctrl+Shift+Y)" })
