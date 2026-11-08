-- LLM Commander :: MICRO / ARMY modes.
-- micro: the LOUD AI plays everything and keeps ALL its units; the LLM controls ONLY the Quantum Gateway ACUs (SACUs).
-- army : additionally the LLM owns every attack unit for good. The unit micro below (order/focus/scout/release/rally) is army-mode only.
-- Unit control (army mode): the LLM claims every combat unit for good and gives tactical orders. Engineers, structures and
-- the original ACU are never touched.
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')
local StateMod = import('/mods/LLMCommander/lua/LLMC/State.lua')
local Gateway = import('/mods/LLMCommander/lua/LLMC/Gateway.lua')

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
local function Take(brain, units, now, perm)
    local fresh = {}
    for _, u in ipairs(units) do
        local id = tostring(u:GetEntityId())
        if not Held[id] then table.insert(fresh, u) end
        Held[id] = { unit = u, t = now, perm = perm or (Held[id] and Held[id].perm) }
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

-- Quantum Gateway ACUs (SACUs) are claimed permanently: the LLM owns them from the moment they appear.
local LastClaim = -100
local function ClaimSacus(brain, now)
    if now - LastClaim < 3 then return end
    LastClaim = now
    local fresh = {}
    for _, u in ipairs(K.Select(brain:GetListOfUnits(categories.ALLUNITS, false, true), K.Recipes.sacu)) do
        if not Held[tostring(u:GetEntityId())] then table.insert(fresh, u) end
    end
    if table.getn(fresh) > 0 then
        Take(brain, fresh, now, true)
        LOG('LLMC|I|INFO claimed ' .. table.getn(fresh) .. ' gateway ACU(s) for the LLM')
    end
end

-- ARMY MODE: the LLM owns ALL attack units permanently. New ones are claimed as soon as they appear.
local LastClaimAll = -100
local function ClaimAllCombat(brain, now)
    if now - LastClaimAll < 3 then return end
    LastClaimAll = now
    local fresh = {}
    for _, u in ipairs(K.Select(brain:GetListOfUnits(categories.ALLUNITS, false, true), K.Squads.all)) do
        if not Held[tostring(u:GetEntityId())] and K.MobileRole(u:GetUnitId()) ~= 'other' then table.insert(fresh, u) end
    end
    if table.getn(fresh) > 0 then Take(brain, fresh, now, true) end
end

-- Staging point: a spot in front of the base, towards the nearest enemy start. Idle attack units gather here.
Staging = false          -- false (not nil): reading a never-assigned global is an error in the FA engine
local function StagingPoint(brain, cfg)
    if Staging then return Staging end
    local bx, bz = brain:GetArmyStartPos()
    local idx = brain:GetArmyIndex()
    local bestX, bestZ, bd = nil, nil, 1e9
    for i, b in ipairs(ArmyBrains) do
        if i ~= idx and IsEnemy(idx, i) then
            local ok, x, z = pcall(function() return b:GetArmyStartPos() end)
            if ok and x then
                local d = Dist(x, z, bx, bz)
                if d < bd then bd, bestX, bestZ = d, x, z end
            end
        end
    end
    local dist = cfg.StagingDistance or 70
    if bestX and bd > 1 then
        Staging = { bx + (bestX - bx) / bd * dist, bz + (bestZ - bz) / bd * dist }
    else
        Staging = { bx + 30, bz + 30 }
    end
    return Staging
end

-- Units the LLM has not used for IdleFallbackSeconds go to the staging point (instead of standing at the factory).
local function IdleFallback(brain, cfg, now)
    local st = StagingPoint(brain, cfg)
    local list = {}
    for _, h in pairs(Held) do
        local u = h.unit
        if (not u.Dead) and h.perm and u:IsIdleState() and now - h.t > (cfg.IdleFallbackSeconds or 25)
           and K.MobileRole(u:GetUnitId()) ~= 'scouts' and K.CatSet(u:GetUnitId()).MOBILE and not K.CatSet(u:GetUnitId()).SUBCOMMANDER then
            local p = u:GetPosition()
            if Dist(p[1], p[3], st[1], st[2]) > 30 then table.insert(list, u) end
        end
    end
    if table.getn(list) > 0 then IssueAggressiveMove(list, Vec(st[1], st[2])) end
