# Sourced for every zsh (login, interactive, scripts) -- put environment here,
# not in .zshrc, so it also covers shells spawned by a pre-existing tmux server.

# KDE menu prefix. Plasma 6 ships only /etc/xdg/menus/plasma-applications.menu;
# without this, kbuildsycoca6 finds no application menu and builds a stunted
# ksycoca cache with no app catalog. Since that cache is shared, ONE KIO/KService
# program started from a terminal that lacks this var (dolphin, kate, kioclient,
# kbuildsycoca6, xdg-open, kreadconfig...) silently rebuilds and poisons it for
# every app -- Dolphin then can't resolve default applications and falls through
# to an empty xdg-desktop-portal-kde chooser. Hyprland's environment.lua already
# exports this for its own children + the systemd/dbus activation env; this line
# closes the terminal/tmux gap. See commit 31d6c4a.
export XDG_MENU_PREFIX=plasma-
