-- LLM Commander :: reward function for TRAIN mode.
-- Event rewards come from the Unit hook (hook/lua/sim/Unit.lua); economy rewards from EcoTick (called by the controller).
--   destroy enemy unit +3 | enemy Tech 4 +6 | killed by an artillery installation +4 | killed by a nuke +8
--   produce unit +2 | produce Tech 4 unit +8
--   ECONOMY (follows the wiki): mass income +0.4 per M/s | power supply >= demand +3 | storage buffer 30-95% +2 | mex upgraded to T2 +10, T3 +20
--   stalls: mass at 0 -4 | power at 0 -4 | power under 20% -2;  waste: mass overflow -6 (power overflow is normal and NOT penalised)
--   WIN +500 (+ up to +300 speed bonus, none after 2 h) | LOSS -500 | TIMEOUT -250 | time -5/min (at most -250 in total)
--   the positive economy rewards are x0.25 and capped at 300 per 30 minutes of play
--   lose a unit -1 | lose a building -3 | lose a mass extractor -4
-- Lua 5.0 style: no '#', no '%'.

local K = import('/mods/LLMCommander/lua/LLMC/Kinds.lua')

Active = false
OurIdx = 0
KillMode = 'max'          -- 'max': a kill is worth the highest applicable value; 'sum': the applicable values add up
EpTotal = 0
StepSum = 0
EcoPos = 0                -- positive economy reward collected so far this episode
WinR, LossR, TimeoutR, EcoScale, EcoCap, TimeRate, TickLen = 500, -500, -250, 0.25, 300, 5, 10
TimeCap, TimePaid, SpeedBonus, SpeedHorizon, CapNow = 250, 0, 300, 7200, 300
IncomeMass, PowerBalancedR, BufferR, MexT2R, MexT3R = 0.4, 3, 2, 10, 20
CombatR, CombatRate, CombatCap, CombatWindow, DefR, DefCap, DefPaid = 2, 0.5, 10, 60, 3, 150, 0
CombatTimes = {}          -- game times at which our recent combat units finished (for the production-RATE bonus)
NoCombatPenalty, NoCombatGrace, NoCombatWindow, NoCombatCap, NoCombatPaid, LastCombat = -2, 240, 90, 300, 0, -1
Totals = {}               -- reward name -> total this episode
Counts = {}               -- reward name -> how many times this episode
StepParts = {}            -- reward name -> total since the last observation

function Reset(idx, cfg)
    Active = true
    OurIdx = idx
    KillMode = cfg.RewardMode or 'max'
    EpTotal, StepSum, EcoPos, TimePaid = 0, 0, 0, 0
    Totals, Counts, StepParts = {}, {}, {}
    WinR, LossR, TimeoutR = cfg.WinReward or 500, cfg.LossReward or -500, cfg.TimeoutReward or -250
    EcoScale, EcoCap = cfg.EcoRewardScale or 0.25, cfg.EcoRewardCap or 300
    TimeRate, TickLen = cfg.TimePenaltyPerMinute or 5, cfg.TrainEcoInterval or 10
    TimeCap, SpeedBonus, SpeedHorizon = cfg.TimePenaltyCap or 250, cfg.WinSpeedBonus or 300, cfg.WinSpeedHorizon or 7200
    CapNow = EcoCap
    IncomeMass, PowerBalancedR, BufferR = cfg.IncomeRewardPerMass or 0.4, cfg.PowerBalancedReward or 3, cfg.HealthyBufferReward or 2
    MexT2R, MexT3R = cfg.MexUpgradeRewardT2 or 10, cfg.MexUpgradeRewardT3 or 20
    CombatR, CombatRate, CombatCap, CombatWindow = cfg.CombatUnitReward or 2, cfg.CombatRateBonus or 0.5, cfg.CombatRateCap or 10, cfg.CombatRateWindow or 60
    DefR, DefCap, DefPaid = cfg.DefenseBuiltReward or 3, cfg.DefenseRewardCap or 150, 0
    CombatTimes = {}
    NoCombatPenalty, NoCombatGrace, NoCombatWindow, NoCombatCap = cfg.NoCombatPenalty or -2, cfg.NoCombatGrace or 240, cfg.NoCombatWindow or 90, cfg.NoCombatCap or 300
    NoCombatPaid, LastCombat = 0, -1
end

function Stop() Active = false end

-- seconds since the last combat unit finished (or since the start if none yet)
function SecondsSinceCombat(now)
    if LastCombat < 0 then return now or 0 end
    return (now or 0) - LastCombat
end

