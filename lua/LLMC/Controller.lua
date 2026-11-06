-- LLM Commander :: game-side controller.
--   * picks which army the LLM plays
--   * every Config.StateInterval seconds writes an observation to the game log (LLMC|S|... lines)
--   * polls bridge/inbox.lua for the LLM's reply and executes it
-- Lua 5.0 style: no '#', no '%'.

local Json    = import('/mods/LLMCommander/lua/LLMC/Json.lua')
local Cfg     = import('/mods/LLMCommander/lua/LLMC/Config.lua').Config
local State   = import('/mods/LLMCommander/lua/LLMC/State.lua')
local Actions = import('/mods/LLMCommander/lua/LLMC/Actions.lua')
local Macro   = import('/mods/LLMCommander/lua/LLMC/Macro.lua')
local Micro   = import('/mods/LLMCommander/lua/LLMC/Micro.lua')
local Reward  = import('/mods/LLMCommander/lua/LLMC/Reward.lua')

local Started = false
local TargetName = nil

-- Which army does the LLM play?
function PickArmyName()
    if TargetName then return TargetName end
    if type(Cfg.Army) == 'number' then
        TargetName = 'ARMY_' .. Cfg.Army
        return TargetName
    end
    local best, bestN = nil, -1
    for name, setup in pairs(ScenarioInfo.ArmySetup) do
        local isAI = setup.AIPersonality and setup.AIPersonality ~= ''
        local n = tonumber(string.sub(name, 6))     -- 'ARMY_3' -> 3
        if isAI and n and n > bestN then best, bestN = name, n end
    end
    TargetName = best
    return best
end

-- Called from the aibrain hook: should this brain's built-in AI be switched off?
function ShouldTakeOver(brain)
    if Cfg.Takeover ~= 'replace' and Cfg.Takeover ~= 'train' then return false end
    return brain.Name == PickArmyName()
end

local function ReadInbox()
    local env = {}   -- empty environment: the inbox file can only assign a table, nothing else
    local ok = pcall(doscript, Cfg.BridgeDir .. 'inbox.lua', env)
    if not ok then return nil end
    if type(env.LLMC_INBOX) ~= 'table' then return nil end
    return env.LLMC_INBOX
end

