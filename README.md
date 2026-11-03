# Note i am Not a programmer
I wanted to have a mod like but i could not find one so i asked claude.ai to make one. I can't fix bugs with out claude ai or make improvements.
# Recommend Models
Qwen3.8-9B-Distill-GGUF
Download it here https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF/blob/main/Qwen3.8-9B-Q8_0.gguf

# What i want to add

add a Train mode in where your local LLM server will learn to play and improve via trail and error against a  LOUD AI 
LOUD AI is very good at playing the game so i am hoping it will learn to beat it

# LLM Commander (Supreme Commander: Forged Alliance + LOUD)

A local LLM (llama.cpp `llama-server`, Ollama, LM Studio, anything OpenAI-compatible) plays one army.
Skirmish vs AI only. **Not multiplayer-safe** (the sim reads a local file, so other clients would desync).

# LLM Commander (Supreme Commander: Forged Alliance + LOUD)

A local LLM (llama.cpp `llama-server`, Ollama, LM Studio, anything OpenAI-compatible) plays one army.
Skirmish vs AI only. **Not multiplayer-safe** (the sim reads a local file, so other clients would desync).

**Status: written without access to a running game. Untested in-engine.** See "Assumptions" below.

## Modes (`Takeover` in `lua/LLMC/Config.lua`)
- **`micro` (default): LOUD plays everything; the LLM controls ONLY the Quantum Gateway ACUs (SACUs).** LOUD keeps its economy,
  tech, base, production, *all* of its combat units and its attack plans - the LLM cannot give orders to any normal unit. Every
  SACU the gateway builds is claimed permanently. Their jobs, in priority order: build base defences when they are lacking, assist
  Tech 4 construction, build Tech 4 units when mass is floating, build mass farms when mass is short (details below). Actions:
  `defense_cluster`, `experimental`, `mass_farm`, `assist_t4`, `sacu`. With no SACU the LLM has nothing to do and replies with no
  orders. Unit orders (`order`, `focus`, `scout`, `release`, `rally`) are refused in this mode. The macro manager, economy-only
  opening etc. further down are NOT used here (only the rescue watchdog is).
