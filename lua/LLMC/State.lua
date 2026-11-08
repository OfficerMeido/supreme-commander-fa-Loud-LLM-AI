-- LLM Commander :: builds the observation (a Lua table) that is sent to the LLM.
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')

local function R(v) return math.floor(v + 0.5) end
local function R1(v) return math.floor(v * 10 + 0.5) / 10 end
local function XZ(p) return { R(p[1]), R(p[3]) } end
local function Dist(x1, z1, x2, z2)
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end

local PrevCounts = nil

local function Eco(brain, t)
    local o = {}
    pcall(function()
        o.stored = R(brain:GetEconomyStored(t))
        o.stored_ratio = R1(brain:GetEconomyStoredRatio(t))
        o.income = R1(brain:GetEconomyIncome(t) * 10)      -- per second
        o.demand = R1(brain:GetEconomyRequested(t) * 10)   -- per second
    end)
    return o
end

local function QueueLen(u)
    local ok, q = pcall(function() return u:GetCommandQueue() end)
    if ok and q then return table.getn(q) end
    return 0
end

-- Everything the army can currently see/sense of the enemy, clustered into ~48-unit grid cells.
function ScanEnemies(brain, idx, baseX, baseZ, radius)
    local res = { clusters = {}, near_base = { land = 0, air = 0, naval = 0 }, radar_blips = 0 }
    local grid = {}
    pcall(function()
        local list = brain:GetUnitsAroundPoint(categories.ALLUNITS, { baseX, 0, baseZ }, radius, 'Enemy')
        for _, u in ipairs(list) do
            if not u.Dead then
                local now, ever, radar = false, false, false
                local blip = u:GetBlip(idx)
                if blip then
                    now = blip:IsSeenNow(idx) or blip:IsOnOmni(idx)
                    ever = blip:IsSeenEver(idx)
                    radar = blip:IsOnRadar(idx) or blip:IsOnSonar(idx)
                end
                local p = u:GetPosition()
                local bpid = u:GetUnitId()
                local isStruct = K.CatSet(bpid).STRUCTURE
                local key = math.floor(p[1] / 48) .. ',' .. math.floor(p[3] / 48)
                local function Cell()
                    local c = grid[key]
                    if not c then
                        c = { x = 0, z = 0, n = 0, struct = 0, def = 0, land = 0, air = 0, naval = 0, radar = 0, armies = {} }
                        grid[key] = c
                    end
                    return c
                end
                if isStruct and (now or ever) then
                    local c = Cell()
                    c.x = c.x + p[1] c.z = c.z + p[3] c.n = c.n + 1
                    c.struct = c.struct + 1
                    local kind = K.StructureKind(bpid)
                    if kind == 'pd' or kind == 'aa' or kind == 'torpedo' or kind == 'shield' or kind == 'arty' then c.def = c.def + 1 end
                    c.armies[u:GetArmy()] = true
                elseif (not isStruct) and now then
                    local c = Cell()
                    c.x = c.x + p[1] c.z = c.z + p[3] c.n = c.n + 1
                    local role = K.MobileRole(bpid)
                    if role == 'naval' then c.naval = c.naval + 1
                    elseif role == 'land' then c.land = c.land + 1
                    elseif role == 'scouts' then
                    else c.air = c.air + 1 end
                    c.armies[u:GetArmy()] = true
                    if Dist(p[1], p[3], baseX, baseZ) < 120 then
                        if role == 'naval' then res.near_base.naval = res.near_base.naval + 1
                        elseif role == 'land' then res.near_base.land = res.near_base.land + 1
                        elseif role ~= 'scouts' then res.near_base.air = res.near_base.air + 1 end
                    end
                elseif radar and not now then
                    res.radar_blips = res.radar_blips + 1
                end
            end
        end
    end)
    local list = {}
    for _, c in pairs(grid) do
        local cx, cz = c.x / c.n, c.z / c.n
        local arm = {}
        for a, _ in pairs(c.armies) do table.insert(arm, a) end
        table.insert(list, { pos = { R(cx), R(cz) }, structures = c.struct, defenses = c.def,
            land = c.land, air = c.air, naval = c.naval, armies = arm, dist = R(Dist(cx, cz, baseX, baseZ)) })
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    for i = 1, math.min(12, table.getn(list)) do table.insert(res.clusters, list[i]) end
    return res
end

