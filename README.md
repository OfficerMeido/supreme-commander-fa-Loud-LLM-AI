# Note i am Not a programmer
I wanted to have a mod like but i could not find one so i asked claude.ai to make one. I can't fix bugs with out claude ai or make improvements.
# Recommend Model 
Qwen3.8-9B-Distill-GGUF

Download it here https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF/blob/main/Qwen3.8-9B-Q8_0.gguf
# LLM Commander (Supreme Commander: Forged Alliance + LOUD)

A local LLM (llama.cpp `llama-server`, Ollama, LM Studio, anything OpenAI-compatible) plays one army.
Skirmish vs AI only. **Not multiplayer-safe** (the sim reads a local file, so other clients would desync).

**Status: written without access to a running game. Untested in-engine.** See "Assumptions" below.

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
6. In the lobby: enable the **LLM Commander** mod, add **one extra AI player** (any LOUD AI). The highest-numbered
   AI slot becomes the LLM's army and its built-in AI is switched off. Other AIs stay normal opponents.
7. Slow the game down (lobby game speed / `-` key) if your model needs many seconds per reply; the game does not wait for the LLM.

Look for `LLMC|I|INFO built-in AI disabled for ARMY_n` in the game log and `[game] executed orders...` in the bridge console.

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
Bridge flags: `--temperature`, `--max-tokens`, `--no-json-mode`, `--extra-system file.txt` (e.g. `/no_think` for Qwen3), `-v`.

## Fairness
The LLM only sees enemy units you can see (omni/vision) or structures you have seen before; radar-only blips are
counted but not identified. It is told enemy start positions (config `RevealEnemyStarts`).
