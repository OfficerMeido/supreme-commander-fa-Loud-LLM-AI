-- LLM Commander :: configuration. Edit freely.

Config = {
    -- Which army the LLM plays.
    --   'auto' : the highest-numbered AI slot in the lobby (ARMY_n)
    --   number : that army number, e.g. 2  ->  ARMY_2
    Army = 'auto',

    -- 'replace' : the chosen AI slot's built-in (LOUD) AI is switched off, the LLM is its only brain.
    -- 'overlay' : the built-in AI keeps running and the LLM just adds orders (they will fight over units).
    Takeover = 'replace',

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
