-- Cursor-centric zoom (like the built-in positioning/cursor-centric-zoom) without the "video-zoom" OSD message.
-- mpv names this script "quiet_zoom" (dashes become underscores): bind as quiet_zoom/in and quiet_zoom/out.
local function zoom_at_cursor(inc)
    local d = mp.get_property_native("osd-dimensions")
    local m = mp.get_property_native("mouse-pos")
    local f = 2 ^ inc
    local zoom = mp.get_property_number("video-zoom") + inc
    if not d or not m or d.w == 0 or d.h == 0 then
        mp.set_property_number("video-zoom", zoom)
        return
    end
    local W, H = d.w - d.ml - d.mr, d.h - d.mt - d.mb
    if W <= 0 or H <= 0 then
        mp.set_property_number("video-zoom", zoom)
        return
    end
    local px, py = mp.get_property_number("video-pan-x"), mp.get_property_number("video-pan-y")
    local dx, dy = m.x - d.w / 2, m.y - d.h / 2
    mp.set_property_number("video-zoom", zoom)
    mp.set_property_number("video-pan-x", px + dx / (W * f) - dx / W)
    mp.set_property_number("video-pan-y", py + dy / (H * f) - dy / H)
end

mp.add_key_binding(nil, "in", function() zoom_at_cursor(0.1) end)
mp.add_key_binding(nil, "out", function() zoom_at_cursor(-0.1) end)