end

-- live, finished gateway ACUs owned by the LLM
local function SacuList()
    local out = {}
    for _, h in pairs(Held) do
        if h.perm and not h.unit.Dead and h.unit:GetFractionComplete() >= 1 then table.insert(out, h.unit) end
    end
    return out
end

-- Called every second by the controller: expire old holds, forget dead units.
function Maintain(brain, cfg, now)
    ClaimSacus(brain, now)
    if cfg.CleanStaleAssist ~= false then K.ClearStale(SacuList(), now, cfg.StaleAssistSeconds or 6) end     -- gateway ACUs left guarding something that is done
    if cfg.Takeover == 'army' then
        ClaimAllCombat(brain, now)
        IdleFallback(brain, cfg, now)
    end
    local expired = {}
    for id, h in pairs(Held) do
        if h.unit.Dead then
            Held[id] = nil
        elseif (not h.perm) and now - h.t > (cfg.MicroHoldSeconds or 40) then
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
    local st = { mode = cfg.Takeover, seq = seq, sid = sid, t = R(now), faction = K.FactionNames[faction], base = { R(bx), R(bz) } }
    if ScenarioInfo.size then st.map = { w = ScenarioInfo.size[1], h = ScenarioInfo.size[2] } end
    local mr, er = 0, 0
    pcall(function() mr = brain:GetEconomyStoredRatio('MASS') er = brain:GetEconomyStoredRatio('ENERGY') end)
    st.eco = { mass = R1(mr), energy = R1(er) }

    -- own combat units -> cells -> groups
    local cells = {}
    local structs = 0
    local acu = nil
    local sacuList, gateways, defs, exps = {}, 0, {}, 0
    for _, u in ipairs(brain:GetListOfUnits(categories.ALLUNITS, false, true)) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            local s = K.CatSet(bpid)
            if s.COMMAND then acu = u
            elseif s.SUBCOMMANDER and s.MOBILE then
                table.insert(sacuList, u)
            elseif s.STRUCTURE then
                structs = structs + 1
                if s.GATE then gateways = gateways + 1 end
                local k = K.StructureKind(bpid)
                if k == 'shield' or k == 'aa' or k == 'pd' or k == 'arty' then
                    local p = u:GetPosition()
                    if Dist(p[1], p[3], bx, bz) <= (cfg.DefenseRadius or 90) then defs[k] = (defs[k] or 0) + 1 end
                end
            elseif s.MOBILE and not s.ENGINEER then
                if s.EXPERIMENTAL then exps = exps + 1 end
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
    if cfg.Takeover == 'army' then
        st.groups = out
        st.units_held_by_llm = HeldCount()
        local idleAll = 0
        for _, g in ipairs(groups) do idleAll = idleAll + g.idle end
        st.idle_attack_units = idleAll
        local sp = StagingPoint(brain, cfg)
        st.rally = { R(sp[1]), R(sp[2]) }
    end
    st.enemy = e.clusters
    st.enemy_near_base = e.near_base
    st.under_attack = (e.near_base.land + e.near_base.air + e.near_base.naval) > 0
    st.radar_blips = e.radar_blips
    st.own_structures = structs

    -- Quantum Gateway ACUs (owned by the LLM) and base-defence status
    local sacuIdle, sacuIds = 0, {}
    for _, u in ipairs(sacuList) do
        if K.EffectivelyIdle(u) then sacuIdle = sacuIdle + 1 end
        if table.getn(sacuIds) < 8 then table.insert(sacuIds, tostring(u:GetEntityId())) end
    end
    st.gateway = { built = gateways > 0, sacus = table.getn(sacuList), idle = sacuIdle, ids = sacuIds }
    local shields, aas, pds, artys = defs.shield or 0, defs.aa or 0, defs.pd or 0, defs.arty or 0
    -- base-defence building is only a concern when there are gateway ACUs to build it (micro and army mode)
    if table.getn(sacuList) > 0 then
        st.defense_status = { shields = shields, aa = aas, pd = pds, artillery = artys, radius = cfg.DefenseRadius or 90,
            lacking = (shields == 0 or aas < 6 or (pds + artys) < 8) }
        st.defense_clusters = Gateway.Clusters
    end
    st.experimentals = exps
    st.mass_farms = Gateway.Farms
    st.auto_recent = AutoRecent
    st.t4_under_construction = T4Building

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
    if cfg.Takeover == 'sacu' then
        -- sacu mode: the LLM only sees what matters for the gateway ACUs (no unit groups)
        st.groups = nil
        st.units_held_by_llm = nil
        st.radar_blips = nil
    end
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
    if ctx.cfg.Takeover == 'army' then
        return Say(ctx, 'release: not available in army mode - you own all attack units; give them orders instead')
    end
    local units, err = Select(ctx, a)
    if not units then return Say(ctx, 'release: ' .. err) end
    local mine = {}
    for _, u in ipairs(units) do
        if Held[tostring(u:GetEntityId())] then table.insert(mine, u) end
    end
    Release(ctx.brain, mine)
    Say(ctx, string.format('release: %d units handed back to the AI', table.getn(mine)))