local function Add(name, v)
    if not Active then return end
    EpTotal = EpTotal + v
    StepSum = StepSum + v
    Totals[name] = (Totals[name] or 0) + v
    Counts[name] = (Counts[name] or 0) + 1
    StepParts[name] = (StepParts[name] or 0) + v
end

-- returns the reward collected since the previous call, and resets the step counters
local function EcoCapNow() return CapNow end

function PopStep()
    local r = { step = StepSum, parts = StepParts, episode_total = EpTotal,
                rules = { win = WinR, loss = LossR, timeout = TimeoutR, economy_scale = EcoScale, economy_cap = EcoCapNow(),
                          no_combat_penalty = NoCombatPenalty, no_combat_after_s = NoCombatGrace, combat_unit_base = CombatR, combat_rate_bonus_per_recent_unit = CombatRate, combat_rate_window_s = CombatWindow, defense_per_tier = DefR, mass_income_per_mass_per_s = IncomeMass * EcoScale, time_per_minute = -TimeRate, time_penalty_cap = -TimeCap,
                          win_speed_bonus = SpeedBonus, win_speed_horizon = SpeedHorizon } }
    StepSum = 0
    StepParts = {}
    return r
end

function Summary()
    return { total = EpTotal, parts = Totals, counts = Counts }
end

-- victim died; instigator = the unit (or projectile) that dealt the killing damage
function OnUnitKilled(victim, instigator)
    if not Active then return end
    local vArmy = victim:GetArmy()
    local vs = K.CatSet(victim:GetUnitId())
    if vs.WALL then return end

    if vArmy == OurIdx then
        if victim:GetFractionComplete() < 1 then return end       -- cancelled / unfinished: not a loss
        if vs.STRUCTURE then
            if vs.MASSEXTRACTION then Add('lost_mex', -4) else Add('lost_building', -3) end
        else
            Add('lost_unit', -1)
        end
        return
    end

    local killer = instigator
    if killer and (not killer.GetArmy) and killer.Launcher then killer = killer.Launcher end   -- projectile -> its launcher
    if not (killer and killer.GetArmy and killer:GetArmy() == OurIdx) then return end
    if not IsEnemy(OurIdx, vArmy) then return end
    if victim:GetFractionComplete() < 1 then return end

    local ks = K.CatSet(killer:GetUnitId())
    local name, value = 'kill', 3
    local function Consider(n, v)
        if KillMode == 'sum' then name, value = n, value + v
        elseif v > value then name, value = n, v end
    end
    if vs.EXPERIMENTAL then Consider('kill_t4', 6) end
    if ks.ARTILLERY and ks.STRUCTURE then Consider('kill_artillery', 4) end
    if ks.NUKE then Consider('kill_nuke', 8) end
    Add(name, value)
end

-- one of our units finished construction
function OnBuilt(unit)
    if not Active then return end
    if unit:GetArmy() ~= OurIdx then return end
    local bpid = unit:GetUnitId()
    local s = K.CatSet(bpid)
    if s.STRUCTURE then
        -- a mass extractor that finished at tier 2/3 is an UPGRADE (engineers cannot build T2/T3 mex directly): it multiplies the mass income
        if s.MASSEXTRACTION then
            local t = K.TechOf(unit:GetUnitId())
            if t == 2 then Add('mex_upgrade', MexT2R) elseif t >= 3 then Add('mex_upgrade', MexT3R) end
        end
        -- DEFENCE STRUCTURES (point defence, anti-air, torpedo, shield): DefenseBuiltReward x tier (T1 3, T2 6, T3 9),
        -- at most DefenseRewardCap per 30 minutes of play so defence spam cannot become the point of the game
        local kind = K.StructureKind(bpid)
        if kind == 'pd' or kind == 'aa' or kind == 'torpedo' or kind == 'shield' then
            local now = GetGameTimeSeconds()
            local v = DefR * math.min(3, K.TechOf(bpid))
            local room = DefCap * (1 + math.floor(now / 1800)) - DefPaid
            if v > room then v = room end
            if v > 0 then
                DefPaid = DefPaid + v
                Add('defense_built', v)
            end
        end
        return
    end
    if (not s.MOBILE) or s.COMMAND then return end
    if s.EXPERIMENTAL then Add('built_t4', 8) else Add('built_unit', 2) end

    -- COMBAT UNITS: an extra reward that grows with the production RATE - every combat unit finished is worth
    -- CombatUnitReward + CombatRateBonus x (combat units finished in the previous CombatRateWindow seconds, max CombatRateCap).
    -- Trickling units out pays little; keeping several factories busy pays a lot.
    local role = K.MobileRole(bpid)
    if role == 'land' or role == 'fighters' or role == 'bombers' or role == 'gunships' or role == 'naval' or role == 'air' then
        local now = GetGameTimeSeconds()
        LastCombat = now
        local fresh = {}
        for _, t in ipairs(CombatTimes) do
            if now - t <= CombatWindow then table.insert(fresh, t) end
        end
        local recent = table.getn(fresh)
        table.insert(fresh, now)
        CombatTimes = fresh
        Add('combat_unit', CombatR + CombatRate * math.min(recent, CombatCap))
    end
