-- LLM Commander :: automatic macro manager (the "stock AI" part).
-- Runs every Config.MacroInterval game seconds, independent of how slow the LLM is.
-- It keeps the economy growing, teches up (mex + factories), builds factories, keeps engineers
-- working, keeps factories producing, reacts to attacks and sends attack waves.
-- The LLM steers it through the "strategy" action and can still give any order itself.
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')
local Actions = import('/mods/LLMCommander/lua/LLMC/Actions.lua')

Recent = {}                 -- last few macro decisions, shown to the LLM
local LastState = nil       -- newest observation (for contacts / enemy starts)
local Cool = {}             -- rule name -> game time it may fire again
local OpeningPhase = 0      -- 0 start, 1 factory+pgens queued, 2 engineers queued, 3 done (normal macro)
local OpeningStart = nil
local WaveCount, LastWave = 0, -1000
local Rot = {}              -- factory id -> unit rotation counter

function SetState(st) LastState = st end

local function Note(now, msg)
    table.insert(Recent, 't' .. math.floor(now) .. ' ' .. msg)
    while table.getn(Recent) > 8 do table.remove(Recent, 1) end
end

local function Ready(name, now) return (Cool[name] or 0) <= now end
local function Wait(name, now, secs) Cool[name] = now + secs end

local function QueueLen(u)
    local ok, q = pcall(function() return u:GetCommandQueue() end)
    if ok and q then return table.getn(q) end
    return 0
end

local function Ratio(brain, t)
    local r, inc, dem = 0.5, 0, 0
    pcall(function()
        r = brain:GetEconomyStoredRatio(t)
        inc = brain:GetEconomyIncome(t) * 10
        dem = brain:GetEconomyRequested(t) * 10
    end)
    return r, inc, dem
end

local function Dist(x1, z1, x2, z2)
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end

---------------------------------------------------------------------------------------------------
local function Scan(brain, cfg)
    local c = {
        mex = 0, mexUpg = 0, mexMin = 9, mexUnfinished = 0, massStore = 0, pgen = 0, radar = 0, aa = 0, pd = 0,
        engTotal = 0, engIdle = 0, engIdleEng = 0, facUpg = 0, mexUpgId = nil, facUpgId = nil, buildId = nil,
        fac = { land = { n = 0, best = 0, list = {} }, air = { n = 0, best = 0, list = {} }, naval = { n = 0, best = 0, list = {} } },
        army = { land = 0, fighters = 0, bombers = 0, gunships = 0, naval = 0 },
    }
    for _, u in ipairs(brain:GetListOfUnits(categories.ALLUNITS, false)) do
        if not u.Dead then
            local bpid = u:GetUnitId()
            local s = K.CatSet(bpid)
            local done = u:GetFractionComplete() >= 1
            if s.STRUCTURE then
                local kind = K.StructureKind(bpid)
                local tech = K.TechOf(bpid)
                if kind == 'mex' then
                    c.mex = c.mex + 1
                    if not done then c.mexUnfinished = c.mexUnfinished + 1 end
                    if done then
                        if u:IsUnitState('Upgrading') then
                            c.mexUpg = c.mexUpg + 1
                            if not c.mexUpgId then c.mexUpgId = tostring(u:GetEntityId()) end
                        elseif tech < c.mexMin then c.mexMin = tech end
                    end
                elseif kind == 'pgen' or kind == 'hydro' then c.pgen = c.pgen + 1
                elseif kind == 'mass_storage' then c.massStore = c.massStore + 1
                elseif kind == 'radar' or kind == 'omni' then c.radar = c.radar + 1
                elseif kind == 'aa' then c.aa = c.aa + 1
                elseif kind == 'pd' then c.pd = c.pd + 1
                elseif s.FACTORY then
                    local k = nil
                    if kind == 'land_factory' then k = 'land' elseif kind == 'air_factory' then k = 'air' elseif kind == 'naval_factory' then k = 'naval' end
                    if k then
                        local f = c.fac[k]
                        f.n = f.n + 1
                        if not done then
                            if not c.buildId then c.buildId = tostring(u:GetEntityId()) end
                        else
                            if tech > f.best then f.best = tech end
                            if u:IsUnitState('Upgrading') then
                                c.facUpg = c.facUpg + 1
                                c.facUpgId = tostring(u:GetEntityId())
                            else
                                table.insert(f.list, { id = tostring(u:GetEntityId()), queue = QueueLen(u) })
                            end
                        end
                    end
                end
            elseif done and s.COMMAND then
                if u:IsUnitState('Enhancing') then c.acuEnhId = tostring(u:GetEntityId()) end
                if u:IsIdleState() and cfg.UseACUToBuild then c.engIdle = c.engIdle + 1 end
            elseif done and s.ENGINEER and s.MOBILE then
                c.engTotal = c.engTotal + 1
                if u:IsIdleState() then c.engIdle = c.engIdle + 1 c.engIdleEng = c.engIdleEng + 1 end
            elseif done and s.MOBILE then
                local role = K.MobileRole(bpid)
                if c.army[role] then c.army[role] = c.army[role] + 1 end
            end
        end
    end
    return c
