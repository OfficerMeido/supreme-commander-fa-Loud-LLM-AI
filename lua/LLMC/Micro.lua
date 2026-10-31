-- LLM Commander :: MICRO mode.
-- The built-in (LOUD) AI keeps playing the whole game: economy, tech, base, production, its own attack plans.
-- The LLM only micro-manages COMBAT UNITS: it can take a selection of units away from the AI for a short time,
-- give them tactical orders (retreat damaged units, concentrate, focus fire, raid, scout) and the units are handed
-- back to the AI automatically after Config.MicroHoldSeconds without a new order (or on an explicit "release").
-- Engineers, structures and the ACU are never touched.
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')
local StateMod = import('/mods/LLMCommander/lua/LLMC/State.lua')

local Held = {}            -- entityId -> { unit, t = game time of the last LLM order }
local MicroPlatoon = nil

local function R(v) return math.floor(v + 0.5) end
local function R1(v) return math.floor(v * 10 + 0.5) / 10 end
local function Dist(x1, z1, x2, z2)
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end
local function Num(v, def, lo, hi)
    v = tonumber(v)
    if not v then return def end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end
local function Vec(x, z)
    local s = ScenarioInfo.size
    if s then
        x = math.max(3, math.min(s[1] - 3, x))
        z = math.max(3, math.min(s[2] - 3, z))
    end
    return { x, GetSurfaceHeight(x, z), z }
end
local function Say(ctx, msg)
    if table.getn(ctx.results) < 30 then table.insert(ctx.results, string.sub(msg, 1, 150)) end
end
local function HpOf(u)
    local m = u:GetMaxHealth()
    if m < 1 then return 1 end
    return u:GetHealth() / m
end

---------------------------------------------------------------------------------------------------
-- Taking units from / giving units back to the built-in AI
---------------------------------------------------------------------------------------------------
local function EnsurePlatoon(brain)
    if MicroPlatoon then
        local ok, ex = pcall(function() return brain:PlatoonExists(MicroPlatoon) end)
        if ok and ex then return MicroPlatoon end
    end
    local ok, p = pcall(function() return brain:MakePlatoon('LLMMicro', '') end)
    if ok then MicroPlatoon = p else MicroPlatoon = nil end
    return MicroPlatoon
end

-- Move units into a platoon with no AI plan so LOUD's platoon logic stops re-tasking them.
local function Take(brain, units, now)
    local fresh = {}
    for _, u in ipairs(units) do
        local id = tostring(u:GetEntityId())
        if not Held[id] then table.insert(fresh, u) end
        Held[id] = { unit = u, t = now }
    end
    if table.getn(fresh) > 0 then
        local p = EnsurePlatoon(brain)
        if p then
            local ok = pcall(function() brain:AssignUnitsToPlatoon(p, fresh, 'Attack', 'NoFormation') end)
            if not ok then LOG('LLMC|I|WARN could not move units into the micro platoon; the AI may override orders') end
        end
    end
end

-- Hand units back to the AI's army pool.
local function Release(brain, units)
    if table.getn(units) == 0 then return end
    IssueClearCommands(units)
    pcall(function()
        local pool = brain:GetPlatoonUniquelyNamed('ArmyPool')
        brain:AssignUnitsToPlatoon(pool, units, 'Unassigned', 'NoFormation')
    end)
    for _, u in ipairs(units) do Held[tostring(u:GetEntityId())] = nil end
end

-- Called every second by the controller: expire old holds, forget dead units.
function Maintain(brain, cfg, now)
    local expired = {}
    for id, h in pairs(Held) do
        if h.unit.Dead then
            Held[id] = nil
        elseif now - h.t > (cfg.MicroHoldSeconds or 40) then
            table.insert(expired, h.unit)
        end
    end
    if table.getn(expired) > 0 then Release(brain, expired) end
end

function ReleaseAll(brain)
    local all = {}
    for _, h in pairs(Held) do if not h.unit.Dead then table.insert(all, h.unit) end end
    Release(brain, all)
end

local function HeldCount()
    local n = 0
    for _, h in pairs(Held) do if not h.unit.Dead then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------------------------------