end

-- A positive economy reward, scaled by EcoRewardScale and limited by EcoRewardCap per episode (so economy points
-- guide the play but can never outweigh winning).
local function AddEco(name, v)
    v = v * EcoScale
    local room = EcoCap - EcoPos
    if room <= 0 then return end
    if v > room then v = room end
    EcoPos = EcoPos + v
    Add(name, v)
end

-- Economy rewards, evaluated every Config.TrainEcoInterval game seconds. They follow how the economy works (supcom wiki):
--   * income is what wins games ("time is everything"): reward mass income, and upgrading extractors (an upgrade triples a mex)
--   * running out of a resource halts construction (an energy shortage also switches off radar and shields): penalties
--   * anything generated beyond storage is wasted: penalties; stockpiles are only a buffer, so a big hoard is not rewarded
function EcoTick(brain, now)
    if not Active then return end
    CapNow = EcoCap * (1 + math.floor((now or 0) / 1800))      -- the cap grows by EcoRewardCap for every 30 minutes of play
    local mr, er, mInc, mDem, eInc, eDem = 0.5, 0.5, 0, 0, 0, 0
    pcall(function()
        mr = brain:GetEconomyStoredRatio('MASS')
        er = brain:GetEconomyStoredRatio('ENERGY')
        mInc = brain:GetEconomyIncome('MASS') * 10          -- per second
        mDem = brain:GetEconomyRequested('MASS') * 10
        eInc = brain:GetEconomyIncome('ENERGY') * 10
        eDem = brain:GetEconomyRequested('ENERGY') * 10
    end)
    -- STALLS (full value): construction halts at 0; no power also shuts down radar and shield generators
    if mr <= 0.005 then Add('mass_zero', -4) end
    if er <= 0.005 then Add('power_zero', -4)
    elseif er < 0.2 then Add('power_low', -2) end
    -- WASTE (full value): mass that does not fit into storage is lost. Power overflow is normal (power income is far larger
    -- than mass income: +1000 energy against +1 mass is fine) and is NOT penalised.
    if mr >= 0.99 and mInc > mDem then Add('mass_waste', -6) end
    -- POSITIVE (scaled and capped): income wins games
    if mInc > 0 then AddEco('mass_income', IncomeMass * mInc) end
    if er > 0.05 and eInc >= eDem then AddEco('power_balanced', PowerBalancedR) end          -- supply meets demand
    if mr > 0.3 and er > 0.3 and mr < 0.95 then AddEco('storage_ok', BufferR) end     -- a buffer: mass in stock but not overflowing; power may sit full
    -- NO ARMY: after the grace period, every economy tick in which no combat unit finished during the last NoCombatWindow
    -- seconds is punished (at most NoCombatCap per 30 minutes of play). You cannot win without an army.
    if (now or 0) >= NoCombatGrace and SecondsSinceCombat(now) > NoCombatWindow then
        local cost = -NoCombatPenalty
        local room = NoCombatCap * (1 + math.floor((now or 0) / 1800)) - NoCombatPaid
        if cost > room then cost = room end
        if cost > 0 then
            NoCombatPaid = NoCombatPaid + cost
            Add('no_combat', -cost)
        end
    end
    -- time pressure: a faster win is better than a slow one
    if TimeRate > 0 and TimePaid < TimeCap then
        local v = TimeRate * TickLen / 60
        if TimePaid + v > TimeCap then v = TimeCap - TimePaid end
        TimePaid = TimePaid + v
        Add('time', -v)
    end
end

-- End of episode: the big reward. result = 'win' | 'loss' | 'timeout'
function Terminal(result, now)
    if not Active then return end
    if result == 'win' then
        Add('win', WinR)
        -- speed bonus: the longer a game runs the tougher the opponent gets, so an early win is worth more
        local bonus = SpeedBonus * (1 - (now or 0) / SpeedHorizon)
        if bonus > 0.5 then Add('win_speed', bonus) end
    elseif result == 'loss' then Add('loss', LossR)
    else Add('timeout', TimeoutR) end
end