end

local function PickTarget(st, bx, bz)
    if not st then return nil end
    if st.contacts then
        for _, cl in ipairs(st.contacts) do
            if cl.structures and cl.structures > 0 then return cl.pos[1], cl.pos[2] end
        end
    end
    local bestX, bestZ, bd = nil, nil, 1e9
    if st.enemy_starts then
        for _, e in ipairs(st.enemy_starts) do
            local d = Dist(e.pos[1], e.pos[2], bx, bz)
            if d < bd then bd, bestX, bestZ = d, e.pos[1], e.pos[2] end
        end
    end
    return bestX, bestZ
end

local UnitRot = {
    land  = { 'tank', 'tank', 'tank', 'artillery', 'land_aa' },
    air   = { 'fighter', 'bomber', 'gunship', 'bomber' },
    naval = { 'warship', 'warship', 'submarine' },
}
local UnitN = { tank = 4, artillery = 2, land_aa = 2, fighter = 5, bomber = 4, gunship = 3, warship = 3, submarine = 2 }

---------------------------------------------------------------------------------------------------
function Tick(brain, cfg, now, rescue)
    local S = Actions.Strategy
    if not S.macro and not rescue then return end
    if rescue then OpeningPhase = 3 end      -- no scripted opening when rescuing LOUD

    local c = Scan(brain, cfg)
    local bx, bz = brain:GetArmyStartPos()
    local massR, massInc = Ratio(brain, 'MASS')
    local enR, enInc, enDem = Ratio(brain, 'ENERGY')
    local massStored = 0
    pcall(function() massStored = brain:GetEconomyStored('MASS') end)
    local acts = {}
    local ecoOnly = now < (cfg.EcoOnlySeconds or 0) and not Actions.Emergency
    if not ecoOnly and not Cool.ecoEnded and (cfg.EcoOnlySeconds or 0) > 0 then
        Cool.ecoEnded = 1
        Note(now, 'economy-only phase over: military, defences, factories and tech-ups now allowed')
    end
    local idleLeft = c.engIdle
    local base = { bx, bz }
    local function Add(a) table.insert(acts, a) end

    -- 0. scripted opening (only at the start of the game):
    --    ACU: land factory, then 2 power generators.
    --    Factory (when finished): 2 engineers.  Engineers (not the ACU): the first 4 mass extractors.
    if OpeningPhase < 3 then
        if not OpeningStart then OpeningStart = now end
        if OpeningPhase == 0 and now >= 3 then
            Add({ a = 'build', what = 'land_factory', n = 1, tech = 1, near = base, radius = 35, force = true })
            Add({ a = 'build', what = 'pgen', n = 2, tech = 1, near = base, radius = 25, force = true })
            OpeningPhase = 1
            Note(now, 'opening: ACU builds land factory then 2 pgen')
        elseif OpeningPhase == 1 and table.getn(c.fac.land.list) > 0 then
            Add({ a = 'produce', factory = 'land', what = 'engineer', n = 2, tech = 1 })
            OpeningPhase = 2
            Note(now, 'opening: factory built, queueing 2 engineers')
        elseif OpeningPhase == 2 and c.engTotal >= 2 then
            Add({ a = 'build', what = 'mex', n = 4, tech = 1, near = base, radius = 90, no_acu = true })
            OpeningPhase = 3
            Note(now, 'opening: 2 engineers build the first 4 mex; normal macro takes over')
        elseif now - OpeningStart > 180 then
            OpeningPhase = 3          -- something went wrong; do not stall the game
            Note(now, 'opening timed out, normal macro takes over')
        end
        if table.getn(acts) > 0 then Actions.Execute(brain, acts, cfg, true) end
        if OpeningPhase < 3 then return end
        Wait('pgen', now, 10) Wait('landfac', now, 30) Wait('mex', now, 12) Wait('eng', now, 20)
        return
    end

    -- TECH PLAN (factories only follow the mass extractors, see the tech rule below)
    local facBest = 1
    for _, k in ipairs({ 'land', 'air', 'naval' }) do
        if c.fac[k].best > facBest then facBest = c.fac[k].best end
    end
    local mexCap = math.min(S.tech, facBest + 1)
    local wantMexUp = (c.mexMin < mexCap and c.mexMin < 9)
    local facPending = false     -- a factory upgrade is about to start (all mex are at the next tier)
    if c.facUpg == 0 then
        for _, k in ipairs({ 'land', 'air', 'naval' }) do
            local f = c.fac[k]
            if f.n > 0 and f.best > 0 and f.best < S.tech and c.mexMin >= f.best + 1 then facPending = true end
        end
    end

    -- 1. energy
    local energyShort = (enInc < enDem * 1.05) or enR < 0.3 or (rescue and massR > 0.6 and enR < 0.5)
    -- rescue: energy piling up but mass short -> mass fabricators turn the spare energy into mass
    if rescue and idleLeft > 0 and enR >= 0.9 and massR < 0.5 and Ready('fab', now) then
        Add({ a = 'build', what = 'fabricator', n = 1, tech = S.tech, near = base, radius = 40, idle_only = true })
        idleLeft = idleLeft - 1
        Wait('fab', now, 20)
        Note(now, 'rescue: energy floating, building a mass fabricator')
    end
    if idleLeft > 0 and Ready('pgen', now) and (c.pgen < 2 or (energyShort and c.pgen < 40) or (facPending and enR < (cfg.TechEnergyRatio or 0.98) and c.pgen < 40)) then
        Add({ a = 'build', what = 'pgen', n = 1, tech = S.tech, near = base, radius = 40, idle_only = true })
        idleLeft = idleLeft - 1
        Wait('pgen', now, 12)
    end

    -- 2. first factory, then mass expansion
    if idleLeft > 0 and c.fac.land.n < 1 and Ready('landfac', now) then
        Add({ a = 'build', what = 'land_factory', n = 1, tech = 1, near = base, radius = 40, idle_only = true })
        idleLeft = idleLeft - 1
        Wait('landfac', now, 30)
    end
    if idleLeft > 0 and c.mex < 30 and Ready('mex', now) then
        local rad = 90
        if now > 600 then rad = 180 end
        Add({ a = 'build', what = 'mex', n = math.min(idleLeft, 3), tech = 1, near = base, radius = rad, idle_only = true })
        idleLeft = idleLeft - math.min(idleLeft, 3)
        Wait('mex', now, 10)
    end

    -- 3. more factories as the economy grows
    local boost = 0
    if massR > 0.7 and c.mex >= 8 then boost = 1 end
    local wantLand, wantAir, wantNaval = S.land_factories, S.air_factories, S.naval_factories
    if c.mex < 4 then wantLand = math.min(wantLand, 1) end
    if c.mex < 6 or now < 360 then wantAir = 0 end
    if wantLand > 0 then wantLand = wantLand + boost end
    if wantAir > 0 then wantAir = wantAir + boost end
    if idleLeft > 0 and Ready('factory', now) and not ecoOnly then
        local what = nil
        if c.fac.land.n < wantLand then what = 'land_factory'
        elseif c.fac.air.n < wantAir then what = 'air_factory'
        elseif c.fac.naval.n < wantNaval then what = 'naval_factory' end
        if what then
            Add({ a = 'build', what = what, n = 1, tech = 1, near = base, radius = 50, idle_only = true })
            idleLeft = idleLeft - 1
            Wait('factory', now, 25)
            Note(now, 'build ' .. what)
        end
    end

    -- 4. intel
    if idleLeft > 0 and not ecoOnly and now > 150 and c.radar == 0 and c.mex >= 4 and Ready('radar', now) then
        Add({ a = 'build', what = 'radar', n = 1, tech = 1, near = base, radius = 30, idle_only = true })
        idleLeft = idleLeft - 1
        Wait('radar', now, 90)
    end

    -- 5. TECH UP
    -- Rule: factories only go to the next tech level when EVERY mass extractor is already at that level
    -- (and none is still upgrading or being built). Mex only run one level ahead of the factories:
    --   all mex -> T2, then factories -> T2, then all mex -> T3, then factories -> T3.
    local mexSettled = (c.mex >= 3 and c.mexUpg == 0 and c.mexUnfinished == 0)

    local okFac = (enR >= (cfg.TechEnergyRatio or 0.98))   -- power storage full
    -- Mex upgrades (T1->T2, T2->T3): whenever a mex is below the tier the factories allow (one tier ahead of them).
    local okMex = (massR > 0.12 and enR > 0.3)
    if okMex and wantMexUp and c.mex >= 3 and c.mexUpg < math.max(1, math.floor(c.mex / 4)) and Ready('upmex', now) then
        Add({ a = 'upgrade', what = 'mex', n = 1, from_tech = c.mexMin, max_tech = mexCap })
        Wait('upmex', now, 8)
        Note(now, 'upgrade mex T' .. c.mexMin)
    end
    if okFac and mexSettled and not ecoOnly and c.facUpg == 0 and Ready('upfac', now) then
        local pick, pickTech = nil, 99
        for _, k in ipairs({ 'land', 'air', 'naval' }) do
            local f = c.fac[k]
            -- next level for this factory kind is f.best + 1; every mex must already be there
            if f.n > 0 and f.best > 0 and f.best < S.tech and c.mexMin >= f.best + 1 and f.best < pickTech then
                pick, pickTech = k, f.best
            end
        end
        if pick then
            Add({ a = 'upgrade', what = pick .. '_factory', n = 1, from_tech = pickTech, max_tech = S.tech })
            Wait('upfac', now, 20)
            Note(now, 'all mex at T' .. c.mexMin .. ' -> upgrade ' .. pick .. ' factory T' .. pickTech)
        end
    end

    -- 6. react to attacks with static defence
    local st = LastState
    if st and st.enemy_near_base and idleLeft > 0 and not ecoOnly and Ready('defense', now) then
        local nb = st.enemy_near_base
        if nb.air >= 3 and c.aa < math.min(8, 2 + math.floor(nb.air / 3)) then
            Add({ a = 'build', what = 'aa', n = 1, tech = S.tech, near = base, radius = 40, idle_only = true })
            idleLeft = idleLeft - 1 Wait('defense', now, 20)
        elseif nb.land >= 3 and c.pd < math.min(8, 2 + math.floor(nb.land / 3)) then
            Add({ a = 'build', what = 'pd', n = 1, tech = S.tech, near = base, radius = 40, idle_only = true })
            idleLeft = idleLeft - 1 Wait('defense', now, 20)
        end
    end

    -- 7. engineers
    local want = S.engineers
    if want < 1 then want = math.min(16, 4 + math.floor(c.mex / 2)) end
    if c.fac.land.n > 0 and c.engTotal < want and Ready('eng', now) and c.engIdleEng == 0 then   -- never while an engineer is idle
        Add({ a = 'produce', factory = 'land', what = 'engineer', n = math.min(2, want - c.engTotal), tech = 4 })
        Wait('eng', now, 25)
    end

    -- 8. army production: refill idle factories
    for _, k in ipairs({ 'land', 'air', 'naval' }) do
        local allowed = true
        if k == 'land' and S.army == 'air' then allowed = false end
        if k == 'air' and S.army == 'land' then allowed = false end
        if allowed and not ecoOnly then
            for _, f in ipairs(c.fac[k].list) do
                if f.queue == 0 and (k ~= 'land' or c.engTotal >= 2 or c.fac.land.n > 1) then
                    local rot = Rot[f.id] or 0
                    local list = UnitRot[k]
                    local what = list[math.mod(rot, table.getn(list)) + 1]
                    Rot[f.id] = rot + 1
                    Add({ a = 'produce', factory = f.id, what = what, n = UnitN[what] or 3, tech = 4 })
                end
            end
        end
    end

    -- 9. Idle engineers and the idle ACU ONLY assist a mass extractor upgrade or an ACU upgrade (enhancement);
    --    with nothing of that kind going on they reclaim instead.
    if idleLeft > 0 then
        local target = c.mexUpgId or c.acuEnhId
        if target then
            Add({ a = 'assist', target = target, n = math.min(idleLeft, 20) })
        elseif Ready('reclaim', now) and now > 120 then
            Add({ a = 'reclaim', near = base, radius = 60, n = math.min(idleLeft, 2) })
            Wait('reclaim', now, 30)
        end
    end

    -- 10. defend / attack waves
    if S.auto_attack and st and not ecoOnly and not rescue then
        local a = c.army
        local combat = a.land + a.fighters + a.bombers + a.gunships
        local nb = st.enemy_near_base
        local threat = 0
        if nb then threat = nb.land + nb.air + nb.naval end
        if threat > 0 and combat > 0 and Ready('defend', now) then
            Add({ a = 'attack', squad = 'land', x = bx, z = bz })
            Add({ a = 'attack', squad = 'air', x = bx, z = bz })
            Wait('defend', now, 20)
            Note(now, 'defending base (' .. threat .. ' enemies)')
        else
            local need = math.min(80, S.attack_size + 5 * WaveCount)
            if combat >= need and now - LastWave > 60 then
                local tx, tz = PickTarget(st, bx, bz)
                if tx then
                    Add({ a = 'attack', squad = 'land', x = tx, z = tz })
                    Add({ a = 'attack', squad = 'gunships', x = tx, z = tz })
                    Add({ a = 'attack', squad = 'bombers', x = tx, z = tz })
                    Add({ a = 'attack', squad = 'fighters', x = tx, z = tz })
                    LastWave = now
                    WaveCount = WaveCount + 1
                    Note(now, 'attack wave ' .. WaveCount .. ' (' .. combat .. ' units) -> ' .. math.floor(tx) .. ',' .. math.floor(tz))
                end
            end
        end
    end

    if table.getn(acts) > 0 then
        local results = Actions.Execute(brain, acts, cfg, true)
        -- back off rules that found nothing to do
        for _, r in ipairs(results) do
            if string.find(r, 'build mex', 1, true) and string.find(r, ': 0 queued', 1, true) then Wait('mex', now, 40) end
            if string.find(r, 'build radar', 1, true) and string.find(r, ': 0 queued', 1, true) then Wait('radar', now, 120) end
            if string.find(r, 'build pgen', 1, true) and string.find(r, ': 0 queued', 1, true) then Wait('pgen', now, 25) end
            if string.find(r, 'upgrade', 1, true) and string.find(r, ': 0 started', 1, true) then Wait('upmex', now, 25) Wait('upfac', now, 40) end
        end
    end
