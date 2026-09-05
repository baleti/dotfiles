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

-- No blur rule for the quickshell notification layer
-- (namespace "quickshell-notifications"): unlike the old notifyd, whose
-- GTK popups were each sized to their card, the quickshell layer is one
-- persistent full-height surface per monitor, so `blur = true` on it
-- painted a permanent blurred column down the right edge of every screen.
-- The cards are translucent (Theme.bgAlpha) and read fine without blur.

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

-- Reddit architecture-engagement bot (systemd --user timer, 3x/day,
-- ~/.local/share/reddit-architecture-bot/run.sh -> chromium-automation-profile-2
-- on CDP port 9223, launched with --class=RedditArchitectureBot). run.sh also
-- moves it into special:redditbot at the start of every run so it never sits
-- on a visible workspace, but keep no_focus too in case a window briefly maps
-- before that move lands.
hl.window_rule({
    name  = "reddit-architecture-bot-no-focus",
    match = { class = "RedditArchitectureBot" },

    no_focus = true,
})
