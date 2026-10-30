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

## Orders the LLM can give
`build` (mex hydro pgen fabricator land/air/naval_factory omni radar sonar shield aa torpedo pd arty storage),
`produce` (engineer, tank, artillery, land_aa, fighter, bomber, gunship, warship, submarine, scouts, experimental),
`upgrade`, `assist`, `reclaim`, `enhance` (ACU), `attack/move/patrol/retreat/stop/scout` for squads
(land, fighters, bombers, gunships, naval, air, scouts, all), `rally`. Raw `unit_id` is accepted for build/produce.

## Config (`lua/LLMC/Config.lua`)
`Army` (auto or a number), `Takeover` (`replace` | `overlay`), `StateInterval`, `MaxActionsPerTurn`, `UseACUToBuild`, `RevealEnemyStarts`.
Bridge flags: `--temperature`, `--max-tokens`, `--no-json-mode`, `--extra-system file.txt` (e.g. `/no_think` for Qwen3), `-v`.

## Fairness
The LLM only sees enemy units you can see (omni/vision) or structures you have seen before; radar-only blips are
counted but not identified. It is told enemy start positions (config `RevealEnemyStarts`).

