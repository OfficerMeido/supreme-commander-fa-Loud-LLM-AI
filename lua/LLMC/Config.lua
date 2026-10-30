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

    -- Folder (inside the mod) that the bridge writes inbox.lua to. Must match the mod folder name.
    BridgeDir = '/mods/LLMCommander/bridge/',
}
