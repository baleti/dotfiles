--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

-- See https://wiki.hypr.land/Configuring/Basics/Window-Rules/
-- See https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/ for workspace rules

hl.window_rule({
    -- Ignore maximize requests from all apps. You'll probably like this.
    name  = "suppress-maximize-events",
    match = { class = ".*" },

    suppress_event = "maximize",
})

-- The quickshell notification cards (~/.config/quickshell/notifications/,
-- rendered for the headless notifyd) set this namespace so this rule can
-- find them -- layer-shell surfaces don't get appearance.lua's
-- decoration.blur automatically the way normal windows do. Needs the card
-- background to actually be translucent (Theme.bgAlpha) or there's nothing
-- for the blur to show through.
hl.layer_rule({
    name  = "blur-notifications",
    match = { namespace = "^quickshell-notifications$" },

    blur = true,
})

hl.window_rule({
    -- Fix some dragging issues with XWayland
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },

    no_focus = true,
})

-- Hyprland-run windowrule
hl.window_rule({
    name  = "move-hyprland-run",
    match = { class = "hyprland-run" },

    move  = "20 monitor_h-120",
    float = true,
})

-- Background job-search automation (Playwright/Chromium, launched via
-- ~/.local/share/architect-job-search/lib/browser.js with --class=ArchitectJobAutomation).
-- These pop up headed (Cloudflare blocks headless on Dezeen) on whatever workspace is
-- active, possibly while the user is doing something else there - don't let them steal
-- keyboard/mouse focus.
hl.window_rule({
    name  = "architect-job-automation-no-focus",
    match = { class = "ArchitectJobAutomation" },

    no_focus = true,
})
