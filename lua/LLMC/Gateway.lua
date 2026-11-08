-- LLM Commander :: construction plans for the Quantum Gateway ACUs (SACUs).
--   defense_cluster : T3 shield, then 10 SAMs under it, then a mix of T2 artillery + T2 point defence, as many as fit under the shield
--   mass_farm       : a T3 power plant surrounded by (up to 16) T2 mass fabricators
--   experimental    : a Tech 4 unit built in the field
-- ctx = { brain, cfg, results, sacus = {units}, faction, baseX, baseZ }
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')

Farms = 0          -- mass farms started
Clusters = 0       -- defence clusters started
local ExpIdx = 0   -- rotates through the available experimentals

local function Say(ctx, msg)
    if table.getn(ctx.results) < 30 then table.insert(ctx.results, string.sub(msg, 1, 170)) end
end
local function Num(v, def, lo, hi)
    v = tonumber(v)
    if not v then return def end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end
local function Dist(x1, z1, x2, z2)
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end
local function Vec(x, z)
    local s = ScenarioInfo.size
    if s then
        x = math.max(3, math.min(s[1] - 3, x))
        z = math.max(3, math.min(s[2] - 3, z))
    end
    return { x, GetSurfaceHeight(x, z), z }
end
local function Skirt(bpid)
    local bp = __blueprints[bpid]
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
local function ParseNear(ctx, near)
    if type(near) == 'table' and tonumber(near[1]) and tonumber(near[2]) then return tonumber(near[1]), tonumber(near[2]) end
    return ctx.baseX, ctx.baseZ
end
local function Overlap(res, x, z, h)
    for _, e in ipairs(res) do
        if math.abs(e.x - x) < e.h + h and math.abs(e.z - z) < e.h + h then return true end
    end
    return false
end
local function Reserve(res, x, z, h) table.insert(res, { x = x, z = z, h = h }) end
local function CanBuild(ctx, bpid, x, z)
    return ctx.brain:CanBuildStructureAt(bpid, { x, GetSurfaceHeight(x, z), z })
end

-- First buildable, unreserved spot in a square spiral around (cx, cz).
local function Spiral(ctx, bpid, cx, cz, rmax, step, res)
    local sx, sz = Skirt(bpid)
    local h = math.max(sx, sz) / 2
    for r = 0, math.ceil(rmax / step) do
        local cand = {}
        if r == 0 then table.insert(cand, { 0, 0 })
        else
            for d = -r, r do table.insert(cand, { d, -r }) table.insert(cand, { d, r }) end
            for d = -r + 1, r - 1 do table.insert(cand, { -r, d }) table.insert(cand, { r, d }) end
        end
        for _, c in ipairs(cand) do
            local x, z = Snap(cx + c[1] * step, sx), Snap(cz + c[2] * step, sz)
            if (not Overlap(res, x, z, h)) and CanBuild(ctx, bpid, x, z) then return x, z end
        end
    end
    return nil
end

local function NeedSacus(ctx, what)
    if table.getn(ctx.sacus) == 0 then
        Say(ctx, what .. ': no gateway ACUs available (they come from the Quantum Gateway)')
        return false
    end
    return true
end

local function ShieldRadius(bpid)
    local bp = __blueprints[bpid]
    local d = bp and bp.Defense and bp.Defense.Shield and bp.Defense.Shield.ShieldSize
    if d then return d / 2 end
    return 40
end

