-- Pinned "launch / focus / hide" apps, ported from KDE's Task Manager pinned
-- launchers (see ~/.config/plasma-org.kde.plasma.desktop-appletsrc "launchers="
-- and ~/.config/kglobalshortcutsrc "activate task manager entry N").
-- Shared by keybinds.lua (toggle binds), windowrules.lua (spawn hidden into
-- their scratch workspace), and hyprland.lua (autostart).
--
-- `class` is the literal window class (hyprctl clients -j | jq '.[].class'),
-- used as an exact match by get_windows and as an anchored regex in window rules.
return {
    { key = "1", slug = "fsearch",     class = "io.github.cboxdoerfer.FSearch", cmd = "fsearch" },
    { key = "2", slug = "element",     class = "Element",                      cmd = "element-desktop" },
    { key = "3", slug = "thunderbird", class = "org.mozilla.Thunderbird",      cmd = "thunderbird" },
    { key = "4", slug = "gimp",        class = "gimp",                         cmd = "gimp-3.2" },
    -- --force-renderer-accessibility forces Electron/Chromium's AT-SPI bridge
    -- on unconditionally (see keybinds.lua's mod+A / appmenu-atspi.py); passed
    -- through the flatpak sandbox via `--` since it's just an argv switch.
    { key = "5", slug = "signal",      class = "org.signal.Signal",            cmd = "flatpak run org.signal.Signal -- --force-renderer-accessibility" },
    { key = "6", slug = "inkscape",    class = "org.inkscape.Inkscape",        cmd = "inkscape" },
    { key = "7", slug = "recoll",      class = "recoll",                       cmd = "recoll" },
}
