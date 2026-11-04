-- LLM Commander :: reward events for TRAIN mode (kills, losses, production).
-- Does nothing unless Reward.Active is true (train mode).
local LLMC_OldUnit = Unit
local LLMC_Reward = nil
local function LLMC_R()
    if not LLMC_Reward then LLMC_Reward = import('/mods/LLMCommander/lua/LLMC/Reward.lua') end
    return LLMC_Reward
end

Unit = Class(LLMC_OldUnit) {
    OnKilled = function(self, instigator, type, overkillRatio)
        pcall(function()
            local R = LLMC_R()
            if R.Active then R.OnUnitKilled(self, instigator) end
        end)
        LLMC_OldUnit.OnKilled(self, instigator, type, overkillRatio)
    end,

    OnStopBeingBuilt = function(self, builder, layer)
        LLMC_OldUnit.OnStopBeingBuilt(self, builder, layer)
        pcall(function()
            local R = LLMC_R()
            if R.Active then R.OnBuilt(self) end
        end)
    end,
}
