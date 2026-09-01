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
--
-- Confirmed by direct testing (2026-08): a KSycoca cache rebuilt with the correct
-- prefix is NOT enough on its own -- the var must be present in the *querying*
-- process's own environment at lookup time (Dolphin's, and xdg-desktop-portal-kde's,
-- which does its own independent KApplicationTrader lookup for the chooser UI).
-- Killing/restarting xdg-desktop-portal-kde was tested too and is irrelevant here --
-- it's D-Bus-activated by unrelated Flatpak apps (Signal, Flatseal) regardless, and
-- was never itself the root cause, just the visible symptom.
--
-- Also: this fix does NOT prevent every "nothing happens" file-open bug going
-- forward. ~/.config/mimeapps.list had accumulated many stale/nonexistent
-- .desktop references of its own (audited and fixed 2026-08-25) which cause the
-- exact same silent-failure symptom independently of this var. If a *new* file
-- type silently fails, check `xdg-mime query default <mimetype>` and whether
-- that .desktop file actually exists before assuming this fix regressed.
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

-- claude-usage's thumb-capture (~/.config/claude-usage/thumb-capture): the
-- claude-usage bar panel's hover-thumbnail helper, same protocol as
-- winswitch above. Without this it's not silently denied -- Hyprland pops
-- an interactive "Permission request" prompt instead, and since a fresh
-- process (a fresh Wayland client) is spawned per hover, that prompt fires
-- on essentially every hover with nobody there to click it in time before
-- thumb-capture's own 5s timeout gives up (reported 2026-09-01: "sometimes
-- it breaks... no thumbnail shows up"). See claude-usage.md's hover-
-- thumbnail section.
hl.permission({ binary = "/home/user1/.config/claude-usage/thumb-capture/target/release/thumb-capture", type = "screencopy", mode = "allow" })
