-- ctrl+j / ctrl+k move the selection down / up in the built-in pickers (g p, g t, ...).
-- console.lua binds those keys itself (submit / delete-to-eol) while it is open and they cannot be
-- overridden from input.conf, so shadow them with later forced bindings while the console is open
-- and forward Down / Up, which the picker already understands.
local mp = require "mp"

local bound = false

local function bind()
    if bound then return end
    bound = true
    mp.add_forced_key_binding("ctrl+j", "picker-nav-down", function() mp.commandv("keypress", "down") end,
                              {repeatable = true})
    mp.add_forced_key_binding("ctrl+k", "picker-nav-up", function() mp.commandv("keypress", "up") end,
                              {repeatable = true})
end

local function unbind()
    if not bound then return end
    bound = false
    mp.remove_key_binding("picker-nav-down")
    mp.remove_key_binding("picker-nav-up")
end

mp.observe_property("user-data/mpv/console/open", "bool", function(_, open)
    if open then
        -- console.lua installs its bindings after setting the property; wait so ours are added last.
        mp.add_timeout(0.05, function()
            if mp.get_property_bool("user-data/mpv/console/open") then bind() end
        end)
    else
        unbind()
    end
end)
