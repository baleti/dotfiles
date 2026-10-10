-- group-open (~/bin/group-open) staging hook.
--
-- group-open spawns its viewers itself, so they are genuine child processes of it (they
-- show up together in htop's tree view / pstree). To keep them off the user's screen
-- while they load, this hook moves each new window to that run's private staging
-- workspace *as it is created* -- `window.open_early` fires before the window is mapped,
-- focused or drawn, so nothing flashes and focus is left alone (measured).
--
-- A window is moved only if its process descends from a pid that registered itself in
-- $XDG_RUNTIME_DIR/group-open.reg ("<pid> <staging workspace>" per line). group-open adds
-- its line when it starts and removes it as soon as loading is over, so outside a run
-- this costs one failed io.open per new window. Everything is wrapped in pcall: a bug
-- here must never be able to stop windows from opening.

local REG = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/group-open.reg"

local function parent_of(pid)
    local st = io.open("/proc/" .. tostring(pid) .. "/stat")
    if not st then return nil end
    local line = st:read("*l")
    st:close()
    return line and tonumber(line:match("^%d+ %b() %S (%d+)")) or nil
end

-- the staging workspace of the registered supervisor this pid descends from, if any
local function stage_for(pid)
    local f = io.open(REG)
    if not f then return nil end
    local sup = {}
    for line in f:lines() do
        local p, ws = line:match("^(%d+) (%d+)")
        if p then sup[tonumber(p)] = tonumber(ws) end
    end
    f:close()
    if next(sup) == nil then return nil end
    for _ = 1, 12 do
        if not pid or pid <= 1 then return nil end
        if sup[pid] then return sup[pid] end
        pid = parent_of(pid)
    end
    return nil
end

local sub -- kept referenced: a collected subscription never fires
sub = hl.on("window.open_early", function(w)
    pcall(function()
        local ws = stage_for(tonumber(w.pid))
        if ws then
            hl.dispatch(hl.dsp.window.move({ workspace = ws, window = w, follow = false }))
        end
    end)
end)
