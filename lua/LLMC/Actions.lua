-- LLM Commander :: executes the (untrusted) action list coming back from the LLM.
-- Every action is validated and wrapped in pcall; bad input just produces a message for the next observation.
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')

-- Strategy knobs (set by Config, changed by the LLM's "strategy" action, read by Macro.lua).
Strategy = { macro = true, auto_attack = true, tech = 3, army = 'mixed', engineers = 0,
    land_factories = 2, air_factories = 1, naval_factories = 0, attack_size = 20 }

-- Economy-only opening: for the first Config.EcoOnlySeconds of game time only mass/power/engineer things are allowed
-- (set Emergency = true by the Controller when the base is under heavy attack).
Emergency = false
local function EcoOnly(ctx)
    return GetGameTimeSeconds() < (ctx.cfg.EcoOnlySeconds or 0) and not Emergency
end

-- Build spots reserved this/last minute so two engineers are not sent to the same tile.
Reservations = {}

-- Builds ordered but possibly not started yet: { kind, x, z, t }. Used in train mode to stop the agent from ordering the
-- same thing again and again while the first one is still queued behind other jobs.
Pending = {}

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
local function Ranked(ctx, x, z, idleOnly, noACU)
    local out = {}
    for _, e in ipairs(Engineers(ctx)) do
      if not (noACU and e.acu) and not (idleOnly and ((not K.EffectivelyIdle(e.unit)) or ctx.load[e.unit]))
         and not (ctx.wait and ((not ctx.idle0[e.unit]) or (ctx.load[e.unit] or 0) >= (ctx.cfg.TrainMaxJobsPerTurn or 3)))
         and not (ctx.cfg.FreeRules and QueueLen(e.unit) >= (ctx.cfg.TrainMaxQueue or 4)) then
        local p = e.unit:GetPosition()
        local score = Dist(p[1], p[3], x, z)
        if not K.EffectivelyIdle(e.unit) then score = score + 150 + 25 * QueueLen(e.unit) end
        if e.acu then score = score + 300 end
        score = score + 80 * (ctx.load[e.unit] or 0)
        table.insert(out, { unit = e.unit, score = score, acu = e.acu })
      end
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

-- Highest tech tier of our finished factories (1-3): the "tech level" used for the power thresholds.
local function CurrentTech(ctx)
    local t = 1
    for _, u in ipairs(K.Select(ctx.all, K.Recipes.factory)) do
        local tt = K.TechOf(u:GetUnitId())
        if tt > t then t = tt end
    end
    return math.min(t, 3)
end

-- Energy income (per second) below which power counts as LOW for the current tech level (Config.PowerLowIncome).
local function PowerLowThreshold(ctx)
    local tbl = ctx.cfg.PowerLowIncome or { 60, 200, 500 }
    return tbl[CurrentTech(ctx)] or tbl[1]
end

-- positions {x,z} of our radars (finished, under construction, or ordered recently)
local function RadarSpots(ctx)
    local out = {}
    for _, u in ipairs(ctx.brain:GetListOfUnits(categories.ALLUNITS, false)) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            if K.CatSet(bpid).STRUCTURE and K.StructureKind(bpid) == 'radar' then
                local p = u:GetPosition()
                table.insert(out, { p[1], p[3] })
            end
        end
    end
    local now = GetGameTimeSeconds()
    for _, e in ipairs(Pending) do
        if e.kind == 'radar' and now - e.t < 300 then table.insert(out, { e.x, e.z }) end
    end
    return out
end

local function TooClose(list, x, z, r)
    if not list then return false end
    for _, p in ipairs(list) do
        local dx, dz = p[1] - x, p[2] - z
        if math.sqrt(dx * dx + dz * dz) < r then return true end
    end
    return false
end

-- markers = nil  -> spiral search around (cx,cz);  markers = {{x,z},..} -> nearest free marker within radius
-- avoid = {{x,z},..} + avoidR: spots closer than avoidR to any of them are rejected (used for radar spacing)
local function FindSpot(ctx, bpid, cx, cz, radius, markers, avoid, avoidR)
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
            if (not Reserved(x, z, half)) and (not TooClose(avoid, x, z, avoidR or 0))
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

-- Structure kinds that may always be built (mass / power economy and storage).
local FreeKinds = { mex = true, hydro = true, pgen = true, fabricator = true, mass_storage = true, energy_storage = true }

-- Number of structures of `kind` that are under construction or ordered-but-not-started.
local function PendingCount(ctx, kind)
    local now = GetGameTimeSeconds()
    local own, unfinished = {}, 0
    for _, u in ipairs(ctx.brain:GetListOfUnits(categories.ALLUNITS, false)) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            if K.CatSet(bpid).STRUCTURE and K.StructureKind(bpid) == kind then
                table.insert(own, u:GetPosition())
                if u:GetFractionComplete() < 1 then unfinished = unfinished + 1 end
            end
        end
    end
    local keep, queued = {}, 0
    for _, e in ipairs(Pending) do
        if now - e.t < 300 then
            if e.kind ~= kind then
                table.insert(keep, e)
            else
                local started = false
                for _, p in ipairs(own) do
                    if math.abs(p[1] - e.x) < 5 and math.abs(p[3] - e.z) < 5 then started = true end
                end
                if not started then
                    table.insert(keep, e)
                    queued = queued + 1
                end
            end
        end
    end
    Pending = keep
    return unfinished + queued
end

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
    local skind = a.unit_id and K.StructureKind(kind) or kind
    if not FreeKinds[skind] and not (a.force and ctx.trusted) and EcoOnly(ctx) then
        return Say(ctx, 'build ' .. kind .. ' skipped: economy-only phase (first ' .. math.floor((ctx.cfg.EcoOnlySeconds or 0) / 60) .. ' minutes). Build mex/power/engineers only.')
    end
    -- Storage gate: only mass / power buildings may be started when stored resources are low.
    if not FreeKinds[skind] and not (a.force and ctx.trusted) then
        local mr, er = 1, 1
        pcall(function()
            mr = ctx.brain:GetEconomyStoredRatio('MASS')
            er = ctx.brain:GetEconomyStoredRatio('ENERGY')
        end)
        local needM, needE = ctx.cfg.MinMassRatio or 0.15, ctx.cfg.MinEnergyRatio or 0.25
        if mr < needM or er < needE then
            return Say(ctx, string.format('build %s skipped: not enough stored (mass %d%%, energy %d%%; need %d%% / %d%%). Build mex/power first.',
                kind, mr * 100, er * 100, needM * 100, needE * 100))
        end
    end

    local n = Num(a.n, 1, 1, 12)

    -- TRAIN MODE: do not stack up orders for the same kind while earlier ones are still under construction / queued
    if ctx.cfg.FreeRules then
        local caps = ctx.cfg.TrainMaxPending or {}
        local cap = caps[skind] or caps.default or 3
        local pend = PendingCount(ctx, skind)
        if pend >= cap then
            return Say(ctx, string.format('build %s skipped: %d already under construction or queued (limit %d). Build something else (power? mass extractors?) or wait for it to finish.', kind, pend, cap))
        end
        n = math.min(n, cap - pend)

        -- POWER SUFFICIENT: more generators are pointless while storage is nearly full and income already covers demand
        if (skind == 'pgen' or skind == 'hydro') and ctx.cfg.TrainPowerSufficient ~= false then
            local er, eInc, eDem = 0, 0, 1
            pcall(function()
                er = ctx.brain:GetEconomyStoredRatio('ENERGY')
                eInc = ctx.brain:GetEconomyIncome('ENERGY') * 10
                eDem = ctx.brain:GetEconomyRequested('ENERGY') * 10
            end)
            -- power is only "sufficient" when income is NOT low for the current tech level (T1 60/s, T2 200/s, T3 500/s by default;
            -- the start, with just the ACU's 20/s, is LOW) AND storage is nearly full AND income covers demand
            local lowT = PowerLowThreshold(ctx)
            if eInc >= lowT and er >= (ctx.cfg.TrainPowerFull or 0.8) and eInc >= eDem * (ctx.cfg.TrainPowerSurplus or 1.0) then
                return Say(ctx, string.format('build %s skipped: power is already sufficient for tech %d (income %d/s is not low - low is under %d/s - storage %d%%, demand %d/s). Build something else: mass extractors, factories, combat units, defences.', kind, CurrentTech(ctx), eInc, lowT, er * 100, eDem))
            end
        end
    end

    local tech = Num(a.tech, 4, 1, 4)
    local cx, cz = ParseNear(ctx, a.near)
    local isMarker = (kind == 'mex' or kind == 'hydro')
    local radius = Num(a.radius, isMarker and 70 or 30, 5, 150)
    local markers = nil
    if isMarker then markers = K.Markers(kind == 'mex' and 'Mass' or 'Hydrocarbon') end

    -- RADAR SPACING: radars must be at least Config.RadarSpacing (115) apart - they would just cover the same ground
    local avoid, avoidR = nil, nil
    if skind == 'radar' and (ctx.cfg.RadarSpacing or 115) > 0 then
        avoid, avoidR = RadarSpots(ctx), ctx.cfg.RadarSpacing or 115
    end
    local placed, failed = 0, {}
    for i = 1, n do
        local did = false
        for _, e in ipairs(Ranked(ctx, cx, cz, a.idle_only, a.no_acu)) do
            local bpid = K.BestBuildable(e.unit, cands, tech)
            if bpid and not failed[bpid] then
                local x, z = FindSpot(ctx, bpid, cx, cz, radius, markers, avoid, avoidR)
                if x then
                    -- priority: drop the builder's current queue first (once per turn), so this job starts NOW
                    if a.priority and not ctx.cleared[e.unit] then
                        IssueClearCommands({ e.unit })
                        ctx.cleared[e.unit] = true
                    end
                    IssueBuildMobile({ e.unit }, Vec(x, z), bpid, {})
                    table.insert(Pending, { kind = skind, x = x, z = z, t = GetGameTimeSeconds() })
                    if avoid then table.insert(avoid, { x, z }) end
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
    if avoid and placed < n then
        Say(ctx, 'build radar: radars must be at least ' .. avoidR .. ' apart - no spot found within ' .. radius .. ' of that point that is far enough from your other radars; pick "near" a different place (a radar covers a radius of about ' .. avoidR .. ')')
    end
    Say(ctx, string.format('build %s x%d: %d queued%s', kind, n, placed,
        placed < n and (ctx.wait and ' (no IDLE builder for the rest: engineers and the ACU take new orders only after finishing the previous ones - wait for state.engineers.idle_ids / state.acu.idle; or no tech/spot)' or ' (no free builder / tech / spot for the rest; builders with 4+ queued jobs are skipped)') or ''))
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
    local isEng = (kind == 'engineer') or (a.unit_id and K.Match(K.Units.engineer, kind))
    if not isEng and EcoOnly(ctx) then
        return Say(ctx, 'produce ' .. kind .. ' skipped: economy-only phase (engineers only)')
    end
    if isEng and not ctx.trusted and not ctx.cfg.FreeRules then
        for _, e in ipairs(K.Select(ctx.all, K.Units.engineer)) do
            if K.EffectivelyIdle(e) then
                return Say(ctx, 'produce engineer skipped: an engineer is idle - give it work (or let it assist an upgrade) instead of building more')
            end
        end
    end
    local n = Num(a.n, 1, 1, 30)
    local tech = Num(a.tech, 4, 1, 4)
    local capable = {}
    for _, f in ipairs(Factories(ctx, a.factory)) do
        if (ctx.wait and ctx.idle0[f] and (ctx.facUsed[f] or 0) < (ctx.cfg.TrainMaxProduceOrders or 3)) or ((not ctx.wait) and QueueLen(f) < 20) then
            local bpid = K.BestBuildable(f, cands, tech)
            if bpid then table.insert(capable, { unit = f, bp = bpid }) end
        end
    end
    local cnt = table.getn(capable)
    if cnt == 0 then
        if ctx.wait then return Say(ctx, 'produce ' .. kind .. ': no idle suitable factory - a factory takes a new order only when its queue is EMPTY (wait for factories[].idle = true), or wrong type/tech/upgrading') end
        return Say(ctx, 'produce ' .. kind .. ': no suitable factory (wrong type, wrong tech, busy or upgrading)')
    end
    local left, queued = n, 0
    for i, c in ipairs(capable) do
        local share = math.ceil(left / (cnt - i + 1))
        if share > 0 then
            if a.clear then IssueClearCommands({ c.unit }) end
            IssueBuildFactory({ c.unit }, c.bp, share)
            ctx.facUsed[c.unit] = (ctx.facUsed[c.unit] or 0) + 1
            queued = queued + share
            left = left - share
        end
    end
    Say(ctx, string.format('produce %s: %d queued across %d factories', kind, queued, cnt))
end

-- State of all our mass extractors (for the factory tech gate).
local function MexStatus(ctx)
    local ms = { total = 0, min = 9, upgrading = 0, unfinished = 0 }
    for _, u in ipairs(ctx.brain:GetListOfUnits(categories.ALLUNITS, false)) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            if K.CatSet(bpid).MASSEXTRACTION and K.CatSet(bpid).STRUCTURE then
                ms.total = ms.total + 1
                local t = K.TechOf(bpid)
                if t < ms.min then ms.min = t end
                if u:GetFractionComplete() < 1 then ms.unfinished = ms.unfinished + 1 end
                if u:IsUnitState('Upgrading') then ms.upgrading = ms.upgrading + 1 end
            end
        end
    end
    return ms
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
    local from, maxT = tonumber(a.from_tech), tonumber(a.max_tech)
    local done = 0

    -- FACTORY TECH GATE: a factory may only go up a tech level when EVERY mass extractor is already at the
    -- new level (none upgrading / under construction) and energy storage is full.
    local ms = MexStatus(ctx)
    local er = 1
    pcall(function() er = ctx.brain:GetEconomyStoredRatio('ENERGY') end)
    local needE = ctx.cfg.TechEnergyRatio or 0.98
    local why = nil
    local function GateOK(bpid)
        if ctx.cfg.FreeRules then return true end      -- train mode: the agent learns the tech order from rewards
        if K.CatSet(bpid).MASSEXTRACTION then return true end
        if EcoOnly(ctx) then why = 'economy-only phase' return false end
        local nextT = K.TechOf(bpid) + 1
        if ms.total == 0 then why = 'no mass extractors' return false end
        if ms.unfinished > 0 or ms.upgrading > 0 then why = 'mass extractors still upgrading or being built' return false end
        if ms.min < nextT then why = 'not all mass extractors are T' .. nextT .. ' yet (lowest is T' .. ms.min .. ')' return false end
        if er < needE then why = string.format('energy storage %d%% (need %d%%)', er * 100, needE * 100) return false end
        return true
    end
    for _, u in ipairs(list) do
        if done >= n then break end
        local bpid = u:GetUnitId()
        local cur = K.TechOf(bpid)
        local up = u:GetBlueprint().General and u:GetBlueprint().General.UpgradesTo
        if up and up ~= '' and (not from or cur == from) and (not maxT or cur < maxT)
           and not u:IsUnitState('Upgrading') and u:CanBuild(up) and GateOK(bpid)
           and ((not ctx.wait) or K.CatSet(bpid).MASSEXTRACTION or ctx.idle0[u]) then
            -- factories are almost always busy building units: drop the queue so the upgrade can start
            if not K.CatSet(bpid).MASSEXTRACTION and not u:IsIdleState() then IssueClearCommands({ u }) end
            IssueUpgrade({ u }, up)
            done = done + 1
        end
    end
    Say(ctx, string.format('upgrade %s: %d started%s', tostring(a.what or a.id), done,
        (done == 0 and why) and (' - blocked: ' .. why) or ''))
end

function Handlers.assist(ctx, a)
    local target = ctx.units[tostring(a.target)]
    if not target then return Say(ctx, 'assist: unknown target id ' .. tostring(a.target)) end
    -- ASSIST RULE: engineers / ACU may only assist a mass extractor that is upgrading, or the ACU while it enhances.
    local tcat = K.CatSet(target:GetUnitId())
    local okMex = tcat.MASSEXTRACTION and tcat.STRUCTURE and target:IsUnitState('Upgrading')
    local okAcu = tcat.COMMAND and target:IsUnitState('Enhancing')
    if ctx.cfg.FreeRules then
        -- only assist something that is really under construction / upgrading (and is not itself just assisting)
        local focus = nil
        pcall(function() focus = target:GetFocusUnit() end)
        local working = (target:GetFractionComplete() < 1) or target:IsUnitState('Upgrading') or target:IsUnitState('Building') or (focus ~= nil)
        if target:IsUnitState('Guarding') or not working then
            return Say(ctx, 'assist refused: that unit is not building or upgrading anything - an engineer assisting it would just stand there')
        end
    end
    if not (okMex or okAcu or ctx.cfg.FreeRules) then
        return Say(ctx, 'assist refused: engineers/ACU only assist a mass extractor upgrade or an ACU upgrade')
    end
    local tp = target:GetPosition()
    local n = Num(a.n, 2, 1, 20)
    local sent = {}
    for _, e in ipairs(Ranked(ctx, tp[1], tp[3], a.idle_only ~= false)) do
        if table.getn(sent) >= n then break end
        if e.unit == target then e.acu = 'self' end
        -- keep the commander near home: it only assists targets within ACUAssistRadius
        local far = false
        if e.acu then
            local ap = e.unit:GetPosition()
            far = Dist(ap[1], ap[3], tp[1], tp[3]) > (ctx.cfg.ACUAssistRadius or 200)
        end
        if not far and e.acu ~= 'self' then table.insert(sent, e.unit) end
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
    local engs = Ranked(ctx, cx, cz, a.idle_only ~= false)
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

function Handlers.strategy(ctx, a)
    local S = Strategy
    if a.tech ~= nil then S.tech = Num(a.tech, S.tech, 1, 3) end
    if a.army == 'land' or a.army == 'air' or a.army == 'mixed' then S.army = a.army end
    if a.engineers ~= nil then S.engineers = Num(a.engineers, 0, 0, 30) end
    if a.land_factories ~= nil then S.land_factories = Num(a.land_factories, 2, 0, 8) end
    if a.air_factories ~= nil then S.air_factories = Num(a.air_factories, 1, 0, 8) end
    if a.naval_factories ~= nil then S.naval_factories = Num(a.naval_factories, 0, 0, 6) end
    if a.attack_size ~= nil then S.attack_size = Num(a.attack_size, 20, 5, 150) end
    if a.macro ~= nil then S.macro = a.macro and true or false end
    if a.auto_attack ~= nil then S.auto_attack = a.auto_attack and true or false end
    Say(ctx, 'strategy updated')
end

-- {"a":"mex_defense","n":3,"pd":1,"aa":1,"tech":2}: a point defence and an anti-air next to mass extractors that lack them
-- (most exposed = farthest from the base first). An extractor is "covered" when enough PD / AA stand within Config.MexDefenseCover.
function Handlers.mex_defense(ctx, a)
    if EcoOnly(ctx) then return Say(ctx, 'mex_defense skipped: economy-only phase') end
    local mr, er = 1, 1
    pcall(function() mr = ctx.brain:GetEconomyStoredRatio('MASS') er = ctx.brain:GetEconomyStoredRatio('ENERGY') end)
    if mr < (ctx.cfg.MinMassRatio or 0.15) or er < (ctx.cfg.MinEnergyRatio or 0.25) then
        return Say(ctx, 'mex_defense skipped: not enough stored mass/energy for defences yet')
    end
    local cover = Num(a.cover, ctx.cfg.MexDefenseCover or 20, 5, 60)
    local radius = Num(a.radius, ctx.cfg.MexDefenseRadius or 12, 4, 30)
    local wantPD, wantAA = Num(a.pd, ctx.cfg.MexDefensePD or 1, 0, 3), Num(a.aa, ctx.cfg.MexDefenseAA or 1, 0, 3)
    local tech = Num(a.tech, ctx.cfg.MexDefenseTech or 2, 1, 3)
    local maxMex = Num(a.n, 3, 1, 10)

    local mexes, pds, aas = {}, {}, {}
    for _, u in ipairs(ctx.all) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            if K.CatSet(bpid).STRUCTURE then
                local k = K.StructureKind(bpid)
                if k == 'mex' then table.insert(mexes, u:GetPosition())
                elseif k == 'pd' then table.insert(pds, u:GetPosition())
                elseif k == 'aa' then table.insert(aas, u:GetPosition()) end
            end
        end
    end
    local now = GetGameTimeSeconds()
    for _, e in ipairs(Pending) do            -- defences ordered but not finished count as cover
        if now - e.t < 300 then
            if e.kind == 'pd' then table.insert(pds, { e.x, 0, e.z }) elseif e.kind == 'aa' then table.insert(aas, { e.x, 0, e.z }) end
        end
    end
    local function Count(list, x, z)
        local n = 0
        for _, p in ipairs(list) do
            if Dist(p[1], p[3], x, z) <= cover then n = n + 1 end
        end
        return n
    end
    local lacking = {}
    for _, mp in ipairs(mexes) do
        local mPD, mAA = wantPD - Count(pds, mp[1], mp[3]), wantAA - Count(aas, mp[1], mp[3])
        if mPD > 0 or mAA > 0 then
            table.insert(lacking, { x = mp[1], z = mp[3], pd = math.max(mPD, 0), aa = math.max(mAA, 0), d = Dist(mp[1], mp[3], ctx.baseX, ctx.baseZ) })
        end
    end
    if table.getn(lacking) == 0 then return Say(ctx, 'mex_defense: all ' .. table.getn(mexes) .. ' mass extractors are covered by point defence and anti-air') end
    table.sort(lacking, function(p, q) return p.d > q.d end)

    local pdC, aaC = K.Candidates(K.Structures.pd, ctx.faction), K.Candidates(K.Structures.aa, ctx.faction)
    local queued, covered = 0, 0
    for i = 1, math.min(maxMex, table.getn(lacking)) do
        local m = lacking[i]
        local did = false
        for _, job in ipairs({ { 'pd', pdC, m.pd }, { 'aa', aaC, m.aa } }) do
            for k = 1, job[3] do
                for _, e in ipairs(Ranked(ctx, m.x, m.z, a.idle_only)) do
                    local bpid = K.BestBuildable(e.unit, job[2], tech)
                    if bpid then
                        local x, z = FindSpot(ctx, bpid, m.x, m.z, radius, nil)
                        if x then
                            IssueBuildMobile({ e.unit }, Vec(x, z), bpid, {})
                            table.insert(Pending, { kind = job[1], x = x, z = z, t = GetGameTimeSeconds() })
                            ctx.load[e.unit] = (ctx.load[e.unit] or 0) + 1
                            queued = queued + 1
                            did = true
                            break
                        end
                    end
                end
            end
        end
        if did then covered = covered + 1 end
    end
    Say(ctx, string.format('mex_defense: %d defence structures queued next to %d of %d mass extractors that lacked cover%s', queued, covered, table.getn(lacking),
        queued == 0 and ' (no idle builder, tech or room)' or ''))
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
    local skipped = 0
    if ctx.wait and ctx.cfg.TrainWaitSquads ~= false and mode ~= 'retreat' and mode ~= 'stop' then
        local ready = {}
        for _, u in ipairs(units) do
            if ctx.idle0[u] then table.insert(ready, u) end
        end
        skipped = table.getn(units) - table.getn(ready)
        units = ready
        if table.getn(units) == 0 then
            return Say(ctx, mode .. ' ' .. name .. ': all ' .. skipped .. ' units are still busy with earlier orders - units take new orders only when idle (retreat and stop always work)')
        end
    end

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
    Say(ctx, string.format('%s %s: %d units%s', mode, name, table.getn(units), skipped > 0 and (' (' .. skipped .. ' busy units skipped)') or ''))
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
function Execute(brain, actions, cfg, trusted)
    local bx, bz = brain:GetArmyStartPos()
    local ctx = {
        brain = brain, cfg = cfg, results = {}, load = {}, trusted = trusted, cleared = {},
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

    -- TRAIN MODE - WAIT FOR ORDERS TO FINISH: remember which builders / factories / units were idle (nothing queued) when this
    -- turn's orders arrived. New orders go only to those: a builder, factory or unit that is still carrying out earlier orders
    -- is left alone, so the agent cannot keep re-issuing the same order on top of a queue.
    ctx.wait = (cfg.FreeRules and cfg.TrainWaitForOrders ~= false) and true or false
    ctx.idle0, ctx.facUsed = {}, {}
    local cleared = 0
    if ctx.wait then
        for _, u in ipairs(ctx.all) do
            if not u.Dead then
                local s = K.CatSet(u:GetUnitId())
                if s.FACTORY then
                    ctx.idle0[u] = (QueueLen(u) == 0)                          -- a factory is free when its queue is empty
                elseif s.ENGINEER or s.COMMAND then
                    if (not u:IsIdleState()) and K.EffectivelyIdle(u) then
                        -- busy for the engine but doing nothing (e.g. assisting a unit that has finished): drop the dead
                        -- Guard order now, otherwise the orders we give it would queue behind it and never start
                        IssueClearCommands({ u })
                        cleared = cleared + 1
                        ctx.idle0[u] = true
                    else
                        ctx.idle0[u] = u:IsIdleState() and QueueLen(u) == 0
                    end
                elseif s.MOBILE then
                    ctx.idle0[u] = u:IsIdleState()
                end
            end
        end
        local ie, ifc, iu = 0, 0, 0
        for u, v in pairs(ctx.idle0) do
            if v then
                local s = K.CatSet(u:GetUnitId())
                if s.FACTORY then ifc = ifc + 1 elseif s.ENGINEER or s.COMMAND then ie = ie + 1 else iu = iu + 1 end
            end
        end
        Say(ctx, string.format('at the start of this turn %d engineers/ACU, %d factories and %d other units were idle (only idle ones accept new orders)%s', ie, ifc, iu,
            cleared > 0 and (' - ' .. cleared .. ' engineers were only assisting something that does nothing; their dead assist orders were cleared') or ''))
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


-- Called every few seconds by the controller (replace / train modes): engineers and ACUs that are "busy" for the engine
-- but have been doing nothing for a while (a dead assist order) get their commands cleared.
function CleanStale(brain, cfg, now)
    local list = {}
    for _, u in ipairs(brain:GetListOfUnits(categories.ALLUNITS, false, true)) do
        if not u.Dead then
            local s = K.CatSet(u:GetUnitId())
            if s.ENGINEER or s.COMMAND then table.insert(list, u) end
        end
    end
    return K.ClearStale(list, now, cfg.StaleAssistSeconds or 6)
end