end

-- {"a":"rally","x":X,"z":Z}  (army mode) change the staging point where idle attack units gather
function Handlers.rally(ctx, a)
    if ctx.cfg.Takeover ~= 'army' then return Say(ctx, 'rally: only in army mode') end
    local x, z = tonumber(a.x), tonumber(a.z)
    if not x or not z then return Say(ctx, 'rally: need x and z') end
    Staging = { x, z }
    Say(ctx, string.format('rally: staging point set to %d,%d', x, z))
end

-- {"a":"assist_t4"}: idle gateway ACUs assist the nearest Tech 4 unit/building under construction ("force":true = all of them)
function Handlers.assist_t4(ctx, a)
    local list = {}
    for _, u in ipairs(ctx.sacus) do
        if a.force or K.EffectivelyIdle(u) then table.insert(list, u) end
    end
    if table.getn(list) == 0 then return Say(ctx, 'assist_t4: no idle gateway ACUs') end
    local what = AssistT4(ctx.brain, list)
    if what then Say(ctx, string.format('assist_t4: %d gateway ACUs help build %s', table.getn(list), what))
    else Say(ctx, 'assist_t4: no Tech 4 unit or building is under construction') end
end

-- Gateway ACU actions
function Handlers.defense_cluster(ctx, a) Gateway.DefenseCluster(ctx, a) end
function Handlers.mass_farm(ctx, a) Gateway.MassFarm(ctx, a) end
function Handlers.mex_defense(ctx, a) Gateway.MexDefense(ctx, a) end
function Handlers.experimental(ctx, a) Gateway.Experimental(ctx, a) end

-- {"a":"sacu","cmd":"move|retreat|stop","x":..,"z":..}: move the gateway ACUs (they are owned by the LLM permanently)
function Handlers.sacu(ctx, a)
    local cmd = tostring(a.cmd)
    if table.getn(ctx.sacus) == 0 then return Say(ctx, 'sacu: no gateway ACUs') end
    if cmd == 'stop' then
        IssueClearCommands(ctx.sacus)
    elseif cmd == 'retreat' then
        IssueClearCommands(ctx.sacus)
        IssueMove(ctx.sacus, Vec(ctx.baseX, ctx.baseZ))
    elseif cmd == 'move' and tonumber(a.x) and tonumber(a.z) then
        IssueClearCommands(ctx.sacus)
        IssueMove(ctx.sacus, Vec(tonumber(a.x), tonumber(a.z)))
    else
        return Say(ctx, 'sacu: cmd must be move (with x,z), retreat or stop')
    end
    Say(ctx, string.format('sacu %s: %d gateway ACUs', cmd, table.getn(ctx.sacus)))
