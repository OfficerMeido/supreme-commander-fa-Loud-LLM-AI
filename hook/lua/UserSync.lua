-- LLM Commander :: UI side. Restarts the match with RestartSession() - the call LOUD's own menu uses - after a training
-- episode. RestartSession() only exists in the UI Lua state, so it is called from here. Two independent triggers:
--   1. THE BRIDGE (primary): after it has saved the playbook it writes bridge/restart.lua with a NEW token. A UI thread polls
--      that file every 2 s. It does not depend on the sim at all (the sim may have stopped after an army was destroyed).
--      The token present when the match starts is the baseline, so an old request can never restart a new match.
--   2. THE SIM (backup): the controller sets Sync.LLMC_Restart once the bridge has signalled it.
-- Everything is logged with a LLMC|I| prefix, so the bridge console shows how far it got.
local LLMC_OldOnSync = OnSync
local LLMC_Restarting = false
local LLMC_Watching = false
local LLMC_Baseline = 0

local function LLMC_ReadToken()
    local env = {}
    local ok = pcall(doscript, '/mods/LLMCommander/bridge/restart.lua', env)
    if ok and type(env.LLMC_RESTART) == 'table' and type(env.LLMC_RESTART.token) == 'number' then
        return env.LLMC_RESTART.token
    end
    return nil
end

local function LLMC_DoRestart(why)
    if LLMC_Restarting then return end
    LLMC_Restarting = true
    LOG('LLMC|I|Restart requested (' .. why .. ') - calling RestartSession() now.')
    local ok, err = pcall(function() RestartSession() end)
    if not ok then
        LLMC_Restarting = false
        LOG('LLMC|I|ERR RestartSession() failed: ' .. tostring(err))
        WARN('LLMC: RestartSession() failed: ' .. tostring(err))
    end
end

local function LLMC_Watch()
    LLMC_Baseline = LLMC_ReadToken() or 0
    LOG('LLMC|I|UI restart watcher started (baseline token ' .. tostring(LLMC_Baseline) .. ').')
    while true do
        WaitSeconds(2)
        local tok = LLMC_ReadToken()
        if tok and tok > LLMC_Baseline then
            LLMC_DoRestart('bridge token ' .. tostring(tok))
        end
    end
end

function OnSync()
    LLMC_OldOnSync()
    if not LLMC_Watching then
        LLMC_Watching = true
        local ok, err = pcall(function() ForkThread(LLMC_Watch) end)
        if not ok then LOG('LLMC|I|ERR could not start the UI restart watcher: ' .. tostring(err)) end
    end
    if Sync.LLMC_Restart then LLMC_DoRestart('sim request') end
end
