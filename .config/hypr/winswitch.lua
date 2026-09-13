-- Alt-tab key handling, done inside the compositor (2026-09-10 overhaul).
--
-- The Quickshell grid (~/.config/quickshell/winswitch/,
-- services/WinSwitchState.qml) never sees the raw keys. This file turns them
-- into ordered events on Hyprland's own event socket (socket2), which
-- Quickshell is already subscribed to (`Hyprland.rawEvent`):
--
--   custom>>winswitch tab next|prev   (window list, MRU order, written to
--                                      $XDG_RUNTIME_DIR/winswitch-windows.json
--                                      just before)
--   custom>>winswitch altup
--
-- Why not the previous `exec_cmd("qs ipc call winswitch cycle ...")` +
-- `hyprctl repl is_key_down` polling from QML: every press forked a process,
-- so presses could land out of order or be mistaken for auto-repeat. Alt state
-- was read once, after a debounce, by yet another process, and the window
-- order came from Quickshell's cached toplevel snapshot rather than
-- Hyprland's live focus history. Here, everything stays in-process and
-- strictly ordered: a tab event carries the compositor's own
-- focus_history_id order *at the moment of the press*, and Alt release is
-- watched by an in-compositor timer rather than a key-release bind (no global
-- Alt bind that could interfere with apps using Alt).
--
-- The window list is NOT simply Hyprland's live clients sorted by native
-- focus_history_id (that was the 2026-09-10 version, and it lies): focusing
-- a specific window on a workspace that isn't active goes through the
-- compositor's own workspace-switch step first, which implicitly refocuses
-- whatever window was already that workspace's own last-active one -- and
-- that phantom refocus bumps focus_history_id exactly like a real visit.
-- Diagnosed 2026-09-13 (reported as "picking a window in the ctrl+alt+c
-- claude-usage panel, then Alt+Tab, lands one window off"): confirmed live
-- via `hyprctl repl` that a single `hl.dsp.focus({window=w})` cross-workspace
-- call fires 2-3 `window.active` events, only the last of which is the
-- window actually asked for. Fixed by tracking our own history from
-- `hl.on("window.active", ...)`, keyed off Desktop::eFocusReason
-- (src/desktop/state/FocusState.hpp) so the implicit bump never gets
-- confused with a real one -- see FOCUS_REASON_WORKSPACE_CHANGE below.

local ALT_POLL_MS = 10

local function json_str(s)
    local escaped = tostring(s or ""):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. escaped .. '"'
end

local function int(n)
    return math.floor(tonumber(n) or 0)
end

-- Same filtering the old backend's hyprctl.rs::list_windows used: mapped
-- only, no special-workspace scratchpads.
local function is_trackable(w)
    local wsname = w.workspace and w.workspace.name or ""
    return w.mapped and not wsname:find("^special:")
end

-- Our own MRU, [1] = most recently (really) focused. Corrected live from
-- `window.active` events instead of trusted from Hyprland's raw
-- focus_history_id -- see the file-top comment for why.
local history = {}
-- Address of a history[1] entry pushed for FOCUS_REASON_WORKSPACE_CHANGE
-- that hasn't been confirmed yet -- still revocable if a different window
-- settles right after (see active_sub below).
local phantom = nil

local function history_remove(addr)
    for i, a in ipairs(history) do
        if a == addr then
            table.remove(history, i)
            return
        end
    end
end

local function history_push(addr)
    history_remove(addr)
    table.insert(history, 1, addr)
end

-- Hyprland tags every focus change with why it happened
-- (Desktop::eFocusReason, src/desktop/state/FocusState.hpp). No symbolic
-- constant is exposed to Lua -- confirmed live via `hyprctl repl` against
-- this Hyprland 0.56.2 install -- so this is that enum's ordinal (11, its
-- 12th entry, 0-indexed): fragile across a Hyprland enum reorder, but
-- there's nothing else to bind to.
local FOCUS_REASON_WORKSPACE_CHANGE = 11

local active_sub -- kept referenced: a collected subscription never fires
active_sub = hl.on("window.active", function(w, reason)
    local addr = tostring(w.address)
    if addr == phantom and reason ~= FOCUS_REASON_WORKSPACE_CHANGE then
        -- Same window re-confirmed under a different reason right after its
        -- own workspace-change bump (observed live: reason 11 then 2 for the
        -- same address, immediately before the real target's reason-3
        -- event). Still not a real visit -- leave it revocable.
        return
    end
    if reason == FOCUS_REASON_WORKSPACE_CHANGE then
        history_push(addr)
        phantom = addr
        return
    end
    if phantom and phantom ~= addr then
        -- A different window settled right after: that workspace-change
        -- placeholder was never a real visit. Undo it.
        history_remove(phantom)
    end
    phantom = nil
    history_push(addr)
end)

