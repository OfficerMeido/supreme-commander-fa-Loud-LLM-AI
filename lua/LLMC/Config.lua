-- LLM Commander :: configuration. Edit freely.

Config = {
    -- Which army the LLM plays.
    --   'auto' : the highest-numbered AI slot in the lobby (ARMY_n)
    --   number : that army number, e.g. 2  ->  ARMY_2
    Army = 'auto',

    -- 'micro'   : (default) the built-in LOUD AI plays the whole game - economy, tech, base, production, its own
    --             attack plans. The LLM only MICRO-MANAGES combat units: it takes selected units from the AI for
    --             a short time, gives tactical orders, and they go back to the AI automatically.
    -- 'replace' : the chosen AI slot's built-in (LOUD) AI is switched off; the LLM + the macro manager play.
    -- 'overlay' : like 'replace' but the built-in AI is left running (they will fight over units).
    Takeover = 'micro',

    -- micro mode: game seconds between observations, and how long units stay under LLM control without a new order
    -- before they are handed back to the AI.
    MicroInterval = 8,
    MicroHoldSeconds = 40,

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

    -- micro mode RESCUE: if the built-in AI stops building (idle engineers/factories) while stored mass >= StallMassRatio
    -- or stored energy >= StallEnergyRatio for StallSeconds, the macro manager spends the resources for it until they
    -- are being used again. Set Rescue = false to disable.
    Rescue = true,
    StallSeconds = 20,
    StallMassRatio = 0.7,
    StallEnergyRatio = 0.95,

    -- Mex upgrades (T1->T2 and T2->T3): one at a time, and only when stored mass is ABOVE this fraction of mass
    -- storage capacity (0.5 = 50%). Enforced for LLM orders too.
    MexUpgradeMassRatio = 0.5,
    -- While a mex upgrade is pending (or a factory upgrade is about to happen) the macro does not spend mass on engineers,
    -- extra factories, radar or army units - factories may sit idle - unless the base is attacked. Applies to LLM
    -- produce/build orders too. Set false to keep producing units.
    PauseArmyForMexUpgrade = true,

    -- Idle engineers AND the idle ACU assist ONLY mass extractor upgrades and ACU upgrades. The ACU only helps
    -- when the target is within this many map units of it (needs UseACUToBuild = true).
    ACUAssistRadius = 200,

    -- Early power limit: for the first PowerRatioSeconds of the game, build at most 1 power generator per
    -- MexPerPgen mass extractors (never fewer than 2 generators; the opening's first 2 are exempt). 0 = off.
    PowerRatioSeconds = 300,
    MexPerPgen = 2,

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
