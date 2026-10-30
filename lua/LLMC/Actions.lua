-- LLM Commander :: executes the (untrusted) action list coming back from the LLM.
-- Every action is validated and wrapped in pcall; bad input just produces a message for the next observation.
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')

-- Build spots reserved this/last minute so two engineers are not sent to the same tile.
Reservations = {}

local function Num(v, def, lo, hi)
    v = tonumber(v)
    if not v then return def end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

local function Say(ctx, msg)
    if table.getn(ctx.results) < 40 then table.insert(ctx.results, string.sub(msg, 1, 150)) end
end

local function Dist(x1, z1, x2, z2)
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end

local function Clamp(x, z)
    local s = ScenarioInfo.size
    if s then
        x = math.max(3, math.min(s[1] - 3, x))
        z = math.max(3, math.min(s[2] - 3, z))
    end
    return x, z
end

local function Vec(x, z)
    x, z = Clamp(x, z)
    return { x, GetSurfaceHeight(x, z), z }
end

local function QueueLen(u)
    local ok, q = pcall(function() return u:GetCommandQueue() end)
    if ok and q then return table.getn(q) end
    return 0
end

local function ParseNear(ctx, near)
    if type(near) == 'table' and tonumber(near[1]) and tonumber(near[2]) then
        return tonumber(near[1]), tonumber(near[2])
    end
    return ctx.baseX, ctx.baseZ
end

---------------------------------------------------------------------------------------------------
-- Engineers
---------------------------------------------------------------------------------------------------
local function Engineers(ctx)
    if ctx.engs then return ctx.engs end
    local out = {}
    for _, u in ipairs(K.Select(ctx.all, K.Units.engineer)) do table.insert(out, { unit = u, acu = false }) end
    if ctx.cfg.UseACUToBuild then
        for _, u in ipairs(K.Select(ctx.all, K.Recipes.acu)) do table.insert(out, { unit = u, acu = true }) end
    end
    ctx.engs = out
    return out
end

-- Engineers sorted best-first for a job at (x, z): close, idle, not the ACU, not already given work this turn.
local function Ranked(ctx, x, z)
    local out = {}
    for _, e in ipairs(Engineers(ctx)) do
        local p = e.unit:GetPosition()
        local score = Dist(p[1], p[3], x, z)
        if not e.unit:IsIdleState() then score = score + 150 + 25 * QueueLen(e.unit) end
        if e.acu then score = score + 300 end
        score = score + 80 * (ctx.load[e.unit] or 0)
        table.insert(out, { unit = e.unit, score = score })
    end
    table.sort(out, function(a, b) return a.score < b.score end)
    return out
end

---------------------------------------------------------------------------------------------------
-- Build-site search
---------------------------------------------------------------------------------------------------
local function Reserved(x, z, r)
    local now = GetGameTimeSeconds()
    for _, e in ipairs(Reservations) do
        if now - e.t < 90 and math.abs(e.x - x) < (e.r + r) and math.abs(e.z - z) < (e.r + r) then return true end
    end
    return false
end

local function Reserve(x, z, r)
    local now = GetGameTimeSeconds()
    local keep = {}
    for _, e in ipairs(Reservations) do
        if now - e.t < 90 then table.insert(keep, e) end
    end
    table.insert(keep, { x = x, z = z, r = r, t = now })
    Reservations = keep
end

local function Skirt(bp)
    local sx, sz = 1, 1
    if bp and bp.Physics then
        sx = bp.Physics.SkirtSizeX or 1
        sz = bp.Physics.SkirtSizeZ or 1
    end
    return sx, sz
end

local function Snap(v, size)
    if math.mod(size, 2) == 1 then return math.floor(v) + 0.5 end
    return math.floor(v + 0.5)
end