---------------------------------------------------------------------------------------------------
-- DEFENCE CLUSTER: T3 shield -> 10 SAMs under it -> mix of T2 artillery / T2 point defence, as many as fit
---------------------------------------------------------------------------------------------------
function DefenseCluster(ctx, a)
    if not NeedSacus(ctx, 'defense_cluster') then return end
    if Clusters >= (ctx.cfg.MaxDefenseClusters or 2) and not a.again then
        return Say(ctx, 'defense_cluster: already started ' .. Clusters .. ' clusters (limit reached)')
    end
    local b = ctx.sacus[1]
    local f = ctx.faction
    local shield = K.BestBuildable(b, K.Candidates(K.Structures.shield, f), 3)
    local sam    = K.BestBuildable(b, K.Candidates(K.Structures.aa, f), 3)       -- T3 SAM launcher when available
    local arty   = K.BestBuildable(b, K.Candidates(K.Structures.arty, f), 2)     -- T2 artillery
    local pd     = K.BestBuildable(b, K.Candidates(K.Structures.pd, f), 2)       -- T2 point defence
    if not shield then return Say(ctx, 'defense_cluster: cannot build a shield generator') end

    local cx, cz = ParseNear(ctx, a.near)
    local res = {}
    local sx0, sz0 = Spiral(ctx, shield, cx, cz, 45, 3, res)
    if not sx0 then return Say(ctx, 'defense_cluster: no room for a shield generator near that point') end
    local ssx, ssz = Skirt(shield)
    Reserve(res, sx0, sz0, math.max(ssx, ssz) / 2)
    IssueBuildMobile(ctx.sacus, Vec(sx0, sz0), shield, {})

    -- grid of candidate spots inside the shield bubble, nearest to its centre first
    local R = ShieldRadius(shield) - 3
    local lim = math.floor(R)
    local cand = {}
    for dx = -lim, lim, 2 do
        for dz = -lim, lim, 2 do
            local d = math.sqrt(dx * dx + dz * dz)
            if d <= R then table.insert(cand, { dx = dx, dz = dz, d = d }) end
        end
    end
    table.sort(cand, function(p, q) return p.d < q.d end)

    local ptr = {}
    local function Place(bpid)
        local sx, sz = Skirt(bpid)
        local h = math.max(sx, sz) / 2
        local i = ptr[bpid] or 1
        local n = table.getn(cand)
        while i <= n do
            local c = cand[i]
            i = i + 1
            local x, z = Snap(sx0 + c.dx, sx), Snap(sz0 + c.dz, sz)
            if Dist(x, z, sx0, sz0) + h <= R + 1 and (not Overlap(res, x, z, h)) and CanBuild(ctx, bpid, x, z) then
                ptr[bpid] = i
                Reserve(res, x, z, h)
                IssueBuildMobile(ctx.sacus, Vec(x, z), bpid, {})
                return true
            end
        end
        ptr[bpid] = i
        return false
    end

    local nSam, nArty, nPd = 0, 0, 0
    if sam then
        for k = 1, Num(a.sams, 10, 0, 20) do
            if Place(sam) then nSam = nSam + 1 else break end
        end
    end
    local types = {}
    if arty then table.insert(types, 'arty') end
    if pd then table.insert(types, 'pd') end
    local cap, total, ti = Num(a.max_total, 40, 0, 80), 0, 1
    while table.getn(types) > 0 and total < cap do
        if ti > table.getn(types) then ti = 1 end
        local t = types[ti]
        local bp = arty
        if t == 'pd' then bp = pd end
        if Place(bp) then
            total = total + 1
            if t == 'arty' then nArty = nArty + 1 else nPd = nPd + 1 end
            ti = ti + 1
        else
            table.remove(types, ti)       -- this type no longer fits; keep filling with the other
        end
    end
    Clusters = Clusters + 1
    Say(ctx, string.format('defense_cluster at %d,%d: shield (radius %d) + %d SAM + %d T2 artillery + %d T2 PD queued',
        sx0, sz0, R, nSam, nArty, nPd))
end

---------------------------------------------------------------------------------------------------
-- MASS FARM: a T3 power plant surrounded by up to 16 T2 mass fabricators (edge-adjacent ring)
---------------------------------------------------------------------------------------------------
local function RingTiles(cx, cz, psx, psz, f)
    local hx, hz = psx / 2, psz / 2
    local out = {}
    local z = cz - (hz + f / 2)
    while z <= cz + hz + f / 2 + 0.01 do                     -- east and west sides (include corners)
        table.insert(out, { cx + hx + f / 2, z })
        table.insert(out, { cx - hx - f / 2, z })
        z = z + f
    end
    local x = cx - (hx + f / 2) + f
    while x <= cx + hx + f / 2 - f + 0.01 do                 -- north and south sides (between the corners)
        table.insert(out, { x, cz + hz + f / 2 })
        table.insert(out, { x, cz - hz - f / 2 })
        x = x + f
    end
    return out
end

function MassFarm(ctx, a)
    if not NeedSacus(ctx, 'mass_farm') then return end
    if Farms >= (ctx.cfg.MaxMassFarms or 3) and not a.again then
        return Say(ctx, 'mass_farm: already started ' .. Farms .. ' farms (limit reached)')
    end
    local b = ctx.sacus[1]
    local f = ctx.faction
    local plant, pt = K.BestBuildable(b, K.Candidates(K.Structures.pgen, f), 3)
    if not plant or pt < 3 then return Say(ctx, 'mass_farm: cannot build a T3 power generator (needs T3 engineering)') end
    local fab = K.BestBuildable(b, K.Candidates(K.Structures.fabricator, f), 2)       -- T2 mass fabricator
    if not fab then return Say(ctx, 'mass_farm: cannot build a T2 mass fabricator') end
    local want = Num(a.n, 16, 4, 24)

    local psx, psz = Skirt(plant)
    local fsx, fsz = Skirt(fab)
    local fs = math.max(fsx, fsz)
    local cx, cz = ParseNear(ctx, a.near)

    -- find the centre with the most buildable ring tiles
    local best, bestX, bestZ, bestTiles = -1, nil, nil, nil
    local tried = 0
    for r = 0, 14 do
        local cand = {}
        if r == 0 then table.insert(cand, { 0, 0 })
        else
            for d = -r, r do table.insert(cand, { d, -r }) table.insert(cand, { d, r }) end
            for d = -r + 1, r - 1 do table.insert(cand, { -r, d }) table.insert(cand, { r, d }) end
        end
        for _, c in ipairs(cand) do
            if tried < 90 then
                local x, z = Snap(cx + c[1] * 10, psx), Snap(cz + c[2] * 10, psz)
                tried = tried + 1
                if CanBuild(ctx, plant, x, z) then
                    local tiles, ok = RingTiles(x, z, psx, psz, fs), {}
                    for _, t in ipairs(tiles) do
                        if CanBuild(ctx, fab, t[1], t[2]) then table.insert(ok, t) end
                    end
                    if table.getn(ok) > best then best, bestX, bestZ, bestTiles = table.getn(ok), x, z, ok end
                end
            end
        end
        if best >= math.min(want, table.getn(RingTiles(cx, cz, psx, psz, fs))) then break end
    end
    if not bestX then return Say(ctx, 'mass_farm: no open ground for a power plant near that point') end

    IssueBuildMobile(ctx.sacus, Vec(bestX, bestZ), plant, {})      -- power plant first, so the fabricators get the adjacency
    local placed = 0
    for _, t in ipairs(bestTiles) do
        if placed >= want then break end
        IssueBuildMobile(ctx.sacus, Vec(t[1], t[2]), fab, {})
        placed = placed + 1
    end
    Farms = Farms + 1
    Say(ctx, string.format('mass_farm at %d,%d: T3 power plant + %d T2 fabricators queued (ring has room for %d)', bestX, bestZ, placed, best))