function Build(brain, cfg, seq, sid, now, lastResults)
    local idx = brain:GetArmyIndex()
    local faction = brain:GetFactionIndex()
    local bx, bz = brain:GetArmyStartPos()
    local st = { seq = seq, sid = sid, t = R(now), faction = K.FactionNames[faction], base = { R(bx), R(bz) } }
    if ScenarioInfo.size then st.map = { w = ScenarioInfo.size[1], h = ScenarioInfo.size[2] } end

    st.eco = { mass = Eco(brain, 'MASS'), energy = Eco(brain, 'ENERGY') }

    ---------------------------------------------------------------- own units
    local all = brain:GetListOfUnits(categories.ALLUNITS, false)
    local structs, building = {}, 0
    local mexPos, pdPos, aaPos = {}, {}, {}           -- finished structures, to find mass extractors without defences
    local constr, engBusy, engQueued = {}, 0, 0      -- under construction per kind; busy engineers; queued jobs
    local factories, engIdle, engTotal = {}, {}, 0
    local squads = {}
    local counts = {}
    local acu = nil
    local engineers, factoryUnits, builders = {}, {}, {}

    for _, u in ipairs(all) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            local s = K.CatSet(bpid)
            if u:GetFractionComplete() < 1 then
                building = building + 1
                if s.STRUCTURE then
                    local ck = K.StructureKind(bpid)
                    constr[ck] = (constr[ck] or 0) + 1
                end
            elseif s.COMMAND then
                acu = u
                table.insert(builders, u)
            elseif s.ENGINEER and s.MOBILE then
                engTotal = engTotal + 1
                table.insert(engineers, u)
                table.insert(builders, u)
                if K.EffectivelyIdle(u) then table.insert(engIdle, tostring(u:GetEntityId())) else engBusy = engBusy + 1 end
                engQueued = engQueued + QueueLen(u)
            elseif s.STRUCTURE then
                local kind = K.StructureKind(bpid)
                local tk = 't' .. K.TechOf(bpid)
                if kind == 'mex' then table.insert(mexPos, u:GetPosition())
                elseif kind == 'pd' then table.insert(pdPos, u:GetPosition())
                elseif kind == 'aa' then table.insert(aaPos, u:GetPosition()) end
                structs[kind] = structs[kind] or {}
                structs[kind][tk] = (structs[kind][tk] or 0) + 1
                if s.FACTORY then
                    table.insert(factoryUnits, u)
                    local p = u:GetPosition()
                    local fk = 'other'
                    if kind == 'land_factory' then fk = 'land' elseif kind == 'air_factory' then fk = 'air' elseif kind == 'naval_factory' then fk = 'naval' end
                    local fq = QueueLen(u)
                    table.insert(factories, { id = tostring(u:GetEntityId()), kind = fk, tech = K.TechOf(bpid),
                        pos = XZ(p), idle = (fq == 0), queue = fq,
                        upgrading = u:IsUnitState('Upgrading') and true or false })
                elseif kind == 'mex' and u:IsUnitState('Upgrading') then
                    structs.mex_upgrading = (structs.mex_upgrading or 0) + 1
                end
            elseif s.MOBILE then
                local role = K.MobileRole(bpid)
                if role ~= 'other' then
                    local p = u:GetPosition()
                    local q = squads[role]
                    if not q then q = { n = 0, idle = 0, x = 0, z = 0 } squads[role] = q end
                    q.n = q.n + 1 q.x = q.x + p[1] q.z = q.z + p[3]
                    if u:IsIdleState() then q.idle = q.idle + 1 end
                end
            end
        end
    end
    local undef = 0
    for _, mp in ipairs(mexPos) do
        local pdN, aaN = 0, 0
        for _, p in ipairs(pdPos) do if Dist(p[1], p[3], mp[1], mp[3]) <= (cfg.MexDefenseCover or 20) then pdN = pdN + 1 end end
        for _, p in ipairs(aaPos) do if Dist(p[1], p[3], mp[1], mp[3]) <= (cfg.MexDefenseCover or 20) then aaN = aaN + 1 end end
        if pdN < (cfg.MexDefensePD or 1) or aaN < (cfg.MexDefenseAA or 1) then undef = undef + 1 end
    end
    st.mex_defense = { mex = table.getn(mexPos), undefended = undef }
    -- "low power" depends on the tech level: energy income under Config.PowerLowIncome (T1 60/s, T2 200/s, T3 500/s)
    local techLevel = 1
    for _, f in ipairs(factories) do
        if f.tech > techLevel then techLevel = f.tech end
    end
    local lowT = (cfg.PowerLowIncome or { 60, 200, 500 })[math.min(techLevel, 3)] or 60
    st.tech_level = techLevel
    st.power_low_income = lowT
    st.structures = structs
    st.building_in_progress = building
    st.under_construction = constr          -- e.g. {land_factory=1, pgen=2}: ordered AND started; do not order the same again
    st.factories = factories
    st.engineers = { total = engTotal, idle = table.getn(engIdle) }
    local idl = {}
    for i = 1, math.min(12, table.getn(engIdle)) do table.insert(idl, engIdle[i]) end
    st.engineers.idle_ids = idl

    local army, nowCounts = {}, {}
    for role, q in pairs(squads) do
        army[role] = { n = q.n, idle = q.idle, center = { R(q.x / q.n), R(q.z / q.n) } }
        nowCounts[role] = q.n
    end
    st.army = army

    -- losses since the previous observation (rough: drop in per-role unit count)
    if PrevCounts then
        local lost = {}
        for role, n in pairs(PrevCounts) do
            local d = n - (nowCounts[role] or 0)
            if d > 0 then lost[role] = d end
        end
        st.units_lost_since_last = lost
    end
    PrevCounts = nowCounts

    if acu then
        local mhp = acu:GetMaxHealth()
        if mhp < 1 then mhp = 1 end
        st.acu = { id = tostring(acu:GetEntityId()), pos = XZ(acu:GetPosition()), hp = R1(acu:GetHealth() / mhp),
                   idle = K.EffectivelyIdle(acu), queued_jobs = QueueLen(acu) }
        -- available ACU enhancements (name + mass cost)
        pcall(function()
            local enh = acu:GetBlueprint().Enhancements
            local list = {}
            if enh then
                for name, e in pairs(enh) do
                    if type(e) == 'table' and e.BuildCostMass and not string.find(name, 'Remove') then
                        local have = acu:HasEnhancement(name)
                        local pre = e.Prerequisite
                        if (not have) and ((not pre) or acu:HasEnhancement(pre)) then
                            table.insert(list, { name = name, mass = R(e.BuildCostMass) })
                        end
                    end
                end
            end
            table.sort(list, function(a, b) return a.mass < b.mass end)
            local cut = {}
            for i = 1, math.min(8, table.getn(list)) do table.insert(cut, list[i]) end
            st.acu.enhancements = cut
        end)
    end

    ---------------------------------------------------------------- what can be built
    local canS, canU = {}, {}
    pcall(function()
        for _, name in ipairs(K.StructureOrder) do
            local t = K.TechsFor(builders, K.Candidates(K.Structures[name], faction))
            if table.getn(t) > 0 then canS[name] = t end
        end
        for name, recipe in pairs(K.Units) do
            local t = K.TechsFor(factoryUnits, K.Candidates(recipe, faction))
            if table.getn(t) > 0 then canU[name] = t end
        end
    end)
    st.can_build = { structures = canS, units = canU }

    ---------------------------------------------------------------- free resource spots near base
    pcall(function()
        local b = builders[1]
        if not b then return end
        local function Free(markerType, kind)
            local ids = K.Candidates(K.Structures[kind], faction)
            local bpid = K.BestBuildable(b, ids, 1)
            if not bpid then return nil end
            local out = {}
            for _, m in ipairs(K.Markers(markerType)) do
                if brain:CanBuildStructureAt(bpid, { m[1], GetSurfaceHeight(m[1], m[2]), m[2] }) then
                    table.insert(out, { R(m[1]), R(m[2]), R(Dist(m[1], m[2], bx, bz)) })
                end
            end
            table.sort(out, function(p, q) return p[3] < q[3] end)
            local cut = {}
            for i = 1, math.min(8, table.getn(out)) do table.insert(cut, out[i]) end
            return cut
        end
        st.free_mass = Free('Mass', 'mex')
        st.free_hydro = Free('Hydrocarbon', 'hydro')
    end)

    ---------------------------------------------------------------- enemies
    local diag = 1500
    if ScenarioInfo.size then diag = math.max(ScenarioInfo.size[1], ScenarioInfo.size[2]) * 1.5 end
    local e = ScanEnemies(brain, idx, bx, bz, diag)
    st.contacts = e.clusters
    st.enemy_near_base = e.near_base
    st.radar_blips = e.radar_blips
    st.under_attack = (e.near_base.land + e.near_base.air + e.near_base.naval) > 0

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

    -- Alerts (train mode): plain-language warnings about the most common mistakes
    if cfg.FreeRules then
        local alerts = {}
        local m, e = st.eco.mass, st.eco.energy
        if (e.stored_ratio and e.stored_ratio < 0.2) or (e.income and e.income < lowT) then
            table.insert(alerts, 'POWER LOW for tech ' .. techLevel .. ': income ' .. tostring(e.income) .. '/s (low = under ' .. lowT .. '/s), ' ..
                math.floor((e.stored_ratio or 0) * 100) .. '% stored: build power generators (pgen) - everything slows down and you lose reward')
        end
        if undef > 0 and table.getn(mexPos) >= 2 then
            table.insert(alerts, undef .. ' of your ' .. table.getn(mexPos) .. ' mass extractors have no point defence and/or anti-air next to them: {"a":"mex_defense","n":3}')
        end
        if e.income and e.demand and e.income < e.demand then
            table.insert(alerts, 'power income (' .. e.income .. '/s) is below demand (' .. e.demand .. '/s): build more pgen')
        end
        if e.stored_ratio and e.stored_ratio >= 0.8 and e.income and e.demand and e.income >= e.demand and e.income >= lowT then
            table.insert(alerts, 'power is SUFFICIENT (storage ' .. math.floor(e.stored_ratio * 100) .. '%, income ' .. e.income .. '/s >= demand ' .. e.demand ..
                '/s): more power generators are refused and useless - build mass extractors, factories, COMBAT UNITS or defences instead')
        end
        if m.stored_ratio and m.stored_ratio < 0.02 then
            table.insert(alerts, 'MASS EMPTY: build mass extractors (mex) on free_mass spots, stop spending on expensive things')
        end
        if (constr.pgen or 0) == 0 and structs.pgen == nil and structs.hydro == nil then
            table.insert(alerts, 'you have NO power generator at all - build pgen first')
        end
        local fac = (constr.land_factory or 0) + (constr.air_factory or 0) + (constr.naval_factory or 0)
        if fac > 0 then
            table.insert(alerts, fac .. ' factory(ies) already under construction - do NOT order more factories now; build power/mass/engineers instead')
        end
        local aq = st.acu and st.acu.queued_jobs or 0
        if aq >= 3 then
            table.insert(alerts, 'the ACU already has ' .. aq .. ' queued jobs; new build orders wait behind them (builders with 4+ jobs get no more orders)')
        end
        -- orders are only accepted by idle builders / factories (cfg.TrainWaitForOrders)
        local idleFac = 0
        for _, f in ipairs(factories) do
            if f.idle and f.queue == 0 and not f.upgrading then idleFac = idleFac + 1 end
        end
        local acuIdle = st.acu and st.acu.idle
        if table.getn(engIdle) == 0 and not acuIdle then
            table.insert(alerts, 'every engineer and the ACU is BUSY: build orders to busy builders are refused - wait until one is idle (state.engineers.idle_ids / state.acu.idle) and do not repeat orders that are already in progress')
        end
        if table.getn(factories) > 0 and idleFac == 0 then
            table.insert(alerts, 'every factory still has a queue: produce orders are refused until a factory has finished its queue (factories[].idle) - queue bigger batches (n=10) when one is idle')
        end
        -- the two things this agent forgets: engineers, and moving its army
        if engTotal < 4 and table.getn(factories) > 0 then
            table.insert(alerts, 'you have only ' .. engTotal .. ' engineers: produce engineers FIRST ({"a":"produce","factory":"land","what":"engineer","n":3}) - they build your economy; you can queue combat units after them in the same turn')
        end
        local armyN, armyIdle = 0, 0
        for role, q in pairs(squads) do
            if role ~= 'scouts' then armyN = armyN + q.n armyIdle = armyIdle + q.idle end
        end
        if armyIdle >= 3 then
            local tx, tz = nil, nil
            if st.enemy_starts and st.enemy_starts[1] then tx, tz = st.enemy_starts[1].pos[1], st.enemy_starts[1].pos[2] end
            if st.contacts and st.contacts[1] then tx, tz = st.contacts[1].pos[1], st.contacts[1].pos[2] end
            local hint = 'gather them with {"a":"move","squad":"land","x":..,"z":..} or scout for the enemy'
            if tx then hint = 'e.g. {"a":"attack","squad":"land","x":' .. tx .. ',"z":' .. tz .. '} (enemy near ' .. tx .. ',' .. tz .. ')' end
            table.insert(alerts, armyIdle .. ' of your ' .. armyN .. ' combat units are IDLE (an idle army earns nothing): send them - ' .. hint)
        end
        if engTotal > 0 and table.getn(engIdle) > 0 then
            table.insert(alerts, table.getn(engIdle) .. ' engineer(s) idle: give them build/assist/reclaim orders')
        end
        st.alerts = alerts
        st.construction = { engineers_busy = engBusy, queued_jobs_engineers = engQueued }
    end
    return st
end
