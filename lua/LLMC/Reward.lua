-- LLM Commander :: reward function for TRAIN mode.
-- Event rewards come from the Unit hook (hook/lua/sim/Unit.lua); economy rewards from EcoTick (called by the controller).
--   destroy enemy unit +3 | enemy Tech 4 +6 | killed by an artillery installation +4 | killed by a nuke +8
--   produce unit +2 | produce Tech 4 unit +8
--   mass AND power storage above 30% +2 | power storage full +3 | mass storage >= 80% +4
--   mass wasted -6 | power under 20% -2 | power at 0 -4 | mass at 0 -4
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
end

function Stop() Active = false end

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
                rules = { win = WinR, loss = LossR, timeout = TimeoutR, economy_scale = EcoScale, economy_cap = EcoCapNow(), time_per_minute = -TimeRate, time_penalty_cap = -TimeCap,
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
    local s = K.CatSet(unit:GetUnitId())
    if (not s.MOBILE) or s.COMMAND then return end
    if s.EXPERIMENTAL then Add('built_t4', 8) else Add('built_unit', 2) end
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

-- economy shaping, evaluated every Config.TrainEcoInterval game seconds
function EcoTick(brain, now)
    if not Active then return end
    CapNow = EcoCap * (1 + math.floor((now or 0) / 1800))      -- the cap grows by EcoRewardCap for every 30 minutes of play
    local mr, er, mInc, mDem = 0.5, 0.5, 0, 0
    pcall(function()
        mr = brain:GetEconomyStoredRatio('MASS')
        er = brain:GetEconomyStoredRatio('ENERGY')
        mInc = brain:GetEconomyIncome('MASS') * 10
        mDem = brain:GetEconomyRequested('MASS') * 10
    end)
    -- penalties (full value)
    if mr <= 0.005 then Add('mass_zero', -4) end
    if mr >= 0.99 and mInc > mDem then Add('mass_waste', -6) end
    if er <= 0.005 then Add('power_zero', -4)
    elseif er < 0.2 then Add('power_low', -2) end
    -- positive economy rewards (scaled and capped)
    if mr >= 0.8 then AddEco('mass_high', 4) end
    if er >= 0.99 then AddEco('power_full', 3) end
    if mr > 0.3 and er > 0.3 then AddEco('storage_ok', 2) end
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