-- Observation
---------------------------------------------------------------------------------------------------
function BuildState(brain, cfg, seq, sid, now, lastResults)
    local idx = brain:GetArmyIndex()
    local faction = brain:GetFactionIndex()
    local bx, bz = brain:GetArmyStartPos()
    local st = { mode = 'micro', seq = seq, sid = sid, t = R(now), faction = K.FactionNames[faction], base = { R(bx), R(bz) } }
    if ScenarioInfo.size then st.map = { w = ScenarioInfo.size[1], h = ScenarioInfo.size[2] } end
    local mr, er = 0, 0
    pcall(function() mr = brain:GetEconomyStoredRatio('MASS') er = brain:GetEconomyStoredRatio('ENERGY') end)
    st.eco = { mass = R1(mr), energy = R1(er) }

    -- own combat units -> cells -> groups
    local cells = {}
    local structs = 0
    local acu = nil
    for _, u in ipairs(brain:GetListOfUnits(categories.ALLUNITS, false, true)) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            local s = K.CatSet(bpid)
            if s.COMMAND then acu = u
            elseif s.STRUCTURE then structs = structs + 1
            elseif s.MOBILE and not s.ENGINEER then
                local role = K.MobileRole(bpid)
                if role ~= 'other' then
                    local p = u:GetPosition()
                    local key = math.floor(p[1] / 50) .. ',' .. math.floor(p[3] / 50)
                    local c = cells[key]
                    if not c then c = { x = 0, z = 0, n = 0, hp = 0, idle = 0, held = 0, roles = {} } cells[key] = c end
                    c.x = c.x + p[1] c.z = c.z + p[3] c.n = c.n + 1
                    c.hp = c.hp + HpOf(u)
                    if u:IsIdleState() then c.idle = c.idle + 1 end
                    if Held[tostring(u:GetEntityId())] then c.held = c.held + 1 end
                    c.roles[role] = (c.roles[role] or 0) + 1
                end
            end
        end
    end
    local cellList = {}
    for _, c in pairs(cells) do table.insert(cellList, c) end
    table.sort(cellList, function(a, b) return a.n > b.n end)
    local groups = {}
    for _, c in ipairs(cellList) do
        local cx, cz = c.x / c.n, c.z / c.n
        local into = nil
        for _, g in ipairs(groups) do
            if Dist(g.x / g.n, g.z / g.n, cx, cz) < 70 then into = g break end
        end
        if not into then
            into = { x = 0, z = 0, n = 0, hp = 0, idle = 0, held = 0, roles = {} }
            table.insert(groups, into)
        end
        into.x = into.x + c.x into.z = into.z + c.z into.n = into.n + c.n
        into.hp = into.hp + c.hp into.idle = into.idle + c.idle into.held = into.held + c.held
        for role, k in pairs(c.roles) do into.roles[role] = (into.roles[role] or 0) + k end
    end

    -- enemies
    local diag = 1500
    if ScenarioInfo.size then diag = math.max(ScenarioInfo.size[1], ScenarioInfo.size[2]) * 1.5 end
    local e = StateMod.ScanEnemies(brain, idx, bx, bz, diag)

    local out = {}
    for gi = 1, math.min(10, table.getn(groups)) do
        local g = groups[gi]
        local gx, gz = g.x / g.n, g.z / g.n
        local ne = nil
        for _, cl in ipairs(e.clusters) do
            local d = Dist(gx, gz, cl.pos[1], cl.pos[2])
            if (not ne) or d < ne.dist then
                ne = { pos = cl.pos, dist = R(d), land = cl.land, air = cl.air, naval = cl.naval,
                       structures = cl.structures, defenses = cl.defenses }
            end
        end
        table.insert(out, { pos = { R(gx), R(gz) }, n = g.n, roles = g.roles, hp = R1(g.hp / g.n),
            idle = g.idle, held_by_llm = g.held, nearest_enemy = ne, engaged = (ne ~= nil and ne.dist < 70) })
    end
    st.groups = out
    st.units_held_by_llm = HeldCount()
    st.enemy = e.clusters
    st.enemy_near_base = e.near_base
    st.under_attack = (e.near_base.land + e.near_base.air + e.near_base.naval) > 0
    st.radar_blips = e.radar_blips
    st.own_structures = structs

    if acu then
        st.acu = { pos = { R(acu:GetPosition()[1]), R(acu:GetPosition()[3]) }, hp = R1(HpOf(acu)) }
    end
    if cfg.RevealEnemyStarts then
        local starts = {}
        for i, b in ipairs(ArmyBrains) do
            if i ~= idx and IsEnemy(idx, i) then
                local ok, x, z = pcall(function() return b:GetArmyStartPos() end)
                if ok and x then table.insert(starts, { army = i, pos = { R(x), R(z) } }) end
            end
        end
        st.enemy_starts = starts
    end
    st.last_results = lastResults
    return st
