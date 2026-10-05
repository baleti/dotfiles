-- ctrl+x d: delete (rm) the file currently playing (not the playlist), after a y/n prompt.
-- mpv has no native key chords, so ctrl+x arms a short-lived set of forced bindings.
local mp = require "mp"

local armed = {}  -- names of temporary bindings currently installed
local timer

local function disarm()
    for _, name in ipairs(armed) do mp.remove_key_binding(name) end
    armed = {}
    if timer then timer:kill() timer = nil end
    mp.osd_message("", 0)
end

local function arm(keys, msg, timeout)
    disarm()
    for key, fn in pairs(keys) do
        local name = "delcur-" .. key
        mp.add_forced_key_binding(key, name, function() disarm() fn() end)
        armed[#armed + 1] = name
    end
    mp.osd_message(msg, timeout)
    timer = mp.add_timeout(timeout, disarm)
end

local function delete_current()
    local path = mp.get_property("path")
    if not path or path:match("^%a[%w+.-]*://") then
        mp.osd_message("Not a local file")
        return
    end
    local abs = mp.command_native({"expand-path", path})
    local pos = mp.get_property_number("playlist-pos", 0)
    local count = mp.get_property_number("playlist-count", 1)
    local res = mp.command_native({name = "subprocess", args = {"rm", "--", abs}})
    if res.status ~= 0 then
        mp.osd_message("Delete failed: " .. (res.stderr or ""):gsub("\n", " "), 3)
        return
    end
    mp.osd_message("Deleted: " .. abs, 2)
    if count > 1 then
        mp.commandv("playlist-remove", "current")
    else
        mp.commandv("quit")
    end
end

local function prompt()
    local name = (mp.get_property("filename") or "?")
    arm({
        y = delete_current,
        n = function() mp.osd_message("Delete cancelled", 1) end,
        ESC = function() mp.osd_message("Delete cancelled", 1) end,
    }, "Delete " .. name .. " ? (y/n)", 10)
end

mp.add_key_binding(nil, "delete-prompt", prompt)

local function chord()
    arm({ d = prompt, ESC = disarm }, "ctrl+x - d: delete current file", 3)
end
mp.add_forced_key_binding("ctrl+x", "delcur-chord", chord)
