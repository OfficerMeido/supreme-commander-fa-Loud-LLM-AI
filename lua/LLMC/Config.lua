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
