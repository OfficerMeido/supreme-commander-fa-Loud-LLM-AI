-- LLM Commander :: configuration. Edit freely.

Config = {
    -- Which army the LLM plays.
    --   'auto' : the highest-numbered AI slot in the lobby (ARMY_n)
    --   number : that army number, e.g. 2  ->  ARMY_2
    Army = 'auto',

    -- 'micro'   : (default) the built-in LOUD AI plays the whole game - economy, tech, base, production, ALL of its
    --             units and its attack plans. The LLM controls ONLY the Quantum Gateway ACUs (SACUs): defence
    --             clusters, Tech 4 units, mass farms, assisting Tech 4 construction.
    -- 'sacu'    : the LLM controls ONLY the Quantum Gateway ACUs, and the mod touches nothing else: like 'micro' but WITHOUT
    --             the rescue watchdog (LOUD's engineers/factories are never given orders) and with a slimmer observation.
    -- 'army'    : like 'micro', and in addition the LLM owns ALL attack units for good (land, air, naval, scouts, experimentals):
    --             every combat unit is claimed the moment it is built and never returned. LOUD keeps the economy,
    --             tech, base and unit production; the LLM fights the war. Units idle for IdleFallbackSeconds
    --             gather at a staging point in front of the base.
    -- 'train'   : TRAINING MODE. Like 'replace' (the slot's built-in AI is off, the LLM plays the whole game) but with no macro
    --             manager and none of the rule gates (the LLM learns the build/tech order itself from the reward
    --             function in Reward.lua). The episode ends when an army is destroyed; the bridge then reflects on the
    --             episode, updates its lessons file and (optionally) restarts the match. See README "Train mode".
    -- 'replace' : the chosen AI slot's built-in (LOUD) AI is switched off; the LLM + the macro manager play.
    -- 'overlay' : like 'replace' but the built-in AI is left running (they will fight over units).
    Takeover = 'micro',

    -- micro/army modes: game seconds between observations. MicroHoldSeconds is only used for units taken by an order
    -- (army mode claims units permanently), before they would be handed back to the AI.
    MicroInterval = 8,
    MicroHoldSeconds = 40,
    -- army mode
    IdleFallbackSeconds = 25,
    StagingDistance = 70,     -- how far in front of the base (towards the nearest enemy) the staging point is

    -- Game seconds between observations sent to the LLM.
    StateInterval = 15,

    -- If the bridge has not answered after this many game seconds, send a fresh observation anyway.
    ResendAfter = 90,

    -- Hard cap on actions executed per LLM reply.
    MaxActionsPerTurn = 24,

    -- Let the ACU (commander) take build orders when it is the best/only builder.
    UseACUToBuild = true,

    -- Tell the LLM where enemy start positions are (a human sees the spawn markers too).
    RevealEnemyStarts = true,

    -- TRAIN mode
    TrainEcoInterval = 10,       -- game seconds between economy-reward evaluations (storage / power / waste rewards)
    TrainMaxSeconds = 10800,     -- an episode that lasts this long (3 hours) ends as a 'timeout'. Short games last 20-30 min, long ones 1-3 h
    AutoRestart = true,          -- after an episode: wait for the bridge to save the playbook, then restart the match with RestartSession()
    RestartWaitSeconds = 900,    -- how long (game seconds) to wait for the bridge before giving up on the automatic restart
    TrainEndOnAnyArmy = true,    -- true: the episode ends as soon as ANY army is destroyed; false: only when ALL enemies are
    -- Terminal rewards - these make the agent train to WIN and destroy its opponents:
    WinReward = 500,             -- the enemy army was destroyed
    LossReward = -500,           -- your army was destroyed
    TimeoutReward = -250,        -- neither side won within TrainMaxSeconds (stalling is discouraged)
    TimePenaltyPerMinute = 5,    -- small cost per game minute: a faster win is better ...
    TimePenaltyCap = 250,        -- ... but never more than this in total, so even a 3-hour win beats a loss
    WinSpeedBonus = 300,         -- extra reward for winning EARLY (opponents get tougher the longer a game runs): full at 0 s,
    WinSpeedHorizon = 7200,      -- falling linearly to 0 at this many seconds (20 min win ~ +250, 1 h ~ +150, 2 h+ = 0)
    -- Economy rewards (follow how the economy works): income wins games, stalls halt construction, overflow is wasted.
    IncomeRewardPerMass = 0.4,   -- per mass/second of income, every TrainEcoInterval (before EcoRewardScale)
    PowerBalancedReward = 3,     -- energy income >= energy demand
    HealthyBufferReward = 2,     -- mass storage between 30% and 95% AND power storage above 30% (power may sit full: it is always in surplus)
    MexUpgradeRewardT2 = 10,     -- a mass extractor finished its upgrade to tier 2 (an upgrade triples its mass)
    MexUpgradeRewardT3 = 20,     -- ... to tier 3
    EcoRewardScale = 0.25,       -- the POSITIVE economy rewards (storage > 30%, power full, mass >= 80%) are multiplied by this ...
    EcoRewardCap = 300,          -- ... and can add at most this much per 30 minutes of play (penalties keep their full value)
    -- Combat-unit and defence rewards (train mode)
    CombatUnitReward = 2,        -- every combat unit finished (land/air/naval, not engineers/scouts/ACU) ...
    CombatRateBonus = 0.5,       -- ... + this for each combat unit finished in the previous CombatRateWindow seconds: a HIGH BUILD RATE pays more
    CombatRateCap = 10,          -- (at most this many recent units count, so a unit is worth at most 2 + 0.5 x 10 = 7)
    CombatRateWindow = 60,
    DefenseBuiltReward = 3,      -- defence structure finished (point defence, anti-air, torpedo, shield): this x tier (T1 3, T2 6, T3 9) ...
    DefenseRewardCap = 150,      -- ... at most this much per 30 minutes of play

    -- NO ARMY punishment (train mode): after NoCombatGrace seconds, every economy tick (TrainEcoInterval) in which no combat unit
    -- finished during the last NoCombatWindow seconds costs NoCombatPenalty, at most NoCombatCap per 30 minutes of play.
    NoCombatPenalty = -2,
    NoCombatGrace = 240,
    NoCombatWindow = 90,
    NoCombatCap = 300,

    -- Power generators are refused while power is already sufficient: energy storage >= TrainPowerFull AND income >= demand x TrainPowerSurplus.
    TrainPowerSufficient = true,
    TrainPowerFull = 0.8,
    TrainPowerSurplus = 1.0,

    -- WAIT FOR ORDERS TO FINISH (train mode): a builder / factory / unit takes new orders only when it was idle (nothing queued)
    TrainWaitForOrders = true,   -- engineers, the ACU and factories (also factory upgrades, assist, reclaim)
    TrainWaitSquads = true,      -- combat units too: attack/move/patrol/scout go only to idle units (retreat and stop always work)
    TrainMaxProduceOrders = 3,   -- a factory may receive up to this many produce orders in ONE turn (e.g. engineers first, then tanks)
    TrainMaxJobsPerTurn = 3,     -- an idle builder may receive up to this many jobs in ONE turn (a short queue), then must finish them

    -- Train mode ordering limits (stop the agent stacking the same order again and again):
    TrainMaxQueue = 4,           -- a builder (ACU / engineer) with this many queued jobs gets no new build orders
    TrainMaxPending = {          -- max structures of a kind under construction or ordered-but-not-started at the same time
        land_factory = 1, air_factory = 1, naval_factory = 1,
        pgen = 3, hydro = 2, mex = 4, fabricator = 2, radar = 1, omni = 1, sonar = 1, shield = 1,
        default = 3,
    },
    RewardMode = 'max',          -- kill reward: 'max' = highest applicable (3 / T4 6 / artillery 4 / nuke 8), 'sum' = add them

    -- micro mode QUANTUM GATEWAY: every ACU (SACU) the Quantum Gateway builds is taken from LOUD for good and belongs to
    -- the LLM, which uses them for: defence clusters (T3 shield + 10 SAMs + T2 artillery/PD under it), Tech 4 units when
    -- mass is not being used, and mass farms (T3 power plant ringed by 16 T2 fabricators). GatewayAuto applies those
    -- rules automatically whenever a gateway ACU is idle (the LLM can still order them itself).
    GatewayAuto = true,
    AssistT4 = true,       -- idle gateway ACUs assist ANY Tech 4 unit/building under construction (ours or LOUD's)
    MaxDefenseClusters = 2,
    MaxMassFarms = 3,
    DefenseRadius = 90,    -- structures within this distance of your start position count as "base defences"

    -- micro mode RESCUE: if the built-in AI stops building (idle engineers/factories) while stored mass >= StallMassRatio
    -- or stored energy >= StallEnergyRatio for StallSeconds, the macro manager spends the resources for it until they
    -- are being used again. Set Rescue = false to disable.
    Rescue = true,
    StallSeconds = 20,
    StallMassRatio = 0.7,
    StallEnergyRatio = 0.95,

    -- Idle engineers AND the idle ACU assist ONLY mass extractor upgrades and ACU upgrades. The ACU only helps
    -- when the target is within this many map units of it (needs UseACUToBuild = true).
    ACUAssistRadius = 200,

    -- Economy-only opening: for this many game seconds the commander only builds economy (mex, power, engineers,
    -- the first land factory). No army, extra factories, radar, defences, tech-ups or attacks. 0 = off.
    EcoOnlySeconds = 300,
    -- Safety valve: if 4+ enemy units are at your base the restriction is lifted until they are gone.
    EcoOnlyEmergency = true,

    -- Factory tech-up gate: a factory is only upgraded when ALL mass extractors are already at the new tier
    -- and stored energy is at least this ratio (1.0 = full; 0.98 tolerates rounding).
    TechEnergyRatio = 0.98,

    -- Storage gate: non mass/power buildings (factories, radar, defences, shields, ...) are only started when
    -- BOTH stored ratios are at least these. Mex, power, fabricators and storage are always allowed.
    MinMassRatio = 0.15,
    MinEnergyRatio = 0.25,

    -- Built-in macro manager (like the stock AI): economy, tech-ups, factories, engineers, production,
    -- defence and attack waves. The LLM steers it with the "strategy" action and can still give any order.
    Macro = true,
    MacroInterval = 6,     -- game seconds between macro decisions
    AutoAttack = true,     -- macro sends attack waves / defends the base
    TechTarget = 3,        -- highest tech tier to upgrade mex and factories to (1-3)
    AttackSize = 20,       -- combat units needed for the first wave (grows 5 per wave)
    LandFactories = 2,
    AirFactories = 1,

    -- Folder (inside the mod) that the bridge writes inbox.lua to. Must match the mod folder name.
    BridgeDir = '/mods/LLMCommander/bridge/',
}

-- The bridge's start-up menu (llm_bridge.py) writes bridge/mode.lua; if present it overrides Takeover for this match.
pcall(function()
    local env = {}
    doscript(Config.BridgeDir .. 'mode.lua', env)
    local m = env.LLMC_MODE
    if type(m) == 'table' and type(m.Takeover) == 'string' then
        local ok = { micro = true, sacu = true, army = true, replace = true, overlay = true, train = true }
        if ok[m.Takeover] then Config.Takeover = m.Takeover end
    end
end)