end

-- micro mode controls ONLY the gateway ACUs: orders that command LOUD's combat units are refused
local UnitOnly = { order = true, focus = true, scout = true, release = true, rally = true }

function Execute(brain, actions, cfg)
    local bx, bz = brain:GetArmyStartPos()
    local ctx = { brain = brain, cfg = cfg, results = {}, now = GetGameTimeSeconds(), idx = brain:GetArmyIndex(),
                  baseX = bx, baseZ = bz, all = brain:GetListOfUnits(categories.ALLUNITS, false, true),
                  faction = brain:GetFactionIndex(), sacus = SacuList() }
    local count = 0
    for _, a in ipairs(actions) do
        count = count + 1
        if count > (cfg.MaxActionsPerTurn or 24) then Say(ctx, 'too many actions; extras ignored') break end
        if type(a) ~= 'table' or type(a.a) ~= 'string' then
            Say(ctx, 'action ' .. count .. ': malformed')
        else
            local h = Handlers[a.a]
            if h and (cfg.Takeover == 'micro' or cfg.Takeover == 'sacu') and UnitOnly[a.a] then
                Say(ctx, a.a .. ' refused: in ' .. tostring(cfg.Takeover) .. ' mode you control ONLY the gateway ACUs (sacu, defense_cluster, mass_farm, experimental, assist_t4); the AI commands all other units')
            elseif not h then
                Say(ctx, 'unknown action "' .. a.a .. '"')
            else
                local ok, err = pcall(h, ctx, a)
                if not ok then Say(ctx, a.a .. ' failed: ' .. tostring(err)) end
            end
        end
    end
    return ctx.results, count
end


---------------------------------------------------------------------------------------------------
-- GATEWAY AUTOPILOT. Same rules the LLM is told to follow, applied automatically when a gateway ACU is idle
-- (Config.GatewayAuto = false turns it off):
--   1. base defences lacking      -> defense_cluster (T3 shield, 10 SAMs, T2 artillery + T2 PD)
--   2. mass is not being used     -> experimental (Tech 4 unit)
--   3. otherwise, mass is short   -> mass_farm (T3 power plant ringed by T2 fabricators)
---------------------------------------------------------------------------------------------------
AutoRecent = {}
local AutoCool, DefBlock, FarmBlock, MexDefBlock = 0, 0, 0, 0

local function ANote(now, msg)
    table.insert(AutoRecent, 't' .. math.floor(now) .. ' ' .. msg)
    while table.getn(AutoRecent) > 6 do table.remove(AutoRecent, 1) end
end

T4Building = false     -- true while any of our Tech 4 (experimental) units/buildings is under construction