end

---------------------------------------------------------------------------------------------------
-- Orders
---------------------------------------------------------------------------------------------------
-- Select own combat units: role + optional circle (near/radius) + optional health filter + optional cap n.
local function Select(ctx, a)
    local recipe = K.Squads[tostring(a.role or 'all')]
    if not recipe then return nil, 'unknown role ' .. tostring(a.role) end
    local units = K.Select(ctx.all, recipe)
    local nx, nz = nil, nil
    if type(a.near) == 'table' and tonumber(a.near[1]) and tonumber(a.near[2]) then
        nx, nz = tonumber(a.near[1]), tonumber(a.near[2])
    end
    local radius = Num(a.radius, 55, 5, 300)
    local lo, hi = tonumber(a.hp_below), tonumber(a.hp_above)
    local out = {}
    for _, u in ipairs(units) do
        local ok = true
        if nx then
            local p = u:GetPosition()
            if Dist(p[1], p[3], nx, nz) > radius then ok = false end
        end
        if ok and (lo or hi) then
            local h = HpOf(u)
            if lo and h >= lo then ok = false end
            if hi and h <= hi then ok = false end
        end
        if ok then table.insert(out, u) end
    end
    local cap = tonumber(a.n)
    if cap and table.getn(out) > cap then
        if nx then
            table.sort(out, function(p, q)
                local pp, qp = p:GetPosition(), q:GetPosition()
                return Dist(pp[1], pp[3], nx, nz) < Dist(qp[1], qp[3], nx, nz)
            end)
        end
        local cut = {}
        for i = 1, math.max(1, math.floor(cap)) do table.insert(cut, out[i]) end
        out = cut
    end
    return out
end

local function Points(ctx, a, retreat)
    local pts = {}
    if retreat and not (tonumber(a.x) and tonumber(a.z)) then
        table.insert(pts, { ctx.baseX, ctx.baseZ })
        return pts
    end
    if type(a.points) == 'table' then
        for i = 1, math.min(8, table.getn(a.points)) do
            local p = a.points[i]
            if type(p) == 'table' and tonumber(p[1]) and tonumber(p[2]) then table.insert(pts, { tonumber(p[1]), tonumber(p[2]) }) end
        end
    end
    if table.getn(pts) == 0 and tonumber(a.x) and tonumber(a.z) then table.insert(pts, { tonumber(a.x), tonumber(a.z) }) end
    return pts
end

local Handlers = {}

-- {"a":"order","cmd":"attack|move|patrol|retreat|stop", role, near, radius, hp_below, hp_above, n, x, z, points, queue}
function Handlers.order(ctx, a)
    local cmd = tostring(a.cmd)
    if not (cmd == 'attack' or cmd == 'move' or cmd == 'patrol' or cmd == 'retreat' or cmd == 'stop') then
        return Say(ctx, 'order: unknown cmd ' .. cmd)
    end
    local units, err = Select(ctx, a)
    if not units then return Say(ctx, 'order: ' .. err) end
    if table.getn(units) == 0 then return Say(ctx, 'order ' .. cmd .. ': no units matched the selection') end
    local pts = {}
    if cmd ~= 'stop' then
        pts = Points(ctx, a, cmd == 'retreat')
        if table.getn(pts) == 0 then return Say(ctx, 'order ' .. cmd .. ': need x,z or points') end
    end
    Take(ctx.brain, units, ctx.now)
    if not a.queue then IssueClearCommands(units) end
    for _, p in ipairs(pts) do
        if cmd == 'attack' then IssueAggressiveMove(units, Vec(p[1], p[2]))
        elseif cmd == 'patrol' then IssuePatrol(units, Vec(p[1], p[2]))
        else IssueMove(units, Vec(p[1], p[2])) end
    end
    Say(ctx, string.format('order %s: %d units', cmd, table.getn(units)))
