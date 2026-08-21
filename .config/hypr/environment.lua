-----------------------------
---- ENVIRONMENT VARIABLES ---
-----------------------------

-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("AQ_DRM_DEVICES",
    "/home/user1/.config/hypr/Intel-integrated-GPU-DRI-card:" ..
    "/home/user1/.config/hypr/nvidia-DRI-card:" ..
    "/home/user1/.config/hypr/displaylink-DRI-card")
hl.env("QT_QPA_PLATFORMTHEME", "kde")

-- A real Plasma session sources ~/.config/plasma-localerc (System Settings >
-- Formats) into the session environment at login. Hyprland never does, so
-- KDE apps like Dolphin fall back to whatever LC_TIME the compositor started
-- with (LANG=en_US.UTF-8 -> Month/day/year dates in the Modified column).
hl.env("LC_TIME", "en_GB.UTF-8")

-- Only needed for Dolphin (and other KIO apps) to resolve default applications
-- correctly -- without it, opening a file falls through to an empty/broken
-- xdg-desktop-portal-kde chooser instead of launching the assigned app.
-- Plasma 6 renamed the KDE menu file applications.menu -> plasma-applications.menu
-- (/etc/xdg/menus/plasma-applications.menu, from plasma-workspace). A real Plasma
-- session exports XDG_MENU_PREFIX=plasma- itself so kbuildsycoca6 can find it;
-- Hyprland never does, so kbuildsycoca6 silently builds an incomplete KSycoca cache
-- and KApplicationTrader::preferredService() (what Dolphin/KIO's OpenUrlJob actually
-- uses to resolve a file's default app -- NOT mimeapps.list directly, unlike xdg-open)
-- returns null even though mimeapps.list is correct. That's why Dolphin falls through
-- to the empty xdg-desktop-portal-kde "Choose Application" chooser instead of just
-- launching the configured default app.
hl.env("XDG_MENU_PREFIX", "plasma-")


-------------------
---- PERMISSIONS --
-------------------

-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Permissions/
-- Please note permission changes here require a Hyprland restart and are not applied on-the-fly
-- for security reasons

hl.config({
  ecosystem = {
    enforce_permissions = true,
  },
})

-- hyprshot (bound to Print, see keybinds.lua) shells out to grim for the
-- actual screencopy call, so allowing grim covers hyprshot too.
hl.permission({ binary = "/usr/(bin|local/bin)/grim", type = "screencopy", mode = "allow" })
hl.permission({ binary = "/usr/(lib|libexec|lib64)/xdg-desktop-portal-hyprland", type = "screencopy", mode = "allow" })
hl.permission({ binary = "/usr/(bin|local/bin)/hyprpm", type = "plugin", mode = "allow" })
hl.permission({ binary = "/usr/(bin|local/bin)/wf-recorder", type = "screencopy", mode = "allow" })
hl.permission({ binary = "/usr/(bin|local/bin)/wtype", type = "keyboard", mode = "allow" })

-- winswitch (~/.config/hypr/winswitch): grid alt-tab switcher, captures live
-- window thumbnails via hyprland-toplevel-export-v1.
hl.permission({ binary = "/home/user1/.config/hypr/winswitch/target/release/winswitch", type = "screencopy", mode = "allow" })
