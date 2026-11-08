-- LLM Commander :: unit/structure "kinds" the LLM can name, and helpers to resolve them
-- to real blueprint IDs for whatever faction (and whatever LOUD / mod units) are in the game.
--
-- Everything is matched against the blueprint's Categories *strings*, so it does not depend on
-- engine category objects and automatically includes LOUD's extra units.

FactionNames = { 'UEF', 'AEON', 'CYBRAN', 'SERAPHIM' }

-- ---------------------------------------------------------------------------------------------
-- Recipes: all = category strings that must be present, none = strings that must be absent
-- ---------------------------------------------------------------------------------------------
StructureOrder = {
    'mex', 'hydro', 'pgen', 'fabricator', 'land_factory', 'air_factory', 'naval_factory',
    'omni', 'radar', 'sonar', 'shield', 'aa', 'torpedo', 'pd', 'arty', 'mass_storage', 'energy_storage',
}

Structures = {
    mex            = { all = {'MASSEXTRACTION', 'STRUCTURE'} },
    hydro          = { all = {'HYDROCARBON', 'STRUCTURE'} },
    pgen           = { all = {'ENERGYPRODUCTION', 'STRUCTURE'}, none = {'HYDROCARBON'} },
    fabricator     = { all = {'MASSFABRICATION', 'STRUCTURE'} },
    land_factory   = { all = {'FACTORY', 'LAND', 'STRUCTURE'} },
    air_factory    = { all = {'FACTORY', 'AIR', 'STRUCTURE'} },
    naval_factory  = { all = {'FACTORY', 'NAVAL', 'STRUCTURE'} },
    omni           = { all = {'OMNI', 'STRUCTURE'} },
    radar          = { all = {'RADAR', 'STRUCTURE'}, none = {'OMNI'} },
    sonar          = { all = {'SONAR', 'STRUCTURE'} },
    shield         = { all = {'SHIELD', 'STRUCTURE'}, none = {'MOBILE'} },
    aa             = { all = {'ANTIAIR', 'DEFENSE', 'STRUCTURE'} },
    torpedo        = { all = {'ANTINAVY', 'STRUCTURE'} },
    pd             = { all = {'DIRECTFIRE', 'DEFENSE', 'STRUCTURE'} },
    arty           = { all = {'ARTILLERY', 'STRUCTURE'} },
    mass_storage   = { all = {'MASSSTORAGE', 'STRUCTURE'} },
    energy_storage = { all = {'ENERGYSTORAGE', 'STRUCTURE'} },
}

Units = {
    engineer     = { all = {'ENGINEER', 'MOBILE'}, none = {'COMMAND'} },
    land_scout   = { all = {'SCOUT', 'LAND', 'MOBILE'} },
    tank         = { all = {'MOBILE', 'LAND', 'DIRECTFIRE'}, none = {'ENGINEER', 'SCOUT', 'COMMAND', 'EXPERIMENTAL'} },
    artillery    = { all = {'MOBILE', 'LAND', 'ARTILLERY'}, none = {'EXPERIMENTAL'} },
    land_aa      = { all = {'MOBILE', 'LAND', 'ANTIAIR'} },
    air_scout    = { all = {'SCOUT', 'AIR', 'MOBILE'} },
    fighter      = { all = {'MOBILE', 'AIR', 'ANTIAIR'}, none = {'BOMBER', 'GROUNDATTACK', 'TRANSPORTATION', 'SCOUT', 'EXPERIMENTAL'} },
    bomber       = { all = {'MOBILE', 'AIR', 'BOMBER'}, none = {'EXPERIMENTAL'} },
    gunship      = { all = {'MOBILE', 'AIR', 'GROUNDATTACK'}, none = {'BOMBER', 'EXPERIMENTAL'} },
    warship      = { all = {'MOBILE', 'NAVAL'}, none = {'SUBMERSIBLE', 'ENGINEER', 'SCOUT', 'EXPERIMENTAL'} },
    submarine    = { all = {'MOBILE', 'NAVAL', 'SUBMERSIBLE'}, none = {'EXPERIMENTAL'} },
    experimental = { all = {'MOBILE', 'EXPERIMENTAL'} },
}

