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
    -- UBUNTU_MENUPROXY=0: appmenu-gtk3-parser's DBus menu-export walk hits
    -- infinite recursion (gtk_widget_map <-> g_signal_emit) building GIMP's
    -- large Filters/Script-Fu menu tree, stack-overflows, SIGSEGV. Confirmed
    -- via coredump backtrace (37k+ frames) and bisecting env vars; the module
    -- loads unconditionally regardless of gtk-modules/gtk-shell-shows-menubar,
    -- so this is the only working disable. Global menu stays on for every
    -- other app.
    { key = "4", slug = "gimp",        class = "gimp",                         cmd = "env UBUNTU_MENUPROXY=0 gimp-3.2" },
    { key = "5", slug = "signal",      class = "org.signal.Signal",            cmd = "flatpak run org.signal.Signal" },
    { key = "6", slug = "inkscape",    class = "org.inkscape.Inkscape",        cmd = "inkscape" },
    { key = "7", slug = "recoll",      class = "recoll",                       cmd = "recoll" },
}