end

---------------------------------------------------------------------------------------------------
-- EXPERIMENTAL: a Tech 4 unit built in the field by the gateway ACUs
---------------------------------------------------------------------------------------------------
function Experimental(ctx, a)
    if not NeedSacus(ctx, 'experimental') then return end
    local b = ctx.sacus[1]
    local ids = {}
    if a.unit_id then
        local id = string.lower(tostring(a.unit_id))
        if __blueprints[id] and b:CanBuild(id) then table.insert(ids, id) end
    else
        local want = tostring(a.what or 'any')
        for _, id in ipairs(K.Candidates(K.Units.experimental, ctx.faction)) do
            local s = K.CatSet(id)
            local domainOk = (want == 'any' and (s.LAND or s.AIR)) or (want == 'land' and s.LAND) or (want == 'air' and s.AIR) or (want == 'naval' and s.NAVAL)
            if domainOk and b:CanBuild(id) then table.insert(ids, id) end
        end
    end
    if table.getn(ids) == 0 then return Say(ctx, 'experimental: none available to the gateway ACUs (kind: ' .. tostring(a.what or a.unit_id or 'any') .. ')') end
    ExpIdx = ExpIdx + 1
    local bpid = ids[math.mod(ExpIdx, table.getn(ids)) + 1]

    local cx, cz = ParseNear(ctx, a.near)
    local res = {}
    local x, z = Spiral(ctx, bpid, cx, cz, 80, 6, res)
    if not x then x, z = cx + 12, cz + 12 end            -- footprint check may not apply to units: just try near the point
    local n = Num(a.n, 1, 1, 4)
    for i = 1, n do IssueBuildMobile(ctx.sacus, Vec(x, z), bpid, {}) end
    Say(ctx, string.format('experimental: %d x %s queued near %d,%d', n, bpid, x, z))
end


---------------------------------------------------------------------------------------------------
-- MEX DEFENCE: a point defence and an anti-air next to mass extractors that lack them, built by the gateway ACUs
---------------------------------------------------------------------------------------------------
function MexDefense(ctx, a)
    if not NeedSacus(ctx, 'mex_defense') then return end
    local b = ctx.sacus[1]
    local f = ctx.faction
    local tech = Num(a.tech, ctx.cfg.MexDefenseTech or 2, 1, 3)
    local cover = Num(a.cover, ctx.cfg.MexDefenseCover or 20, 5, 60)
    local radius = Num(a.radius, ctx.cfg.MexDefenseRadius or 12, 4, 30)
    local wantPD, wantAA = Num(a.pd, ctx.cfg.MexDefensePD or 1, 0, 3), Num(a.aa, ctx.cfg.MexDefenseAA or 1, 0, 3)
    local pdBp = K.BestBuildable(b, K.Candidates(K.Structures.pd, f), tech)
    local aaBp = K.BestBuildable(b, K.Candidates(K.Structures.aa, f), tech)
    if not (pdBp or aaBp) then return Say(ctx, 'mex_defense: the gateway ACUs cannot build point defence or anti-air') end

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

    local res, queued, covered = {}, 0, 0
    for i = 1, math.min(Num(a.n, 3, 1, 10), table.getn(lacking)) do
        local m = lacking[i]
        local did = false
        for _, job in ipairs({ { pdBp, m.pd }, { aaBp, m.aa } }) do
            local bpid = job[1]
            if bpid then
                local sx, sz = Skirt(bpid)
                for k = 1, job[2] do
                    local x, z = Spiral(ctx, bpid, m.x, m.z, radius, 2, res)
                    if x then
                        Reserve(res, x, z, math.max(sx, sz) / 2)
                        IssueBuildMobile(ctx.sacus, Vec(x, z), bpid, {})
                        queued = queued + 1
                        did = true
                    end
                end
            end
        end
        if did then covered = covered + 1 end
    end
    Say(ctx, string.format('mex_defense: %d defence structures queued next to %d of %d mass extractors that lacked cover', queued, covered, table.getn(lacking)))
end
