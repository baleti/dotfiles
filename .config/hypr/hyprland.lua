-- Main Hyprland config entry point.
-- See https://wiki.hypr.land/Configuring/Start/

---------------------
---- MY PROGRAMS ----
---------------------

terminal    = "alacritty"
fileManager = "dolphin"
menu        = "hyprlauncher"
mainMod     = "SUPER" -- Sets "Windows" key as main modifier

-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

local apps = require("apps")

-- Pinned app launchers (see apps.lua) are started hidden. This must only
-- apply to the windows opened by *this* autostart batch -- not to windows
-- from a later manual mainMod+N launch, and not to a dialog of an app that
-- is already running -- so it's a one-shot class->slug lookup consumed on
-- first match, rather than a persistent window rule.
--
-- Two things keep that "one-shot" honest, and both are load-bearing:
--   * the table is armed inside hyprland.start, not at file scope, because a
--     config reload re-runs this file but does not re-fire that event. Arming
--     at file scope re-armed every pinned class on each reload, so the next
--     window of such a class -- typically a dialog of a long-running app, e.g.
--     GIMP's "save before closing?" prompt -- silently vanished into the
--     scratch workspace.
--   * it expires, because an app that never maps a window at login (crashed,
--     not installed, quit before mapping) would otherwise leave its class
--     armed for the whole session, swallowing the window of a manual
--     mainMod+N launch hours later and making that launch look like a no-op.
-- The grace period only has to outlast this batch mapping its windows; the
-- flatpak/Electron apps here are the slow ones on a cold boot.
local AUTOSTART_HIDE_GRACE_MS = 120000

local pending_hide = {}
local autostart_hide_timer = nil -- kept referenced: a collected timer never fires

hl.on("window.open", function(win)
    local slug = pending_hide[win.class]
    if slug then
        pending_hide[win.class] = nil
        hl.dispatch(hl.dsp.window.move({ workspace = "special:scratch_" .. slug, window = win, follow = false }))
    end
end)

