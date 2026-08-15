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