-- Groups of existing army units the LLM can order around ("squads"). The ACU and engineers are never in a squad.
Squads = {
    land     = { all = {'MOBILE', 'LAND'}, none = {'ENGINEER', 'SCOUT', 'TRANSPORTATION', 'COMMAND'} },
    fighters = Units.fighter,
    bombers  = Units.bomber,
    gunships = Units.gunship,
    naval    = { all = {'MOBILE', 'NAVAL'}, none = {'ENGINEER', 'SCOUT'} },
    air      = { all = {'MOBILE', 'AIR'}, none = {'TRANSPORTATION', 'SCOUT', 'ENGINEER'} },
    scouts   = { all = {'MOBILE', 'SCOUT'} },
    all      = { all = {'MOBILE'}, none = {'ENGINEER', 'TRANSPORTATION', 'COMMAND'} },
}
SquadOrder = { 'scouts', 'fighters', 'bombers', 'gunships', 'naval', 'land', 'air' }  -- first match wins

Recipes = {
    acu     = { all = {'COMMAND'} },
    sacu    = { all = {'SUBCOMMANDER', 'MOBILE'} },   -- support ACUs (built by the Quantum Gateway)
    factory = { all = {'FACTORY', 'STRUCTURE'} },
    structure = { all = {'STRUCTURE'} },
}

-- ---------------------------------------------------------------------------------------------
-- Blueprint helpers
-- ---------------------------------------------------------------------------------------------
local SetCache = {}

function CatSet(bpid)
    local s = SetCache[bpid]
    if s then return s end
    s = {}
    local bp = __blueprints[bpid]
    if bp and bp.Categories then
        for _, c in ipairs(bp.Categories) do s[c] = true end
    end
    SetCache[bpid] = s
    return s
end

function TechOf(bpid)
    local s = CatSet(bpid)
    if s.EXPERIMENTAL then return 4 end
    if s.TECH3 then return 3 end
    if s.TECH2 then return 2 end
    return 1
end

function Match(recipe, bpid)
    local s = CatSet(bpid)
    for _, n in ipairs(recipe.all) do
        if not s[n] then return false end
    end
    if recipe.none then
        for _, n in ipairs(recipe.none) do
            if s[n] then return false end
        end
    end
    return true
end

-- Returns the live units from `list` that match the recipe.
function Select(list, recipe)
    local out = {}
    for _, u in ipairs(list) do
        if not u.Dead and Match(recipe, u:GetUnitId()) then table.insert(out, u) end
    end
    return out
end

local KindCache = {}
-- Which structure kind (e.g. 'mex') a blueprint is, or 'other'.
function StructureKind(bpid)
    local k = KindCache['s' .. bpid]
    if k then return k end
    k = 'other'
    for _, name in ipairs(StructureOrder) do
        if Match(Structures[name], bpid) then k = name break end
    end
    KindCache['s' .. bpid] = k
    return k
end

-- Which squad role a mobile blueprint is ('land','air','naval','scouts',...) or 'other'.
function MobileRole(bpid)
    local k = KindCache['m' .. bpid]
    if k then return k end
    k = 'other'
    for _, name in ipairs(SquadOrder) do
        if Match(Squads[name], bpid) then k = name break end
    end
    KindCache['m' .. bpid] = k
    return k
end

-- ---------------------------------------------------------------------------------------------
-- Candidate lookup (all blueprint IDs of a faction matching a recipe) and build resolution
-- ---------------------------------------------------------------------------------------------
local AllIds = nil
local function GetAllIds()
    if AllIds then return AllIds end
    AllIds = {}
    for id, bp in pairs(__blueprints) do
        if type(id) == 'string' and bp.Categories and bp.Economy and bp.Economy.BuildCostMass then
            table.insert(AllIds, id)
        end
    end
    table.sort(AllIds)
    return AllIds