hl.on("hyprland.start", function()
    -- Makes WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE visible to every
    -- systemd --user unit, current and future - `systemctl --user
    -- import-environment` copies the named variables' CURRENT values from
    -- whatever process runs it into the --user MANAGER's own environment
    -- block (`systemctl --user show-environment`), and every unit that
    -- manager subsequently starts *or restarts* inherits that block
    -- automatically. This process is Hyprland's own child, so it already
    -- has both variables the moment this line runs - Hyprland has to set
    -- them for itself before doing anything else, to create its own IPC
    -- socket in the first place.
    --
    -- Root cause this closes: a systemd --user unit is not a child of
    -- Hyprland, so it never inherits these vars on its own - confirmed
    -- three separate times independently (claude-usage-daemon.py
    -- 2026-09-08, desktop-snapshot's snapshot.py 2026-09-18) as *empty*
    -- hyprctl results with no error, since hyprctl itself exits nonzero
    -- rather than falling back to the sole entry under
    -- $XDG_RUNTIME_DIR/hypr/ when the signature is unset - each fix ended
    -- up independently reinventing the same per-daemon env lookup instead
    -- of this being set once, centrally. Specifically fixes the
    -- Restart=always case: a unit's `After=graphical-session.target` only
    -- orders its very first start, a later crash/restart respawn skips
    -- that check entirely and just re-execs against whatever the
    -- manager's environment happens to be at that instant - two
    -- back-to-back desktop-snapshot.service restarts right after a reboot
    -- (2026-09-17) landed in exactly that gap before this import ran.
    --
    -- Does NOT help systemd --user units with no After=graphical-session.target
    -- gating that a timer can fire while lingering (loginctl Linger=yes for
    -- this account) with no Hyprland running at all, e.g.
    -- linkedin-engagement-bot.service/reddit-architecture-bot.service -
    -- there's nothing to import when Hyprland genuinely isn't up. Those
    -- guard their own hyprctl calls separately instead.
    hl.exec_cmd("systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY")
    -- wl-paste tags copies flagged x-kde-passwordManagerHint=secret (app
    -- passwords, generated passwords, TOTP codes, etc.) with
    -- CLIPBOARD_STATE=sensitive, and cliphist silently skips storing those.
    -- The wrapper below deliberately overrides that too, so everything
    -- still lands in history -- retention is bounded instead by
    -- ~/.config/hypr/scripts/cliphist-expire.sh (see cliphist-expire.timer).
    --
    -- Routed through cliphist-store-logged.sh rather than `cliphist store`
    -- directly (as this used to be, via `exec` so wl-paste's stdin passed
    -- straight through) because cliphist itself keeps no per-entry
    -- timestamp - the wrapper also appends one to a small log, which is
    -- what clipboard-picker's $date: field reads from. See that script's
    -- own comment for how it correlates a log line to the right id.
    hl.exec_cmd([[wl-paste --watch ~/.config/hypr/scripts/cliphist-store-logged.sh]])
    -- wl-clip-persist, notifyd and sysmond used to be started here via
    -- hl.exec_cmd -- moved to systemd --user units (2026-09-13) so a crash
    -- gets Restart=always instead of staying dead until the next full
    -- Hyprland restart. The import-environment call above is what actually
    -- guarantees WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE are present
    -- for graphical-session.target-gated units, restart or not - see:
    --   ~/.config/systemd/user/wl-clip-persist.service
    --   ~/.config/systemd/user/notifyd.service -- owns
    --     org.freedesktop.Notifications, replaced dunst (dunst's package is
    --     untouched, its unit masked; rollback: `systemctl --user disable
    --     --now notifyd`, re-enable `dunst.service`). Headless since
    --     2026-08-30 -- cards are drawn by quickshell
    --     (~/.config/quickshell/notifications/, off
    --     ~/.cache/notifyd/state.json).
    --   ~/.config/systemd/user/sysmond.service -- feeds the bar's
    --     hover-graphs and the alt+mod+n/p/t/m popups. Every consumer
    --     (SysmonSvc's TieredSocket/ProcHistSocket and its topCpu/Mem/Net/
    --     Disk sockets) already carries a 2s reconnect timer (2026-08-29,
    --     a5240aede1) that re-asserts `connected = true` while wanted, so a
    --     sysmond restart is picked back up on its own -- no `qs kill`
    --     needed.
    -- Load the theme's nsxiv colors (Nsxiv.* X resources) into the XWayland
    -- server now -- gen-theme.py also does this on every regen, but the
    -- wallpaper (hence that script) may not have changed yet this session.
    hl.exec_cmd("[ -f ~/.config/nsxiv/xresources ] && xrdb -merge ~/.config/nsxiv/xresources")
    -- Rotates through ~/pictures every 15 minutes via set-wallpaper.sh --
    -- a "for now" testing cadence (2026-08-28) to exercise the automatic
    -- re-theming above, not a considered final value. Remove this line to
    -- go back to a single static wallpaper.
    hl.exec_cmd("~/.config/hypr/scripts/wallpaper-rotate.sh")
    -- 2026-08-27: replaced by a custom quickshell bar (~/.config/quickshell/),
    -- built from scratch after trying and reverting caelestia-shell. Revert:
    -- uncomment this line, and kill/disable `qs -n -d` if it's running.
    -- hl.exec_cmd("waybar")
    hl.exec_cmd("qs -n -d")

    for _, app in ipairs(apps) do
        pending_hide[app.class] = app.slug
        hl.exec_cmd(app.cmd)
    end

    autostart_hide_timer = hl.timer(function()
        pending_hide = {}
    end, { timeout = AUTOSTART_HIDE_GRACE_MS, type = "oneshot" })
end)

require("environment")
require("monitors")
require("appearance")
require("input")
require("keybinds")
require("windowrules")
require("rdp-guard")
require("winswitch")
require("dolphin-vim")