-- markers = nil  -> spiral search around (cx,cz);  markers = {{x,z},..} -> nearest free marker within radius
local function FindSpot(ctx, bpid, cx, cz, radius, markers)
    local brain = ctx.brain
    local bp = __blueprints[bpid]
    local sx, sz = Skirt(bp)
    local half = math.max(sx, sz) / 2 + 0.2

    if markers then
        local bestd, bx, bz = 1e9, nil, nil
        for _, m in ipairs(markers) do
            local d = Dist(m[1], m[2], cx, cz)
            if d <= radius and d < bestd and (not Reserved(m[1], m[2], 1))
               and brain:CanBuildStructureAt(bpid, { m[1], GetSurfaceHeight(m[1], m[2]), m[2] }) then
                bestd, bx, bz = d, m[1], m[2]
            end
        end
        if bx then Reserve(bx, bz, 1) return bx, bz end
        return nil
    end

    local isFactory = K.CatSet(bpid).FACTORY
    local step = math.max(sx, sz) + (isFactory and 2 or 1)
    local rmax = math.ceil(radius / step)
    for r = 0, rmax do
        local cand = {}
        if r == 0 then
            table.insert(cand, { 0, 0 })
        else
            for d = -r, r do
                table.insert(cand, { d, -r }) table.insert(cand, { d, r })
            end
            for d = -r + 1, r - 1 do
                table.insert(cand, { -r, d }) table.insert(cand, { r, d })
            end
        end
        for _, c in ipairs(cand) do
            local x, z = Clamp(Snap(cx + c[1] * step, sx), Snap(cz + c[2] * step, sz))
            if (not Reserved(x, z, half))
               and brain:CanBuildStructureAt(bpid, { x, GetSurfaceHeight(x, z), z }) then
                Reserve(x, z, half)
                return x, z
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Action handlers
---------------------------------------------------------------------------------------------------
local Handlers = {}

function Handlers.build(ctx, a)
    local cands, kind
    if a.unit_id then
        kind = string.lower(tostring(a.unit_id))
        if not __blueprints[kind] then return Say(ctx, 'build: unknown unit_id ' .. kind) end
        cands = { kind }
    else
        kind = a.what
        if type(kind) ~= 'string' or not K.Structures[kind] then
            return Say(ctx, 'build: unknown kind ' .. tostring(kind))
        end
        cands = K.Candidates(K.Structures[kind], ctx.faction)
    end
    local n = Num(a.n, 1, 1, 12)
    local tech = Num(a.tech, 4, 1, 4)
    local cx, cz = ParseNear(ctx, a.near)
    local isMarker = (kind == 'mex' or kind == 'hydro')
    local radius = Num(a.radius, isMarker and 70 or 30, 5, 150)
    local markers = nil
    if isMarker then markers = K.Markers(kind == 'mex' and 'Mass' or 'Hydrocarbon') end

    local placed, failed = 0, {}
    for i = 1, n do
        local did = false
        for _, e in ipairs(Ranked(ctx, cx, cz)) do
            local bpid = K.BestBuildable(e.unit, cands, tech)
            if bpid and not failed[bpid] then
                local x, z = FindSpot(ctx, bpid, cx, cz, radius, markers)
                if x then
                    IssueBuildMobile({ e.unit }, Vec(x, z), bpid, {})
                    ctx.load[e.unit] = (ctx.load[e.unit] or 0) + 1
                    placed = placed + 1
                    did = true
                    break
                else
                    failed[bpid] = true
                end
            end
        end
        if not did then break end
    end
    Say(ctx, string.format('build %s x%d: %d queued%s', kind, n, placed,
        placed < n and ' (no builder/tech/free spot for the rest)' or ''))
end

local function Factories(ctx, which)
    local out = {}
    for _, u in ipairs(K.Select(ctx.all, K.Recipes.factory)) do
        local ok = false
        local bpid = u:GetUnitId()
        local s = K.CatSet(bpid)
        if which == nil or which == 'all' then ok = true
        elseif which == 'land' then ok = s.LAND
        elseif which == 'air' then ok = s.AIR
        elseif which == 'naval' then ok = s.NAVAL
        elseif tostring(u:GetEntityId()) == tostring(which) then ok = true end
        if ok and not u:IsUnitState('Upgrading') then table.insert(out, u) end
    end
    table.sort(out, function(p, q) return QueueLen(p) < QueueLen(q) end)
    return out
end

function Handlers.produce(ctx, a)
    local cands, kind
    if a.unit_id then
        kind = string.lower(tostring(a.unit_id))
        if not __blueprints[kind] then return Say(ctx, 'produce: unknown unit_id ' .. kind) end
        cands = { kind }
    else
        kind = a.what
        if type(kind) ~= 'string' or not K.Units[kind] then
            return Say(ctx, 'produce: unknown unit kind ' .. tostring(kind))
        end
        cands = K.Candidates(K.Units[kind], ctx.faction)
    end
    local n = Num(a.n, 1, 1, 30)
    local tech = Num(a.tech, 4, 1, 4)
    local capable = {}
    for _, f in ipairs(Factories(ctx, a.factory)) do
        if QueueLen(f) < 20 then
            local bpid = K.BestBuildable(f, cands, tech)
            if bpid then table.insert(capable, { unit = f, bp = bpid }) end
        end
    end
    local cnt = table.getn(capable)
    if cnt == 0 then return Say(ctx, 'produce ' .. kind .. ': no suitable factory (wrong type, wrong tech, busy or upgrading)') end
    local left, queued = n, 0
    for i, c in ipairs(capable) do
        local share = math.ceil(left / (cnt - i + 1))
        if share > 0 then
            if a.clear then IssueClearCommands({ c.unit }) end
            IssueBuildFactory({ c.unit }, c.bp, share)
            queued = queued + share
            left = left - share
        end
    end
    Say(ctx, string.format('produce %s: %d queued across %d factories', kind, queued, cnt))