end

local CandCache = {}
function Candidates(recipe, factionIndex)
    local key = tostring(recipe) .. ':' .. tostring(factionIndex)
    local c = CandCache[key]
    if c then return c end
    c = {}
    local fname = FactionNames[factionIndex]
    for _, id in ipairs(GetAllIds()) do
        if Match(recipe, id) and ((not fname) or CatSet(id)[fname]) then table.insert(c, id) end
    end
    CandCache[key] = c
    return c
end

-- Highest-tech candidate (<= tech) the builder can actually build right now.
function BestBuildable(builder, cands, tech)
    local best, bestT = nil, 0
    for _, id in ipairs(cands) do
        local t = TechOf(id)
        if t <= tech and t > bestT and builder:CanBuild(id) then best, bestT = id, t end
    end
    return best, bestT
end

-- Sorted list of tech levels at which any of `builders` can build something from `cands`.
function TechsFor(builders, cands)
    local seenBp, has = {}, {}
    for _, b in ipairs(builders) do
        local bid = b:GetUnitId()
        if not seenBp[bid] then
            seenBp[bid] = true
            for _, id in ipairs(cands) do
                if b:CanBuild(id) then has[TechOf(id)] = true end
            end
        end
    end
    local out = {}
    for t = 1, 4 do if has[t] then table.insert(out, t) end end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Resource markers: { {x, z}, ... }  ('Mass' or 'Hydrocarbon')
-- ---------------------------------------------------------------------------------------------
local MarkerCache = {}
function Markers(markerType)
    if MarkerCache[markerType] then return MarkerCache[markerType] end
    local list = {}
    local ok = pcall(function()
        local all = import('/lua/sim/ScenarioUtilities.lua').GetMarkers()
        for _, m in pairs(all) do
            if m.type == markerType and m.position then
                table.insert(list, { m.position[1], m.position[3] })
            end
        end
    end)
    if not ok then LOG('LLMC|I|WARN could not read resource markers') end
    MarkerCache[markerType] = list
    return list
end


---------------------------------------------------------------------------------------------------
-- "Effectively idle": the engine says a unit is busy (it has a command) but it does nothing useful.
-- An ASSIST (Guard) order never ends by itself: when the unit it helps finishes or stops, the helper stands there forever,
-- still "busy" for the engine, and every build order queued behind the dead Guard order never starts.
---------------------------------------------------------------------------------------------------
local WorkStates = { 'Building', 'Repairing', 'Reclaiming', 'Capturing', 'Upgrading', 'Enhancing', 'Attacking', 'Moving', 'Patrolling', 'Sacrificing' }

function EffectivelyIdle(u)
    if u:IsIdleState() then return true end
    local focus = nil
    pcall(function() focus = u:GetFocusUnit() end)       -- what it is building / the real construction it is helping with
    if focus and not focus.Dead then return false end
    for _, name in ipairs(WorkStates) do
        local ok, v = pcall(function() return u:IsUnitState(name) end)
        if ok and v then return false end
    end
    return true
end

StaleSince = {}          -- entity id -> game time it was first seen "busy but doing nothing"

-- Clears the commands of units that have been busy-but-doing-nothing for `secs` seconds. Returns how many were cleared.
function ClearStale(units, now, secs)
    local clear = {}
    for _, u in ipairs(units) do
        if not u.Dead then
            local id = tostring(u:GetEntityId())
            if (not u:IsIdleState()) and EffectivelyIdle(u) then
                local t = StaleSince[id]
                if not t then
                    StaleSince[id] = now
                elseif now - t >= (secs or 6) then
                    table.insert(clear, u)
                    StaleSince[id] = nil
                end
            else
                StaleSince[id] = nil
            end
        end
    end
    if table.getn(clear) > 0 then IssueClearCommands(clear) end
    return table.getn(clear)
end