-- Seed from Hyprland's own history once at load so the list isn't empty
-- until the first focus change (config reload recreates active_sub and runs
-- this file fresh, per CLuaEventHandler's own lifetime).
do
    local rows = {}
    for _, w in ipairs(hl.get_windows({})) do
        if is_trackable(w) then
            rows[#rows + 1] = w
        end
    end
    table.sort(rows, function(a, b) return a.focus_history_id < b.focus_history_id end)
    for i = #rows, 1, -1 do
        history_push(tostring(rows[i].address))
    end
end

local function window_list_json()
    local live, liveList = {}, {}
    for _, w in ipairs(hl.get_windows({})) do
        if is_trackable(w) then
            local addr = tostring(w.address)
            live[addr] = w
            liveList[#liveList + 1] = w
        end
    end

    -- Passive sweep: drop addresses history/phantom still remember that no
    -- longer resolve to a live window (closed since).
    for i = #history, 1, -1 do
        if not live[history[i]] then
            table.remove(history, i)
        end
    end
    if phantom and not live[phantom] then
        phantom = nil
    end

    local order, seen = {}, {}
    for _, addr in ipairs(history) do
        local w = live[addr]
        if w and not seen[addr] then
            order[#order + 1] = w
            seen[addr] = true
        end
    end
    -- Any live window history hasn't seen yet (brand new): append in
    -- whatever order hl.get_windows gave it.
    for _, w in ipairs(liveList) do
        local addr = tostring(w.address)
        if not seen[addr] then
            order[#order + 1] = w
            seen[addr] = true
        end
    end

    local parts = {}
    for _, w in ipairs(order) do
        local size = w.size or {}
        parts[#parts + 1] = string.format(
            '{"address":%s,"class":%s,"title":%s,"workspace":%s,"pid":%d,"width":%d,"height":%d,"active":%s}',
            json_str(w.address), json_str(w.class), json_str(w.title),
            json_str(w.workspace and w.workspace.name or ""),
            int(w.pid), int(size.x or size[1]), int(size.y or size[2]), tostring(w.active == true))
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function emit(data)
    hl.dispatch(hl.dsp.event("winswitch " .. data))
end

local function alt_down()
    return hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R")
end

local alt_timer -- kept referenced: a collected timer never fires
alt_timer = hl.timer(function()
    if not alt_down() then
        alt_timer:set_enabled(false)
        emit("altup")
    end
end, { timeout = ALT_POLL_MS, type = "repeat" })
alt_timer:set_enabled(false)

-- Global so it's reachable from `hyprctl dispatch`/`hyprctl repl` too:
-- `hyprctl repl 'winswitch.tab("next")'` runs exactly what the bind runs
-- (with Alt not physically held, that's a quick tap).
winswitch = {}

-- Hyprland truncates socket2 event lines at ~1KB (measured: a 3KB custom
-- event arrived as 1032 chars), far below a ~50-window list, so the list
-- goes through a tmpfs file (atomic rename) and the event is just the signal.
local LIST_FILE = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/winswitch-windows.json"

local function write_window_list()
    local tmp = LIST_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(window_list_json())
    f:close()
    os.rename(tmp, LIST_FILE)
end

function winswitch.tab(direction)
    write_window_list()
    emit("tab " .. direction)
    if not alt_timer:is_enabled() then
        alt_timer:set_enabled(true)
    end
end

-- Focus by address, for Quickshell's `Hyprland.dispatch(...)`: a dispatch
-- request is evaluated as `hl.dispatch(<request>)`, so
-- `winswitch.focus("0x...")` has to *return* a dispatcher. Matching happens
-- here because `hl.get_windows({ address = ... })` doesn't filter (see
-- hyprland_lua_binding_dispatch_syntax memory).
function winswitch.focus(address)
    for _, w in ipairs(hl.get_windows({})) do
        if tostring(w.address) == address then
            return hl.dsp.focus({ window = w })
        end
    end
    return hl.dsp.no_op()
end

hl.bind("ALT + Tab", function() winswitch.tab("next") end, { description = "Window switcher (next)" })
hl.bind("ALT + SHIFT + Tab", function() winswitch.tab("prev") end, { description = "Window switcher (previous)" })