end

function Handlers.upgrade(ctx, a)
    local list = {}
    if a.id then
        local u = ctx.units[tostring(a.id)]
        if not u then return Say(ctx, 'upgrade: unknown id ' .. tostring(a.id)) end
        list = { u }
    else
        local recipe = K.Structures[tostring(a.what)]
        if not recipe or not (a.what == 'mex' or a.what == 'land_factory' or a.what == 'air_factory' or a.what == 'naval_factory') then
            return Say(ctx, 'upgrade: what must be mex, land_factory, air_factory or naval_factory')
        end
        list = K.Select(ctx.all, recipe)
        table.sort(list, function(p, q)
            local pp, qp = p:GetPosition(), q:GetPosition()
            return Dist(pp[1], pp[3], ctx.baseX, ctx.baseZ) < Dist(qp[1], qp[3], ctx.baseX, ctx.baseZ)
        end)
    end
    local n = Num(a.n, 1, 1, 12)
    local done = 0
    for _, u in ipairs(list) do
        if done >= n then break end
        local bp = u:GetBlueprint()
        local up = bp.General and bp.General.UpgradesTo
        if up and up ~= '' and not u:IsUnitState('Upgrading') and u:CanBuild(up)
           and (K.CatSet(u:GetUnitId()).MASSEXTRACTION or u:IsIdleState()) then
            IssueUpgrade({ u }, up)
            done = done + 1
        end
    end
    Say(ctx, string.format('upgrade %s: %d started', tostring(a.what or a.id), done))
end

function Handlers.assist(ctx, a)
    local target = ctx.units[tostring(a.target)]
    if not target then return Say(ctx, 'assist: unknown target id ' .. tostring(a.target)) end
    local tp = target:GetPosition()
    local n = Num(a.n, 2, 1, 20)
    local sent = {}
    for _, e in ipairs(Ranked(ctx, tp[1], tp[3])) do
        if table.getn(sent) >= n then break end
        table.insert(sent, e.unit)
    end
    if table.getn(sent) > 0 then IssueGuard(sent, target) end
    Say(ctx, string.format('assist %s: %d engineers sent', tostring(a.target), table.getn(sent)))
end

function Handlers.reclaim(ctx, a)
    local cx, cz = ParseNear(ctx, a.near)
    local radius = Num(a.radius, 40, 5, 80)
    local n = Num(a.n, 2, 1, 10)
    local props = GetReclaimablesInRect(Rect(cx - radius, cz - radius, cx + radius, cz + radius))
    local good = {}
    if props then
        for _, p in ipairs(props) do
            local m = p.MaxMassReclaim or 0
            if m >= 5 and not p.Dead then table.insert(good, { prop = p, m = m }) end
        end
    end
    table.sort(good, function(p, q) return p.m > q.m end)
    local engs = Ranked(ctx, cx, cz)
    local sent = 0
    for i = 1, math.min(n, table.getn(good), table.getn(engs)) do
        IssueReclaim({ engs[i].unit }, good[i].prop)
        ctx.load[engs[i].unit] = (ctx.load[engs[i].unit] or 0) + 1
        sent = sent + 1
    end
    Say(ctx, string.format('reclaim: %d engineers sent (%d wrecks found)', sent, table.getn(good)))
end

function Handlers.enhance(ctx, a)
    local acu = ctx.acu
    if not acu then return Say(ctx, 'enhance: no ACU') end
    local name = tostring(a.name)
    local enh = acu:GetBlueprint().Enhancements
    local e = enh and enh[name]
    if type(e) ~= 'table' then return Say(ctx, 'enhance: unknown enhancement ' .. name) end
    if acu:HasEnhancement(name) then return Say(ctx, 'enhance: already have ' .. name) end
    if e.Prerequisite and not acu:HasEnhancement(e.Prerequisite) then
        return Say(ctx, 'enhance: ' .. name .. ' needs ' .. e.Prerequisite .. ' first')
    end
    IssueScript({ acu }, { TaskName = 'EnhanceTask', Enhancement = name })
    Say(ctx, 'enhance: started ' .. name)
end