function Main()
    WaitSeconds(3)
    local name = PickArmyName()
    if not name then
        LOG('LLMC|I|ERR no AI slot found for the LLM. Add an AI player in the lobby (or set Config.Army).')
        return
    end
    local brain = nil
    for _, b in ipairs(ArmyBrains) do
        if b.Name == name then brain = b end
    end
    if not brain then LOG('LLMC|I|ERR army ' .. name .. ' does not exist') return end

    -- MODE: 'micro'   = the built-in AI plays, the LLM micro-manages combat units (default)
    --       'replace' = the built-in AI is switched off, the LLM + macro manager play
    local micro = (Cfg.Takeover == 'micro' or Cfg.Takeover == 'army' or Cfg.Takeover == 'sacu')
    --       'train'   = like 'replace' but NO macro manager and NO rule gates: the LLM plays the whole game and
    --                   learns from the reward function (Reward.lua). The episode ends when an army is destroyed.
    local train = (Cfg.Takeover == 'train')
    local xcfg = Cfg
    if train then
        xcfg = setmetatable({ EcoOnlySeconds = 0, MinMassRatio = 0, MinEnergyRatio = 0, FreeRules = true, Macro = false },
                            { __index = Cfg })
    end
    local exec = Actions.Execute
    if micro then exec = Micro.Execute end

    if (Cfg.Takeover == 'replace' or train) and not brain.LLMControlled then
        LOG('LLMC|I|WARN aibrain hook did not run for ' .. name .. '; the built-in AI is probably still active (overlay mode).')
    end

    local sid = math.floor(Random() * 1000000) + 1
    local seq, lastExec, lastSent, nextSend = 0, 0, -1000, 0
    local pending = false
    local nextMacro = 0
    local S = Actions.Strategy
    S.macro, S.auto_attack, S.tech = Cfg.Macro, Cfg.AutoAttack, Cfg.TechTarget
    if train then S.macro = false S.auto_attack = false end
    local nextEco = 0
    local idx = brain:GetArmyIndex()
    if train then Reward.Reset(idx, Cfg) end
    S.attack_size, S.land_factories, S.air_factories = Cfg.AttackSize, Cfg.LandFactories, Cfg.AirFactories
    local lastResults = {}
    LOG('LLMC|I|START|' .. sid)
    LOG('LLMC|I|INFO controlling ' .. name .. ' (' .. tostring(brain.Nickname) .. ') mode=' .. tostring(Cfg.Takeover))

    while true do
        local now = GetGameTimeSeconds()

        -- finished / dead?
        local out = false
        pcall(function() out = ArmyIsOutOfGame(idx) end)
        if train then
            -- TERMINAL CONDITION: a training step (episode) ends when an army is destroyed
            local result = nil
            if out then
                result = 'loss'
            else
                local anyOut, allOut, n = false, true, 0
                for i, _ in ipairs(ArmyBrains) do
                    local civ = false
                    pcall(function() civ = ArmyIsCivilian(i) end)
                    if i ~= idx and (not civ) and IsEnemy(idx, i) then
                        n = n + 1
                        local o = false
                        pcall(function() o = ArmyIsOutOfGame(i) end)
                        if o then anyOut = true else allOut = false end
                    end
                end
                if n > 0 and ((Cfg.TrainEndOnAnyArmy and anyOut) or allOut) then result = 'win' end
                if (not result) and now >= (Cfg.TrainMaxSeconds or 3600) then result = 'timeout' end
            end
            if result then
                Reward.Terminal(result, now)
                local last = Reward.PopStep()
                local sum = Reward.Summary()
                sum.result = result
                sum.time = math.floor(now)
                sum.last_step = last.step
                Reward.Stop()
                LOG('LLMC|I|EPISODE_END|' .. result .. '|' .. math.floor(sum.total) .. '|' .. math.floor(now))
                LOG('LLMC|I|EPISODE HAS ENDED (' .. result .. ', reward ' .. math.floor(sum.total) .. ', ' .. math.floor(now) .. ' game seconds). The bridge is saving the playbook - START A NEW GAME to continue training.')
                Json.LogChunks('E', seq + 1, Json.Encode(sum))
                if Cfg.AutoRestart ~= false then
                    -- wait until the bridge has reflected on the episode and saved the playbook, THEN restart the match
                    -- (the next match must start with the updated lessons). The bridge signals with inbox.restart = true.
                    LOG('LLMC|I|Waiting for the bridge to save the playbook before restarting the match (up to ' .. (Cfg.RestartWaitSeconds or 900) .. ' s)...')
                    local waited, go = 0, false
                    while waited < (Cfg.RestartWaitSeconds or 900) do
                        local box = ReadInbox()
                        if box and box.sid == sid and box.restart then go = true break end
                        if math.mod(waited, 30) == 29 then
                            LOG('LLMC|I|still waiting for the bridge (inbox sid=' .. tostring(box and box.sid) .. ' expected ' .. tostring(sid) ..
                                ', restart=' .. tostring(box and box.restart) .. ')')
                        end
                        WaitSeconds(1)
                        waited = waited + 1
                    end
                    if go then
                        LOG('LLMC|I|Playbook saved - asking the UI to restart the match with RestartSession().')
                        -- Sync fields last only one tick, so keep asking for a while in case a tick was missed
                        for i = 1, 20 do
                            Sync.LLMC_Restart = true
                            WaitSeconds(1)
                        end
                    else
                        LOG('LLMC|I|WARN no restart signal from the bridge within the time limit; the match was NOT restarted. Start a new game manually.')
                    end
                end
                return
            end
            if now >= nextEco then
                nextEco = now + (Cfg.TrainEcoInterval or 10)
                pcall(Reward.EcoTick, brain, now)
            end
        elseif out then
            LOG('LLMC|I|END')
            return
        end


        -- 1. collect the LLM's reply
        local box = ReadInbox()
        if box and box.sid == sid and type(box.seq) == 'number' and box.seq > lastExec and box.seq <= seq then
            lastExec = box.seq
            local ok, results, count = pcall(exec, brain, box.actions or {}, xcfg)
            if ok then
                lastResults = results
                local joined = ''
                for _, r in ipairs(results) do joined = joined .. r .. ' ; ' end
                LOG('LLMC|I|RESULTS turn ' .. tostring(box.seq) .. ': ' .. string.sub(joined, 1, 900))
            else
                lastResults = { 'executor error: ' .. tostring(results) }
                WARN('LLMC executor error: ' .. tostring(results))
            end
            if type(box.warnings) == 'table' then
                for _, w in ipairs(box.warnings) do
                    if table.getn(lastResults) < 40 then table.insert(lastResults, 'bridge: ' .. tostring(w)) end
                end
            end
            LOG('LLMC|A|' .. box.seq .. '|' .. tostring(count))
            pending = false
        end

        -- 1b. automatic macro (eco, tech, production, waves) - independent of LLM latency
        if micro then
            pcall(Micro.Maintain, brain, Cfg, now)
            if now >= nextMacro then
                nextMacro = now + Cfg.MacroInterval
                if Cfg.Rescue ~= false and Cfg.Takeover ~= 'sacu' then      -- sacu mode: nothing but the gateway ACUs is touched
                    local rok, rerr = pcall(Macro.Rescue, brain, Cfg, now)
                    if not rok then WARN('LLMC rescue error: ' .. tostring(rerr)) end
                end
                local aok, aerr = pcall(Micro.Auto, brain, Cfg, now)
                if not aok then WARN('LLMC gateway auto error: ' .. tostring(aerr)) end
            end
        elseif (not train) and now >= nextMacro then
            nextMacro = now + Cfg.MacroInterval
            local mok, merr = pcall(Macro.Tick, brain, Cfg, now)
            if not mok then WARN('LLMC macro error: ' .. tostring(merr)) end
        end

        -- 2. send a new observation
        if (not pending and now >= nextSend) or (pending and now - lastSent > Cfg.ResendAfter) then
            seq = seq + 1
            local ok, st = pcall(micro and Micro.BuildState or State.Build, brain, xcfg, seq, sid, now, lastResults)
            if ok then
                if micro then
                    st.rescue_active = Macro.IsRescue()
                    st.macro_recent = Macro.Recent
                    Macro.SetState(st)
                elseif train then
                    st.mode = 'train'
                    st.reward = Reward.PopStep()
                    local since = Reward.SecondsSinceCombat(now)
                    if st.alerts and now >= (Cfg.NoCombatGrace or 240) and since > (Cfg.NoCombatWindow or 90) then
                        table.insert(st.alerts, 'NO COMBAT UNITS finished for ' .. math.floor(since) .. ' s - this costs ' .. (Cfg.NoCombatPenalty or -2) ..
                            ' reward every 10 s. Queue combat units (tank / fighter / bomber / gunship / warship) in EVERY idle factory now (n=10 batches); build a factory if you have none')
                    end
                else
                    st.strategy = Actions.Strategy
                    local nb = st.enemy_near_base
                    Actions.Emergency = (Cfg.EcoOnlyEmergency and nb and (nb.land + nb.air + nb.naval) >= 4) and true or false
                    if now < Cfg.EcoOnlySeconds and not Actions.Emergency then
                        st.economy_only_until = Cfg.EcoOnlySeconds
                    end
                    st.macro_recent = Macro.Recent
                    Macro.SetState(st)
                end
                Json.LogChunks('S', seq, Json.Encode(st))
                pending = true
                lastSent = now
                nextSend = now + (micro and (Cfg.MicroInterval or 8) or Cfg.StateInterval)
                lastResults = {}
            else
                WARN('LLMC state error: ' .. tostring(st))
                LOG('LLMC|I|ERR state build failed: ' .. tostring(st))
                nextSend = now + 10
            end
        end

        WaitSeconds(1)
    end
end

function Start()
    if Started then return end
    Started = true
    ForkThread(Main)
end