end


---------------------------------------------------------------------------------------------------
-- RESCUE (micro mode): if the built-in AI stops building - engineers/factories sit idle - while mass or energy
-- float unused, the macro manager temporarily spends the resources for it. It switches itself off again once the
-- resources are being used. The scripted opening, economy-only window, power ratio limit and mass hold are not
-- applied, and the macro never starts attack waves in this mode (LOUD plans its own attacks).
---------------------------------------------------------------------------------------------------
local StallSince, CalmSince = nil, nil
local RescueOn = false

function IsRescue() return RescueOn end

function Rescue(brain, cfg, now)
    local c = Scan(brain, cfg)
    local massR = Ratio(brain, 'MASS')
    local enR = Ratio(brain, 'ENERGY')
    local idleFac = 0
    for _, k in ipairs({ 'land', 'air', 'naval' }) do
        for _, f in ipairs(c.fac[k].list) do
            if f.queue == 0 then idleFac = idleFac + 1 end
        end
    end
    local idleBuilders = (c.engIdleEng > 0) or idleFac > 0
    local floating = massR >= (cfg.StallMassRatio or 0.7) or enR >= (cfg.StallEnergyRatio or 0.95)

    if RescueOn then
        if massR < 0.4 and enR < 0.7 then
            CalmSince = CalmSince or now
            if now - CalmSince > 10 then
                RescueOn = false
                StallSince = nil
                Note(now, 'rescue off: resources are being used again, LOUD builds on its own')
            end
        else
            CalmSince = nil
        end
    else
        if idleBuilders and floating then
            StallSince = StallSince or now
            if now - StallSince >= (cfg.StallSeconds or 20) then
                RescueOn = true
                CalmSince = nil
                Note(now, 'rescue ON: LOUD idle (' .. c.engIdleEng .. ' idle engineers, ' .. idleFac .. ' idle factories) with mass ' ..
                    math.floor(massR * 100) .. '% energy ' .. math.floor(enR * 100) .. '%')
            end
        else
            StallSince = nil
        end
    end

    if RescueOn then
        local rcfg = setmetatable({ EcoOnlySeconds = 0 }, { __index = cfg })
        Tick(brain, rcfg, now, true)
    end
    return RescueOn
end
