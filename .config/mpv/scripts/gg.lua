-- vim-style "g g": second g within 1s jumps to the first playlist entry
local last = 0
mp.add_forced_key_binding("g", "gg", function()
    local now = mp.get_time()
    if now - last < 1 then
        last = 0
        mp.commandv("playlist-play-index", 0)
    else
        last = now
    end
end)