function Handlers.rally(ctx, a)
    local x, z = tonumber(a.x), tonumber(a.z)
    if not x or not z then return Say(ctx, 'rally: need x and z') end
    local facs = Factories(ctx, a.factory)
    if table.getn(facs) > 0 then IssueFactoryRallyPoint(facs, Vec(x, z)) end
    Say(ctx, string.format('rally: set for %d factories', table.getn(facs)))
end

-- attack / move / patrol / retreat / stop / scout all share this
local function SquadOrder(ctx, a, mode)
    local name = a.squad
    if mode == 'scout' and not name then name = 'scouts' end
    local recipe = name and K.Squads[tostring(name)]
    if not recipe then return Say(ctx, mode .. ': unknown squad ' .. tostring(name)) end
    local units = K.Select(ctx.all, recipe)
    if table.getn(units) == 0 then return Say(ctx, mode .. ' ' .. name .. ': no such units') end

    local points = {}
    if mode == 'retreat' then
        table.insert(points, { ctx.baseX, ctx.baseZ })
    elseif mode ~= 'stop' then
        if type(a.points) == 'table' then
            for i = 1, math.min(8, table.getn(a.points)) do
                local p = a.points[i]
                if type(p) == 'table' and tonumber(p[1]) and tonumber(p[2]) then
                    table.insert(points, { tonumber(p[1]), tonumber(p[2]) })
                end
            end
        end
        if table.getn(points) == 0 and tonumber(a.x) and tonumber(a.z) then
            table.insert(points, { tonumber(a.x), tonumber(a.z) })
        end
        if table.getn(points) == 0 then return Say(ctx, mode .. ': need x,z or points') end
    end

    local frac = Num(a.fraction, 1, 0.05, 1)
    if frac < 1 and points[1] then
        table.sort(units, function(p, q)
            local pp, qp = p:GetPosition(), q:GetPosition()
            return Dist(pp[1], pp[3], points[1][1], points[1][2]) < Dist(qp[1], qp[3], points[1][1], points[1][2])
        end)
        local cut = {}
        for i = 1, math.max(1, math.floor(table.getn(units) * frac)) do table.insert(cut, units[i]) end
        units = cut
    end

    if not a.queue then IssueClearCommands(units) end
    if mode == 'stop' then
        -- nothing more to do
    elseif mode == 'patrol' then
        for _, p in ipairs(points) do IssuePatrol(units, Vec(p[1], p[2])) end
    elseif mode == 'attack' then
        for _, p in ipairs(points) do IssueAggressiveMove(units, Vec(p[1], p[2])) end
    else
        for _, p in ipairs(points) do IssueMove(units, Vec(p[1], p[2])) end
    end
    Say(ctx, string.format('%s %s: %d units', mode, name, table.getn(units)))
end

function Handlers.attack(ctx, a)  SquadOrder(ctx, a, 'attack') end
function Handlers.move(ctx, a)    SquadOrder(ctx, a, 'move') end
function Handlers.patrol(ctx, a)  SquadOrder(ctx, a, 'patrol') end
function Handlers.retreat(ctx, a) SquadOrder(ctx, a, 'retreat') end
function Handlers.stop(ctx, a)    SquadOrder(ctx, a, 'stop') end
function Handlers.scout(ctx, a)   SquadOrder(ctx, a, 'scout') end

---------------------------------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------------------------------
function Execute(brain, actions, cfg)
    local bx, bz = brain:GetArmyStartPos()
    local ctx = {
        brain = brain, cfg = cfg, results = {}, load = {},
        faction = brain:GetFactionIndex(), baseX = bx, baseZ = bz,
        all = brain:GetListOfUnits(categories.ALLUNITS, false, true),
        units = {},
    }
    for _, u in ipairs(ctx.all) do
        if not u.Dead then
            ctx.units[tostring(u:GetEntityId())] = u
            if K.CatSet(u:GetUnitId()).COMMAND then ctx.acu = u end
        end
    end

    local max = cfg.MaxActionsPerTurn or 24
    local count = 0
    for _, a in ipairs(actions) do
        count = count + 1
        if count > max then Say(ctx, 'too many actions; extras ignored') break end
        if type(a) ~= 'table' or type(a.a) ~= 'string' then
            Say(ctx, 'action ' .. count .. ': malformed')
        else
            local h = Handlers[a.a]
            if not h then
                Say(ctx, 'unknown action "' .. a.a .. '"')
            else
                local ok, err = pcall(h, ctx, a)
                if not ok then Say(ctx, a.a .. ' failed: ' .. tostring(err)) end
            end
        end
    end
    return ctx.results, count
end
