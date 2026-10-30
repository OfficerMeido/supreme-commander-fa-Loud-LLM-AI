-- LLM Commander :: start the controller when the match begins.
local LLMC_OldBeginSession = BeginSession

function BeginSession()
    LLMC_OldBeginSession()
    local ok, err = pcall(function()
        import('/mods/LLMCommander/lua/LLMC/Controller.lua').Start()
    end)
    if not ok then WARN('LLMC: could not start controller: ' .. tostring(err)) end
end
