-- LLM Commander :: switch off the built-in AI for the army the LLM controls.
-- The chosen AI slot is initialised like a human-less "human" army, so LOUD's AI threads never start.
local LLMC_OldAIBrain = AIBrain

AIBrain = Class(LLMC_OldAIBrain) {
    OnCreateAI = function(self, planName)
        local ok, take = pcall(function()
            return import('/mods/LLMCommander/lua/LLMC/Controller.lua').ShouldTakeOver(self)
        end)
        if ok and take and self.OnCreateHuman then
            LOG('LLMC|I|INFO built-in AI disabled for ' .. tostring(self.Name))
            self.LLMControlled = true
            self:OnCreateHuman(planName)
            return
        end
        return LLMC_OldAIBrain.OnCreateAI(self, planName)
    end,
}