end

-- {"a":"scout","x":..,"z":..} / points : own scouts move (and are returned to the AI later)
function Handlers.scout(ctx, a)
    a.role = 'scouts'
    a.cmd = 'move'
    Handlers.order(ctx, a)
end

-- {"a":"focus","tx":..,"tz":..,"prefer":"acu|defense|structure|mobile|air|land","role", near, radius, hp_below, n}
-- Selected units attack ONE visible enemy near (tx,tz).
function Handlers.focus(ctx, a)
    local tx, tz = tonumber(a.tx), tonumber(a.tz)
    if not tx or not tz then return Say(ctx, 'focus: need tx and tz') end
    local units, err = Select(ctx, a)
    if not units then return Say(ctx, 'focus: ' .. err) end
    if table.getn(units) == 0 then return Say(ctx, 'focus: no units matched the selection') end
    local prefer = tostring(a.prefer or 'any')
    local list = ctx.brain:GetUnitsAroundPoint(categories.ALLUNITS, { tx, 0, tz }, Num(a.target_radius, 25, 5, 80), 'Enemy')
    local best, bestScore = nil, -1e9
    for _, e in ipairs(list) do
        if not e.Dead then
            local bpid = e:GetUnitId()
            local s = K.CatSet(bpid)
            local blip = e:GetBlip(ctx.idx)
            local visible = false
            if blip then
                visible = blip:IsSeenNow(ctx.idx) or blip:IsOnOmni(ctx.idx) or (s.STRUCTURE and blip:IsSeenEver(ctx.idx))
            end
            if visible then
                local p = e:GetPosition()
                local score = -Dist(p[1], p[3], tx, tz)
                local kind = K.StructureKind(bpid)
                if prefer == 'acu' and s.COMMAND then score = score + 1000
                elseif prefer == 'defense' and (kind == 'pd' or kind == 'aa' or kind == 'shield' or kind == 'arty' or kind == 'torpedo') then score = score + 500
                elseif prefer == 'structure' and s.STRUCTURE then score = score + 500
                elseif prefer == 'mobile' and not s.STRUCTURE then score = score + 500
                elseif prefer == 'air' and s.AIR then score = score + 500
                elseif prefer == 'land' and s.LAND and not s.STRUCTURE then score = score + 500 end
                if score > bestScore then best, bestScore = e, score end
            end
        end
    end
    if not best then return Say(ctx, 'focus: no visible enemy near that point') end
    Take(ctx.brain, units, ctx.now)
    IssueClearCommands(units)
    IssueAttack(units, best)
    Say(ctx, string.format('focus: %d units attacking %s', table.getn(units), best:GetUnitId()))
end

-- {"a":"release", role, near, radius, ...}: give the selected units back to the built-in AI right now
function Handlers.release(ctx, a)
    local units, err = Select(ctx, a)
    if not units then return Say(ctx, 'release: ' .. err) end
    local mine = {}
    for _, u in ipairs(units) do
        if Held[tostring(u:GetEntityId())] then table.insert(mine, u) end
    end
    Release(ctx.brain, mine)
    Say(ctx, string.format('release: %d units handed back to the AI', table.getn(mine)))
end

function Execute(brain, actions, cfg)
    local bx, bz = brain:GetArmyStartPos()
    local ctx = { brain = brain, cfg = cfg, results = {}, now = GetGameTimeSeconds(), idx = brain:GetArmyIndex(),
                  baseX = bx, baseZ = bz, all = brain:GetListOfUnits(categories.ALLUNITS, false, true) }
    local count = 0
    for _, a in ipairs(actions) do
        count = count + 1
        if count > (cfg.MaxActionsPerTurn or 24) then Say(ctx, 'too many actions; extras ignored') break end
        if type(a) ~= 'table' or type(a.a) ~= 'string' then
            Say(ctx, 'action ' .. count .. ': malformed')
        else
            local h = Handlers[a.a]
            if not h then
                Say(ctx, 'unknown action "' .. a.a .. '" (micro mode: order, focus, scout, release)')
            else
                local ok, err = pcall(h, ctx, a)
                if not ok then Say(ctx, a.a .. ' failed: ' .. tostring(err)) end
            end
        end
    end
    return ctx.results, count
end