- **`sacu`: the LLM controls ONLY the gateway ACUs - and the mod touches nothing else.** Same SACU jobs and orders as `micro`, but
  without the rescue watchdog (LOUD's engineers and factories are never given orders, nothing spends resources for LOUD) and with a
  slimmer observation (no unit groups). Set `Takeover = 'sacu'`; try it with `--selftest --selftest-mode sacu`. (`micro` is the same
  SACU-only control plus the rescue watchdog.)
- **`army`: the LLM owns ALL attack units.** Everything `micro` does (gateway-ACU jobs, rescue watchdog), plus: every combat unit - land, air, naval, scouts, experimentals - is claimed for good the
  moment it is built and never handed back (no `release`). The LLM fights the whole war: defend, mass, attack in waves, retreat,
  raid. Because replies take seconds, units left idle for `IdleFallbackSeconds` (25) gather at a staging point in front of
  the base towards the nearest enemy (`StagingDistance`, change it with the `rally` action) instead of standing at the factory.
  Set `Takeover = 'army'` in `Config.lua`; try it with `--selftest --selftest-mode army`.
- **`replace`:** the AI slot's built-in AI is switched off and the LLM + macro manager play it (everything below).
- **`overlay`:** like `replace` but the built-in AI is left running.
In `micro` mode the LLM's army is the highest-numbered AI slot (or `Config.Army`): add a LOUD AI player in the lobby as usual.
**Quantum Gateway ACUs (micro mode):** every support ACU (SACU) the Quantum Gateway builds is claimed permanently
for the LLM (never handed back to LOUD). Their jobs, in priority order:
1. *Base defences lacking* (no shield, fewer than 6 AA or fewer than 8 PD + artillery within `DefenseRadius` of your start)
   -> `defense_cluster`: a **Tech 3 shield**, then **10 SAMs** (T3 AA) under it, then a mix of **T2 artillery and T2 point
   defence**, alternating, as many as fit inside the shield bubble (spots are packed from the shield outwards).
2. *Mass not being used* (stored mass >= `StallMassRatio`) -> `experimental`: a **Tech 4 unit** built in the field
   (one at a time).
3. *Mass short* (< 50% stored, energy >= 60%) -> `mass_farm`: a **T3 power plant ringed by T2 mass fabricators** (up to 16;
   the plant is queued first so the fabricators get the adjacency bonus; the ring has however many tiles the plant's
   footprint allows). Limits: `MaxDefenseClusters` (2), `MaxMassFarms` (3).
4. *Any Tech 4 unit or building under construction* (an experimental built by you or by LOUD: experimental units, gantry-built
   units, T4 structures) -> idle gateway ACUs **assist it** (`assist_t4`, `AssistT4 = true`): structures are guarded directly,
   for a unit being built the factory/engineer building it is guarded. Defences-lacking still comes first.
The LLM can order all of these itself (`defense_cluster`, `experimental`, `mass_farm`, `assist_t4`, `sacu`); with `GatewayAuto = true`
the mod also applies the same rules automatically whenever a gateway ACU is idle (`GatewayAuto = false` leaves it to the LLM).
In `micro` and `army` mode base-defence *buildings* are only a concern when gateway ACUs exist: without them the state has no `defense_status`,
the prompt tells the LLM to ignore building defences, and the rescue watchdog builds no static defences. The army still fights attackers.

**Rescue:** if LOUD stops building - engineers or factories idle - while stored mass is >= 70% or energy >= 95% for 20 s
(`StallSeconds`, `StallMassRatio`, `StallEnergyRatio`), the macro manager temporarily spends the resources for it (mex, power,
mass fabricators when energy floats, factories, mex upgrades, units, AA/PD if attacked) and switches off again once
resources are used (`Rescue = false` disables). It never starts attack waves in this mode.
Known limit: a local LLM answers in seconds, so orders arrive a bit late; select by area and let the hold timeout return units.

## How it works
Supreme Commander's sandboxed Lua cannot open sockets, so a small Python script bridges the gap:

    game  --LOG lines (LLMC|S|...)-->  game.log  --tail-->  llm_bridge.py  --HTTP-->  your LLM server
    game  <--doscript(bridge/inbox.lua)--  inbox.lua  <--write--  llm_bridge.py

Every `StateInterval` game seconds (default 15) the mod writes a compact JSON observation (economy, your
buildings/factories/engineers/squads, free mass spots, enemy contacts you have actually detected, what your
last orders did). The LLM answers with a JSON list of high-level orders (`build`, `produce`, `upgrade`,
`attack`, `scout`, ...). The mod resolves them to real blueprint IDs for your faction (so it works with
LOUD's units), finds legal build spots, and issues the commands. Every order is validated; the file the
game loads is plain Lua literals run in an empty environment.

## Install
1. Copy the `LLMCommander` folder into the mods folder your LOUD install uses (next to its other mods).
   **The folder must be named exactly `LLMCommander`.**
2. Start the game with a log file, e.g. add `/log "Loud-Dev.log"` (LOUD's dev shortcut already has it).
3. Start your LLM server, e.g. `llama-server -m model.gguf -c 8192 --port 8080`.
4. Test the model without the game: `python bridge/llm_bridge.py --selftest --server http://127.0.0.1:8080/v1`
5. Run the bridge: `python bridge/llm_bridge.py --log <path to that log file> --server http://127.0.0.1:8080/v1`
   (or edit and use `run_bridge.bat`). Ollama: `--server http://localhost:11434/v1 --model <name>`.
6. In the lobby: enable the **LLM Commander** mod and add a LOUD AI player. In the default `micro` mode the LLM micro-manages
   the combat units of the highest-numbered AI slot while LOUD keeps playing it; in `replace` mode that slot's built-in AI is switched off. Other AIs stay normal opponents.
7. Slow the game down (lobby game speed / `-` key) if your model needs many seconds per reply; the game does not wait for the LLM.

In `replace` mode look for `LLMC|I|INFO built-in AI disabled for ARMY_n` in the game log; in `micro` mode look for `mode=micro` in the `controlling ARMY_n` line and `[game] executed orders...` in the bridge console.

## Built-in macro manager (v2)
`lua/LLMC/Macro.lua` plays the routine game like the stock AI, every 6 game seconds, regardless of LLM speed:
ACU opening (land factory -> 2 pgen; factory makes 2 engineers; engineers build the first 2 mex), power/mass expansion, extra factories, radar, **tech-ups** (mex to T2/T3, then
land/air factories T1->T2->T3, busy factories get their queue cleared so the upgrade can start), engineers kept
at a sensible count and put on assist/reclaim when idle, factory queues refilled with a land/air/naval unit mix,
AA/PD when attacked, base defence, and attack waves that grow by 5 units each time.
The LLM now acts as the strategist: its `strategy` action sets tech target, army type (land/air/mixed), engineer
count, factory counts, wave size, or turns macro / auto-attack off. It can still issue any order itself.
Config: `Macro`, `MacroInterval`, `AutoAttack`, `TechTarget`, `AttackSize`, `LandFactories`, `AirFactories`.
(Set `Macro = false` for the pure-LLM version.)

**Economy-only opening:** for the first `EcoOnlySeconds` (300 = 5 minutes) of game time the commander only builds
economy: mex, power, engineers (plus the very first land factory and mex upgrades). No army, extra factories, radar,
defences, factory tech-ups or attacks - enforced for both the macro and LLM orders. If 4+ enemy units reach your base
(`EcoOnlyEmergency`) the restriction is lifted until they leave. Set `EcoOnlySeconds = 0` to disable.

**Assisting:** ALL idle engineers plus the idle ACU (if within `ACUAssistRadius`) assist an upgrading mex or an ACU
upgrade - and nothing else (assist orders on anything else are refused, for the LLM too); otherwise they reclaim.
The 2 opening engineers build the first 4 mex.

**Engineers:** no new engineers are queued while any engineer is idle (macro and LLM orders alike).

**Tech rule (enforced in the upgrade order itself, so LLM orders cannot bypass it):** a factory only goes to the next
tech level when every mass extractor is already at that level (none upgrading or still being built) AND stored energy
is full (`TechEnergyRatio`). Then the factory produces the new tier's units. Mex only run one level ahead of the factories: all mex T2 -> factories T2 ->
all mex T3 -> factories T3 (capped by `strategy.tech`).

**Storage gate:** the commander/engineers only start non mass/power buildings (factories, radar, defences, shields...)
when stored mass >= `MinMassRatio` (15%) and stored energy >= `MinEnergyRatio` (25%). Mex, power, fabricators and
storage are always allowed. Applies to the macro and to LLM orders; the very first land factory is exempt.

## Orders the LLM can give
`build` (mex hydro pgen fabricator land/air/naval_factory omni radar sonar shield aa torpedo pd arty storage),
`produce` (engineer, tank, artillery, land_aa, fighter, bomber, gunship, warship, submarine, scouts, experimental),
`upgrade`, `assist`, `reclaim`, `enhance` (ACU), `attack/move/patrol/retreat/stop/scout` for squads
(land, fighters, bombers, gunships, naval, air, scouts, all), `rally`, `strategy`. Raw `unit_id` is accepted for build/produce.

## Config (`lua/LLMC/Config.lua`)
`Army` (auto or a number), `Takeover` (`replace` | `overlay`), `StateInterval`, `MaxActionsPerTurn`, `UseACUToBuild`, `RevealEnemyStarts`.
Bridge flags: `--temperature`, `--max-tokens` (default 2500), `--no-json-mode`, `--extra-system file.txt` (e.g. `/no_think` for Qwen3), `-v`.
