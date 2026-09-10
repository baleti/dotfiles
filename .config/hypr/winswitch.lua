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
-- only, no special-workspace scratchpads, ascending focus_history_id (0 =
-- most recently focused).
local function window_list_json()
    local rows = {}
    for _, w in ipairs(hl.get_windows({})) do
        local wsname = w.workspace and w.workspace.name or ""
        if w.mapped and not wsname:find("^special:") then
            rows[#rows + 1] = { w = w, ws = wsname }
        end
    end
    table.sort(rows, function(a, b) return a.w.focus_history_id < b.w.focus_history_id end)
    local parts = {}
    for _, r in ipairs(rows) do
        local w, size = r.w, r.w.size or {}
        parts[#parts + 1] = string.format(
            '{"address":%s,"class":%s,"title":%s,"workspace":%s,"pid":%d,"width":%d,"height":%d,"active":%s}',
            json_str(w.address), json_str(w.class), json_str(w.title), json_str(r.ws),
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