-- Gateway ACUs in `sacus` assist the nearest Tech 4 unit or building under construction (ours or LOUD's).
-- Structures are guarded directly; for a unit being built in a factory/by an engineer the builder is guarded.
-- Returns the blueprint id helped, or nil.
function AssistT4(brain, sacus)
    if table.getn(sacus) == 0 then return nil end
    local all = brain:GetListOfUnits(categories.ALLUNITS, false)
    local focusOf = {}
    for _, u in ipairs(all) do
        if not u.Dead then
            local s = K.CatSet(u:GetUnitId())
            if s.ENGINEER or s.FACTORY then
                local ok, f = pcall(function() return u:GetFocusUnit() end)
                if ok and f and not f.Dead then focusOf[tostring(f:GetEntityId())] = u end
            end
        end
    end
    local cx, cz = 0, 0
    for _, u in ipairs(sacus) do
        local p = u:GetPosition()
        cx = cx + p[1] cz = cz + p[3]
    end
    cx = cx / table.getn(sacus) cz = cz / table.getn(sacus)

    local best, bestD, bestId = nil, 1e9, nil
    for _, u in ipairs(all) do
        if not u.Dead and u:GetFractionComplete() < 1 then
            local bpid = u:GetUnitId()
            local s = K.CatSet(bpid)
            if s.EXPERIMENTAL then
                local target = u
                if not s.STRUCTURE then target = focusOf[tostring(u:GetEntityId())] or u end
                local p = target:GetPosition()
                local d = Dist(p[1], p[3], cx, cz)
                local mine = false
                for _, sc in ipairs(sacus) do if sc == target then mine = true end end
                if (not mine) and d < bestD then best, bestD, bestId = target, d, bpid end
            end
        end
    end
    if not best then return nil end
    IssueGuard(sacus, best)
    return bestId
end

function Auto(brain, cfg, now)
    if cfg.GatewayAuto == false or now < AutoCool then return end
    local sacus = SacuList()
    if table.getn(sacus) == 0 then return end
    local idleList = {}
    for _, u in ipairs(sacus) do if K.EffectivelyIdle(u) then table.insert(idleList, u) end end

    local mr, er = 0, 0
    pcall(function() mr = brain:GetEconomyStoredRatio('MASS') er = brain:GetEconomyStoredRatio('ENERGY') end)
    local bx, bz = brain:GetArmyStartPos()
    local defs, expBuilding = {}, false
    for _, u in ipairs(brain:GetListOfUnits(categories.ALLUNITS, false)) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            local s = K.CatSet(bpid)
            if s.EXPERIMENTAL and u:GetFractionComplete() < 1 then expBuilding = true end
            if s.STRUCTURE then
                local k = K.StructureKind(bpid)
                if k == 'shield' or k == 'aa' or k == 'pd' or k == 'arty' then
                    local p = u:GetPosition()
                    if Dist(p[1], p[3], bx, bz) <= (cfg.DefenseRadius or 90) then defs[k] = (defs[k] or 0) + 1 end
                end
            end
        end
    end
    T4Building = expBuilding
    if table.getn(idleList) == 0 then return end
    local lacking = (defs.shield or 0) == 0 or (defs.aa or 0) < 6 or ((defs.pd or 0) + (defs.arty or 0)) < 8

    local act, why = nil, nil
    if lacking and now >= DefBlock and Gateway.Clusters < (cfg.MaxDefenseClusters or 2) then
        act, why = { a = 'defense_cluster', near = { bx, bz } }, 'base defences lacking'
    elseif expBuilding and cfg.AssistT4 ~= false then
        -- a Tech 4 unit/building is being built (by us or by LOUD): idle gateway ACUs help finish it
        local what = AssistT4(brain, idleList)
        if what then
            AutoCool = now + 6
            ANote(now, 'assisting construction of ' .. what .. ' with ' .. table.getn(idleList) .. ' gateway ACU(s)')
            return
        end
    end
    if not act then
        if mr >= (cfg.StallMassRatio or 0.7) and not expBuilding then
            act, why = { a = 'experimental', what = 'any', near = { bx, bz } }, 'mass not being used'
        elseif mr < 0.5 and er >= 0.6 and now >= FarmBlock and Gateway.Farms < (cfg.MaxMassFarms or 3) then
            act, why = { a = 'mass_farm', near = { bx, bz } }, 'need more mass'
        elseif cfg.GatewayMexDefense ~= false and now >= MexDefBlock and mr >= 0.15 then
            act, why = { a = 'mex_defense', n = 3 }, 'mass extractors need point defence and anti-air'
        end
    end
    if not act then return end

    local c0, f0 = Gateway.Clusters, Gateway.Farms
    local results = Execute(brain, { act }, cfg)
    AutoCool = now + 45
    if act.a == 'defense_cluster' and Gateway.Clusters == c0 then DefBlock = now + 300 end
    if act.a == 'mass_farm' and Gateway.Farms == f0 then FarmBlock = now + 300 end
    if act.a == 'mex_defense' then
        if string.find(tostring(results[1]), 'covered', 1, true) then MexDefBlock = now + 300 else MexDefBlock = now + 90 end
    end
    ANote(now, act.a .. ' (' .. why .. '): ' .. tostring(results[1]))
end
