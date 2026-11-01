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
    if Cfg.Takeover ~= 'replace' then return false end
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
    local exec = Actions.Execute
    if micro then exec = Micro.Execute end

    if Cfg.Takeover == 'replace' and not brain.LLMControlled then
        LOG('LLMC|I|WARN aibrain hook did not run for ' .. name .. '; the built-in AI is probably still active (overlay mode).')
    end

    local sid = math.floor(Random() * 1000000) + 1
    local seq, lastExec, lastSent, nextSend = 0, 0, -1000, 0
    local pending = false
    local nextMacro = 0
    local S = Actions.Strategy
    S.macro, S.auto_attack, S.tech = Cfg.Macro, Cfg.AutoAttack, Cfg.TechTarget
    S.attack_size, S.land_factories, S.air_factories = Cfg.AttackSize, Cfg.LandFactories, Cfg.AirFactories
    local lastResults = {}
    LOG('LLMC|I|START|' .. sid)
    LOG('LLMC|I|INFO controlling ' .. name .. ' (' .. tostring(brain.Nickname) .. ') mode=' .. tostring(Cfg.Takeover))

    while true do
        local now = GetGameTimeSeconds()

        -- finished / dead?
        local out = false
        pcall(function() out = ArmyIsOutOfGame(brain:GetArmyIndex()) end)
        if out then LOG('LLMC|I|END') return end


        -- 1. collect the LLM's reply
        local box = ReadInbox()
        if box and box.sid == sid and type(box.seq) == 'number' and box.seq > lastExec and box.seq <= seq then
            lastExec = box.seq
            local ok, results, count = pcall(exec, brain, box.actions or {}, Cfg)
            if ok then
                lastResults = results
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
        elseif now >= nextMacro then
            nextMacro = now + Cfg.MacroInterval
            local mok, merr = pcall(Macro.Tick, brain, Cfg, now)
            if not mok then WARN('LLMC macro error: ' .. tostring(merr)) end
        end

        -- 2. send a new observation
        if (not pending and now >= nextSend) or (pending and now - lastSent > Cfg.ResendAfter) then
            seq = seq + 1
            local ok, st = pcall(micro and Micro.BuildState or State.Build, brain, Cfg, seq, sid, now, lastResults)
            if ok then
                if micro then
                    st.rescue_active = Macro.IsRescue()
                    st.macro_recent = Macro.Recent
                    Macro.SetState(st)
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
