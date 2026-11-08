#!/usr/bin/env python3
"""
LLM Commander bridge  --  connects Supreme Commander: Forged Alliance (LOUD) to a local LLM server.

  game  --(LLMC|S|... lines in the game log)-->  this script  --(HTTP, OpenAI-style)-->  llama.cpp / Ollama / LM Studio
  game  <--(bridge/inbox.lua, read by the mod)--  this script  <------------------------  JSON action list

Python 3.8+, standard library only.

Example:
  python llm_bridge.py --log "C:/Games/LOUD/bin/Loud-Dev.log" --server http://127.0.0.1:8080/v1
  python llm_bridge.py --selftest --server http://127.0.0.1:8080/v1     # test the model without the game
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

BRIDGE_VERSION = 7
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trainer import Trainer  # noqa: E402  (TRAIN mode bookkeeping)
import menu  # noqa: E402  (start-up mode menu)

PREFIX = b"LLMC|"

ALLOWED_ACTIONS = {
    "build", "produce", "upgrade", "assist", "reclaim", "enhance",
    "attack", "move", "patrol", "retreat", "stop", "scout", "rally", "strategy", "mex_defense",
}

MICRO_ACTIONS = {"order", "focus", "scout", "release", "sacu", "defense_cluster", "mass_farm", "experimental", "assist_t4", "rally", "mex_defense"}

GATEWAY_ACTIONS = {"sacu", "defense_cluster", "mass_farm", "experimental", "assist_t4", "mex_defense"}

GATEWAY_PROMPT = """You are LLM Gateway, the commander of the Quantum Gateway ACUs (SACUs) of a Supreme Commander: Forged Alliance (LOUD mod) army.
The built-in LOUD AI plays the whole game: economy, tech, base, unit production, all combat units and its attack plans. You do NOT control any of that and you cannot give orders to any normal unit.
You control ONLY the support ACUs (SACUs) that the Quantum Gateway builds: each one is permanently yours the moment it appears (state.gateway: built, sacus, idle, ids). Every ~8 game seconds you get a JSON state and answer with orders for them.
If state.gateway.sacus is 0 there is nothing to do: reply with an empty actions list.

STATIC DEFENSES RULE: you only worry about base-defense BUILDINGS (shield, SAMs, artillery, point defense) when you own gateway ACUs (only then does state.defense_status exist). With none, do not think about defenses at all.

JOBS, in this priority:
 a) BASE DEFENCES LACKING (state.defense_status.lacking = true: no shield, fewer than 6 AA or fewer than 8 PD+artillery near base): build defenses FIRST:
    {"a":"defense_cluster","near":[x,z]} = a Tech 3 shield, then 10 SAMs under it, then a mix of T2 artillery and T2 point defense, as many as fit under the shield. Default position: base.
 b) TECH 4 UNDER CONSTRUCTION (state.t4_under_construction = true: an experimental unit or building built by you or by the AI): idle SACUs ASSIST it so it finishes sooner: {"a":"assist_t4"} (add "force":true to pull all SACUs in).
 c) MASS IS NOT BEING USED (state.eco.mass high, e.g. >= 0.7, or state.rescue_active) and no Tech 4 is being built: build a Tech 4 unit: {"a":"experimental","what":"land"|"air"|"any","near":[x,z],"n":1}. Do not stack several at once.
 d) Otherwise, when mass is short (< 0.5) and energy is fine: {"a":"mass_farm","near":[x,z]} = a Tech 3 power plant surrounded by 16 T2 mass fabricators (limited number; expensive).
 e) Move or recall the SACUs: {"a":"sacu","cmd":"move"|"retreat"|"stop","x":X,"z":Z}. Keep them away from enemy clusters (state.enemy).
The mod also runs rules a-d automatically whenever a SACU is idle (see state.auto_recent): do not duplicate what it just ordered. state.rescue_active means the AI stalled and the mod's macro manager is temporarily spending resources for it.
If nothing needs doing, issue NO orders.

OUTPUT FORMAT - reply with ONLY one JSON object, no prose outside it:
{"thoughts": "<=15 words", "notes": "<=200 chars shown to you next turn", "actions": [ ... max 6 ... ]}
No comments, no trailing commas."""

ARMY_ADDENDUM = """

ARMY MODE - THIS OVERRIDES THE "micro" ADVICE ABOVE.
You command ALL attack units of this army permanently: every land, air, naval and scout unit is yours the moment it is built, and you can NOT give them back (no "release"). The AI keeps running the economy, base and unit production, but it no longer commands the army - YOU fight the war.
- Idle units are wasted. Units you leave idle for ~25 s walk to the staging point (state.rally) on their own; change it with {"a":"rally","x":X,"z":Z}. state.idle_attack_units says how many are idle.
- Every turn make sure every group has a job. Doing nothing is NOT a good answer here.
- Plan like a general: (1) when state.under_attack send the army to destroy the attackers (that is fighting - not building defenses), (2) mass the army at the staging point, (3) attack in waves with the whole army at the closest enemy cluster/base from state.enemy / state.enemy_starts, only when your force is clearly bigger than state.enemy_clusters' composition and defenses, (4) pull hurt units back (hp_below), (5) use fighters to guard and cover, bombers/gunships to raid weak spots, scouts to find the enemy, (6) re-issue attack orders every turn as the front moves; orders last until finished.
- Never trickle units into a fight one by one; merge groups first.
"""

MICRO_PROMPT = """You are LLM Micro, a tactical micro-manager for a Supreme Commander: Forged Alliance (LOUD mod) army.
The built-in LOUD AI plays the whole game: economy, tech, base building, unit production and its own attack plans. You do NOT control any of that.
You ONLY micro-manage COMBAT UNITS (never engineers, structures or the commander). Every ~8 game seconds you get a JSON state and answer with short tactical orders.

HOW CONTROL WORKS
- An order takes the selected units away from the AI. After 40 game seconds without a new order from you they are handed back to the AI automatically. You can also hand them back sooner with "release". Re-issue orders each turn for groups you want to keep controlling.
- Orders reach the game a few seconds after the state you saw: units move, so select by area (near + radius), not by exact position.
- state.groups lists clusters of your combat units: pos, n, roles (land/air/naval/fighters/bombers/gunships/scouts counts), hp (0-1 average), idle, held_by_llm, nearest_enemy (pos, dist, composition, defenses) and engaged (enemy within 70). state.enemy lists enemy clusters you can see (structures, defenses, land/air/naval counts). state.enemy_near_base / under_attack tell you about threats at home. state.acu shows your commander.

WHAT TO DO (priorities)
1. Save units: pull badly hurt units back: {"a":"order","cmd":"retreat","near":<group pos>,"radius":60,"hp_below":0.35}. Retreat any group that is clearly outnumbered or walking into many defenses.
2. Concentrate: merge small groups before attacking (move them to the same point), attack with the full group, do not trickle units in.
3. Focus fire on what matters: {"a":"focus","near":<group pos>,"radius":60,"tx":X,"tz":Z,"prefer":"acu"|"defense"|"structure"|"mobile"|"air"|"land"}.
4. Defend home when under_attack: send land/air groups to the threat.
STATIC DEFENSES RULE: you only worry about base-defense BUILDINGS (shield, SAMs, artillery, point defense) when you own gateway ACUs (state.gateway.sacus >= 1; only then does state.defense_status exist and only then is defense_cluster possible). With no gateway ACUs do not think about building defenses at all: the AI looks after its own base, and your job is the units. Defending against attackers with your units (rule 4) is separate and always fine.
5. QUANTUM GATEWAY ACUs: every ACU (SACU) the Quantum Gateway builds is permanently yours (state.gateway: built, sacus, idle, ids). Use them for these three jobs, in this priority:
   a) BASE DEFENCES LACKING (state.defense_status.lacking = true, i.e. no shield, fewer than 6 AA or fewer than 8 PD+artillery near base): build defenses FIRST:
      {"a":"defense_cluster","near":[x,z]} = a Tech 3 shield, then 10 SAMs under it, then a mix of T2 artillery and T2 point defense, as many as fit under the shield. Put it where your base needs cover (default: base).
   b) MASS IS NOT BEING USED (state.eco.mass high, e.g. >= 0.7, or state.rescue_active): build Tech 4 units: {"a":"experimental","what":"land"|"air"|"any","near":[x,z],"n":1}. Do not stack several experimentals at once.
   c) Otherwise, when mass is short: {"a":"mass_farm","near":[x,z]} = a Tech 3 power plant surrounded by 16 T2 mass fabricators (limited number of farms; expensive).
   d) TECH 4 UNDER CONSTRUCTION (state.t4_under_construction = true: an experimental unit or building, built by you or by the AI): idle gateway ACUs ASSIST it so it finishes sooner: {"a":"assist_t4"} (the mod does this automatically; add "force":true to pull all gateway ACUs in).
   e) MASS EXTRACTORS WITHOUT DEFENCES: {"a":"mex_defense","n":3} = a point defence and an anti-air next to mass extractors that lack them (most exposed first). The mod also does this automatically when a gateway ACU is idle.
   Move or recall them with {"a":"sacu","cmd":"move"|"retreat"|"stop","x":X,"z":Z}. The mod also runs these rules automatically when a gateway ACU is idle; check state.auto_recent and do not duplicate what it just ordered.
6. Raid and scout: bombers/gunships against weakly defended enemy clusters; scouts to unexplored enemy start positions: {"a":"scout","x":X,"z":Z}.
7. state.rescue_active=true means the AI had stalled (idle builders while mass/energy floated) and the mod's macro manager is temporarily spending resources for it (see state.macro_recent). You do not handle that - keep micro-managing units only.
8. If everything is fine, issue NO orders: the AI is already playing. Doing nothing is a good answer. Do not micro-manage for the sake of it.

ACTIONS (each object has key "a"; max 12 per turn)
 {"a":"order","cmd":"attack"|"move"|"patrol"|"retreat"|"stop","role":ROLE,"near":[x,z],"radius":55,"hp_below":0.4,"hp_above":0.6,"n":20,"x":X,"z":Z,"points":[[x,z],[x,z]],"queue":false}
     attack = attack-move to x,z. retreat goes to your base (or to x,z if given). ROLE = land fighters bombers gunships naval air scouts all (default all).
     Selection = role + units inside the circle near/radius (+ optional hp filters and a max count n, closest first).
 {"a":"focus","role":ROLE,"near":[x,z],"radius":55,"tx":X,"tz":Z,"prefer":"acu","hp_above":0.3}   selected units attack ONE visible enemy near (tx,tz)
 {"a":"scout","x":X,"z":Z}   or with "points"
 {"a":"release","role":ROLE,"near":[x,z],"radius":80}   give units back to the AI now
 {"a":"defense_cluster","near":[x,z]}   {"a":"mass_farm","near":[x,z]}   {"a":"experimental","what":"land|air|any","near":[x,z],"n":1}   {"a":"sacu","cmd":"move|retreat|stop","x":X,"z":Z}   {"a":"assist_t4"}   (gateway ACUs only)

Coordinates are world [x, z]. Read state.last_results: it tells you what your last orders did or why they failed.

OUTPUT FORMAT - reply with ONLY one JSON object, no prose outside it:
{"thoughts": "<=15 words", "notes": "<=200 chars shown to you next turn", "actions": [ ... ]}
No comments, no trailing commas."""

SYSTEM_PROMPT = """You are LLM Commander, an expert Supreme Commander: Forged Alliance player (LOUD mod) controlling ONE army against AI opponents.
You receive a JSON game state every ~15 game seconds and answer with a JSON object of orders. Your orders run a little later than the state you saw.

GOAL: destroy the enemy commanders (ACUs) and their bases while keeping your own ACU alive. The ACU is also your starting engineer.

AUTOMATIC MACRO MANAGER: the game already runs a macro manager for you (like the stock AI): it builds the opening, mex, power, factories and radar, keeps engineers working, UPGRADES mex and factories toward state.strategy.tech, refills factory queues, builds AA/PD when attacked, defends the base and sends attack waves. state.macro_recent lists what it just did. You do NOT need to micro-manage any of that. Your job is STRATEGY: steer the macro manager with the "strategy" action and add things it will not do (scouting, specific defenses/shields, experimentals, ACU enhancements, targeted attacks, retreats).
 {"a":"strategy","tech":1-3,"army":"land"|"air"|"mixed","engineers":0(auto)-30,"land_factories":n,"air_factories":n,"naval_factories":n,"attack_size":5-150,"macro":true|false,"auto_attack":true|false}
     tech = highest tier it will upgrade mex/factories to (raise it as the game goes on; 3 by default). Set auto_attack false if you want to run attacks yourself.
 Use "upgrade" yourself only for extra pushes.

HOW THE ECONOMY WORKS: mass (from extractors 'mex' on free mass spots, fabricators) and energy (power generators 'pgen', hydrocarbon plants 'hydro') pay for everything. If energy stored is ~0 everything slows down; if mass stored is high you are under-spending. Build order guide: mex on the nearest free_mass spots, 2-3 pgen per few mex, a land_factory, then engineers, more mex, more factories, radar, upgrades (mex and factories to higher tech), defenses (pd, aa, shield) where enemies attack, then a large army and attack in force. Keep engineers busy: idle engineers are wasted.

OUTPUT FORMAT - reply with ONLY one JSON object, no prose outside it:
{"thoughts": "<=2 short sentences", "notes": "<=300 chars of strategy memory that will be shown to you next turn", "actions": [ ... up to 24 actions ... ]}

ACTIONS (each is an object with key "a"):
 {"a":"build","what":KIND,"n":1,"tech":1,"near":"base"|[x,z],"radius":30}
     KIND = mex hydro pgen fabricator land_factory air_factory naval_factory omni radar sonar shield aa torpedo pd arty mass_storage energy_storage
     mex/hydro snap to free resource spots within radius (default 70). Optional "unit_id":"ueb4202" instead of "what".
     "tech" = highest tech you want (1-3). Only kinds listed in state.can_build.structures work, at the tech levels listed.
 {"a":"produce","factory":"all"|"land"|"air"|"naval"|"<factory id>","what":UNITKIND,"n":5,"tech":1}
     UNITKIND = engineer land_scout tank artillery land_aa air_scout fighter bomber gunship warship submarine experimental
     Only units in state.can_build.units work. n is the total, split over capable factories.
 {"a":"upgrade","what":"mex"|"land_factory"|"air_factory"|"naval_factory","n":2}   (or {"a":"upgrade","id":"<unit id>"})
 {"a":"assist","target":"<upgrading mex id or enhancing ACU id>","n":3}   engineers help; only valid for those two
 {"a":"reclaim","near":[x,z],"radius":40,"n":2}      engineers reclaim wrecks/trees for resources
 {"a":"mex_defense","n":3}      a point defence + an anti-air next to mass extractors that lack them (most exposed first); the macro does this automatically too
 {"a":"enhance","name":"<name from state.acu.enhancements>"}
 {"a":"attack","squad":SQUAD,"x":X,"z":Z,"fraction":1.0}   attack-move; also "move", "patrol"; "points":[[x,z],[x,z]] for several waypoints; "queue":true to append
 {"a":"retreat","squad":SQUAD}   {"a":"stop","squad":SQUAD}   {"a":"scout","x":X,"z":Z}   {"a":"rally","factory":"all","x":X,"z":Z}
     SQUAD = land fighters bombers gunships naval air scouts all   (engineers and the ACU are never in squads)

RULES
- Coordinates are world [x, z]. Use state.free_mass / free_hydro / contacts / enemy_starts / base for positions.
- Unit ids in the state are strings; copy them exactly.
- RADARS must be at least 115 apart (they would cover the same ground): never order a second radar within 115 of another one - orders that break this are refused.
- Do not repeat orders that are already in progress (check factories[].queue, engineers.idle, structures counts).
- Read state.last_results: it tells you which of your last orders failed and why.
- ECONOMY-ONLY OPENING: while state.economy_only_until is present (first 5 game minutes) only mex, hydro, pgen, fabricator, storage, engineers and mex upgrades work; everything else is refused. Focus on economy and use the time to plan.
- No new engineers are built while any engineer is idle (the macro stops, and produce engineer orders are refused).
- Idle engineers and the idle ACU automatically assist a mass extractor upgrade or an ACU upgrade (enhancement) in progress, and NOTHING else: an "assist" order on anything other than an upgrading mex or an enhancing ACU is refused. Use {"a":"assist","target":"<id>","n":20}.
- Factory upgrades are refused unless ALL mass extractors are already at the next tier (none upgrading) and energy storage is full; upgrade the mex first, then the factory, then build the higher-tier units.
- Buildings other than mex/hydro/pgen/fabricator/storage are refused while stored mass or energy is low (see last_results); build economy first, then retry.
- Spend resources: if mass or energy is piling up, build more; if one is at zero, build more of that producer first.
- Scout with a cheap scout unit early; attack only with a clearly strong force; retreat if state.under_attack and your army is weak.
- Never output anything except the JSON object. Be concise: thoughts under 15 words, notes under 200 characters, at most 16 actions, no comments, no trailing commas."""

SAMPLE_UNIT_STATE = {
    "mode": "micro", "seq": 1, "sid": 1, "t": 480, "faction": "UEF", "base": [100, 100], "map": {"w": 512, "h": 512},
    "eco": {"mass": 0.4, "energy": 0.8},
    "groups": [
        {"pos": [220, 230], "n": 14, "roles": {"land": 14}, "hp": 0.8, "idle": 0, "held_by_llm": 0,
         "nearest_enemy": {"pos": [260, 260], "dist": 50, "land": 22, "air": 0, "naval": 0, "structures": 2, "defenses": 2}, "engaged": True},
        {"pos": [210, 215], "n": 6, "roles": {"land": 4, "gunships": 2}, "hp": 0.3, "idle": 0, "held_by_llm": 0,
         "nearest_enemy": {"pos": [260, 260], "dist": 66, "land": 22, "air": 0, "naval": 0, "structures": 2, "defenses": 2}, "engaged": True},
        {"pos": [110, 105], "n": 3, "roles": {"scouts": 1, "fighters": 2}, "hp": 1.0, "idle": 3, "held_by_llm": 0, "engaged": False},
    ],
    "units_held_by_llm": 0,
    "enemy": [{"pos": [260, 260], "structures": 2, "defenses": 2, "land": 22, "air": 0, "naval": 0, "armies": [2], "dist": 230}],
    "enemy_near_base": {"land": 0, "air": 0, "naval": 0}, "under_attack": False,
    "acu": {"pos": [100, 100], "hp": 1.0}, "enemy_starts": [{"army": 2, "pos": [400, 400]}], "last_results": [],
}

SAMPLE_ARMY_STATE = dict(SAMPLE_UNIT_STATE, mode="army", rally=[140, 140], idle_attack_units=3)

TRAIN_ACTIONS = ALLOWED_ACTIONS - {"strategy"}

TRAIN_PROMPT = """You are LLM Commander in TRAINING MODE: you play ONE army of Supreme Commander: Forged Alliance (LOUD mod) against a LOUD AI or a human, and you get better by trial and error.
There is NO macro manager and NO safety rules: you run everything yourself - economy, build order, tech, production, scouting, defence and attack. The built-in AI of your slot is switched off. Every ~15 game seconds you receive a JSON state and answer with orders; they run a few seconds later.

REWARD - what you are trained to maximise (state.reward.step = reward earned since your last turn, state.reward.parts = which rewards, state.reward.episode_total = running total):
 + KILLS: enemy unit or building destroyed +3; enemy Tech 4 +6; killed by your artillery installation +4; killed by your nuke +8 (the highest applicable one counts)
 + PRODUCTION: every unit you finish +2; every Tech 4 unit +8
 + COMBAT UNITS: every combat unit you finish (land, air, naval - not engineers or scouts) pays an EXTRA +2, PLUS +0.5 for each other combat unit finished in the previous 60 seconds (up to +5), so one unit is worth 2 to 7. A high production RATE pays far more than trickling units out: keep several factories busy and queue units in batches.
 + DEFENCE STRUCTURES: every point-defence, anti-air, torpedo or shield structure you finish pays +3 x its tier (T1 +3, T2 +6, T3 +9), at most 150 per 30 minutes of play.
 - NO ARMY: after the first 4 minutes, every 10-second check in which you finished NO combat unit during the previous 90 seconds costs -2 (at most -300 per 30 minutes). You cannot win without an army: get a factory producing combat units early and keep it producing.
 + ECONOMY (checked every 10 game seconds; this follows how the Supreme Commander economy works - INCOME wins games, stockpiles are only a buffer, anything beyond your storage is wasted):
     mass income +0.4 per mass/second; power supply keeping up with demand (energy income >= energy demand) +3; a healthy buffer (mass storage between 30% and 95% AND power storage above 30%) +2; every mass extractor upgrade that finishes: T2 +10, T3 +20 (an upgrade TRIPLES an extractor's mass). These positive economy rewards are multiplied by 0.25 and capped at 300 per 30 minutes of play, so they guide you without being the point.
 - STALLS and WASTE (full value): mass at 0 -4 (construction halts); power at 0 -4 and power storage under 20% -2 (an energy shortage also switches off radar and shield generators and slows every factory and engineer); mass wasted (mass storage full and still overflowing) -6. Power overflow is normal and NOT penalised: power income is always far larger than mass income (+1000 energy with +1 mass is fine) - but unspent MASS above capacity is simply lost, so spend it.
 - LOSSES: every unit lost -1; every building lost -3; every mass extractor lost -4
 *** THE BIG ONE - THE GOAL IS TO WIN: destroying the enemy army (kill its commander and base) gives +500, PLUS a speed bonus of up to +300 for winning early (about +250 for a win after 20 minutes, +150 after 1 hour, nothing after 2 hours); having your own army destroyed gives -500; running out the clock (3 hours) without a winner gives -250; every game minute costs -5 (at most -250 in total). THE LONGER A GAME RUNS THE TOUGHER THE OPPONENT GETS (short games last 20-30 minutes, long games 1-3 hours): expand and tech fast, then attack - do not turtle and hope. state.reward.rules shows the current values. Economy points alone can never beat a win, so build a strong economy as a MEANS to build an army, find the enemy and destroy it. ***
The episode (training step) ends when an army is destroyed - yours or the enemy's. Then the match restarts and you see lessons written from your past episodes. Maximise the TOTAL, which is dominated by winning: destroy the enemy commander and army as fast as you safely can; losing your own commander costs -500.

ORDERS (each is an object with key "a"; at most 24 per turn; state.can_build tells what works at which tech):
 {"a":"build","what":KIND,"n":1,"tech":1,"near":"base"|[x,z],"radius":30}   KIND = mex hydro pgen fabricator land_factory air_factory naval_factory omni radar sonar shield aa torpedo pd arty mass_storage energy_storage (or "unit_id":"ueb4202"). mex/hydro snap to free resource spots.
 {"a":"produce","factory":"all"|"land"|"air"|"naval"|"<factory id>","what":UNITKIND,"n":5,"tech":2}   UNITKIND = engineer land_scout tank artillery land_aa air_scout fighter bomber gunship warship submarine experimental
 {"a":"mex_defense","n":3}  (a point defence + an anti-air next to mass extractors that lack them)   {"a":"upgrade","what":"mex"|"land_factory"|"air_factory"|"naval_factory","n":2} (or "id")   {"a":"assist","target":"<id>","n":3}   {"a":"reclaim","near":[x,z],"radius":40,"n":2}   {"a":"enhance","name":"<state.acu.enhancements name>"}
 {"a":"attack","squad":SQUAD,"x":X,"z":Z,"fraction":1.0}  (also "move", "patrol", "points":[[x,z],..], "queue":true)   {"a":"retreat","squad":SQUAD}   {"a":"stop","squad":SQUAD}   {"a":"scout","x":X,"z":Z}   {"a":"rally","factory":"all","x":X,"z":Z}
     SQUAD = land fighters bombers gunships naval air scouts all (engineers and the ACU are never in squads). Engineers build, assist and reclaim; use state.engineers.idle_ids / idle count: idle engineers are wasted.
Coordinates are world [x, z]. Unit ids in the state are strings. Read state.last_results: it says which orders failed and why.

HOW BUILDING WORKS - read this, it is the most common mistake: build orders QUEUE behind whatever the builder is already doing, and structures take a long time. The ACU and each engineer work through their queue ONE JOB AT A TIME. So do NOT order more of something that is already being built:
 - state.under_construction = what is being built right now (e.g. {"land_factory":1}); state.acu.queued_jobs = the ACU's queue length; state.alerts = plain-language problems to fix FIRST.
 - WAIT FOR ORDERS TO FINISH (important): a builder, factory or unit takes a NEW order only when it has finished the previous ones. Engineers and the ACU accept build orders only while idle (state.engineers.idle_ids, state.acu.idle) and then up to 3 jobs in ONE turn; a factory accepts a produce order only when its queue is EMPTY (factories[].idle) - you may give it up to 3 produce orders in the SAME turn - put ENGINEERS first, then combat units (e.g. engineer x3, then tank x10) - and it works through them while you wait; combat units accept attack/move/patrol/scout orders only when idle (retreat and stop always work). Orders to busy ones are refused: do NOT repeat them, wait.
 - Orders for a kind that is already under construction or queued are also REFUSED (limits at a time: 1 factory of each type, 3 pgen, 4 mex, ...). Read state.last_results for these refusals and give DIFFERENT orders to the builders that ARE idle instead of repeating yourself.
 - ASSIST only helps something that is really under construction or upgrading; assisting an idle unit or another helper is refused. An engineer that is left assisting something which has stopped building is released automatically after a few seconds, and state.engineers.idle_ids / state.acu.idle already count such engineers as idle.
 - POWER COMES FIRST: everything costs energy. Power is LOW when your energy INCOME is under 60/s while your best factory is tech 1 (the 20/s you start with IS low - a full storage at the start does not mean you have enough), under 200/s at tech 2 and under 500/s at tech 3 (state.power_low_income, state.tech_level, state.alerts). While power is LOW or income is below demand, build pgen BEFORE anything else. Once income is above the threshold for your tech AND storage is nearly full, more pgen are refused and useless. Never answer with only factories, and never with only pgen.
 - DEFENCES AND RADAR: build a point defence and an anti-air next to your mass extractors ({"a":"mex_defense","n":3}; state.mex_defense shows how many extractors lack them) - losing an extractor costs -4. Radars must be at least 115 apart: orders for a radar closer than that to another radar are refused.
ECONOMY FACTS (from the game's wiki): mass comes mostly from mass extractors - T1 +2 M/s for 2 E/s upkeep, upgraded to T2 +6 M/s for 9 E/s, T3 about 12-18 M/s for 36-54 E/s - so UPGRADING extractors is the cheapest way to multiply income. Energy comes from power generators (T1 pgen 20 E/s, hydrocarbon plant 100 E/s on its special spots, T2 pgen 500 E/s, T3 2500 E/s) and everything draws on it; mass fabricators turn a LOT of energy into a little mass (about 150 E per 1 M for a T2 fab) - only worth it with surplus power. Storage buildings only add capacity. Resources must be stored: income that does not fit is wasted, so keep spending it. Time is the key: more income sooner means more units sooner.
OPENING (first ~3 minutes): the ACU is idle at the start, so give it its three jobs in ONE turn: mex x2 (near free_mass), pgen x2, then ONE land_factory, and then let it work. When the factory exists: produce engineer x3 FIRST, then in the same turn tank x10. AFTER THE OPENING (about 4 mex, 2-4 pgen): as soon as the factory exists START PRODUCING COMBAT UNITS (tank / fighter / ..., batches of n=10) and keep EVERY factory producing - an army that does not exist costs reward after 4 minutes. Engineers: more mex on free_mass and mex upgrades, a second factory, defences, radar; build power ONLY while it is short (do not keep ordering pgen - after the first few it is rarely needed). Spread orders over DIFFERENT kinds each turn (mex, engineers, factory, units, defences...), and use idle engineers.
Also: never let mass or power run empty, and spend mass before it overflows (power overflow does not matter - big power income with small mass income is normal); scout early; do not feed units piecemeal; defend your commander; use the lessons below.

OUTPUT FORMAT - reply with ONLY one JSON object:
{"thoughts": "<=20 words", "notes": "<=250 chars of memory shown to you next turn", "actions": [ ... ]}
No comments, no trailing commas."""

SAMPLE_MICRO_STATE = {
    "mode": "micro", "seq": 1, "sid": 1, "t": 900, "faction": "UEF", "base": [100, 100], "map": {"w": 512, "h": 512},
    "eco": {"mass": 0.75, "energy": 0.9},
    "gateway": {"built": True, "sacus": 3, "idle": 2, "ids": ["101", "102", "103"]},
    "defense_status": {"shields": 0, "aa": 2, "pd": 3, "artillery": 0, "radius": 90, "lacking": True},
    "defense_clusters": 0, "mass_farms": 0, "experimentals": 0, "t4_under_construction": False, "rescue_active": False,
    "enemy": [{"pos": [260, 260], "structures": 2, "defenses": 2, "land": 22, "air": 0, "naval": 0, "armies": [2], "dist": 230}],
    "enemy_near_base": {"land": 0, "air": 0, "naval": 0}, "under_attack": False,
    "acu": {"pos": [100, 100], "hp": 1.0}, "enemy_starts": [{"army": 2, "pos": [400, 400]}], "last_results": [], "auto_recent": [],
}

SAMPLE_STATE = {
    "seq": 1, "sid": 1, "t": 20, "faction": "UEF", "base": [100, 100], "map": {"w": 512, "h": 512},
    "eco": {"mass": {"stored": 650, "income": 1.0, "demand": 0.0}, "energy": {"stored": 4000, "income": 20.0, "demand": 0.0}},
    "structures": {}, "factories": [], "engineers": {"total": 0, "idle": 0, "idle_ids": []}, "army": {},
    "acu": {"id": "1001", "pos": [100, 100], "hp": 1.0, "enhancements": []},
    "can_build": {"structures": {"mex": [1], "pgen": [1], "land_factory": [1], "air_factory": [1], "radar": [1], "pd": [1]}, "units": {}},
    "free_mass": [[110, 95, 11], [90, 110, 14], [120, 120, 28]], "free_hydro": [], "contacts": [],
    "enemy_near_base": {"land": 0, "air": 0, "naval": 0}, "under_attack": False,
    "enemy_starts": [{"army": 2, "pos": [400, 400]}], "last_results": [],
}


SAMPLE_TRAIN_STATE = dict(SAMPLE_STATE, mode="train", reward={"step": 0, "parts": {}, "episode_total": 0})


# ------------------------------------------------------------------------------------------------
# log tailing + message reassembly
# ------------------------------------------------------------------------------------------------
def default_log_candidates():
    home = os.path.expanduser("~")
    local = os.environ.get("LOCALAPPDATA", os.path.join(home, "AppData", "Local"))
    return [
        os.path.join(local, "Gas Powered Games", "Supreme Commander Forged Alliance", "logs", "game.log"),
        os.path.join(home, "Documents", "My Games", "Gas Powered Games", "Supreme Commander Forged Alliance", "logs", "game.log"),
    ]


def tail_lines(path, from_start=False, poll=0.2):
    """Yield raw byte lines appended to `path`; survives the file being (re)created or truncated."""
    f = None
    buf = b""
    first = True
    while True:
        try:
            if f is None:
                if not os.path.exists(path):
                    time.sleep(1.0)
                    continue
                f = open(path, "rb")
                if first and not from_start:
                    f.seek(0, os.SEEK_END)
                first = False
            try:
                if os.path.getsize(path) < f.tell():  # truncated / new game overwrote the log
                    f.seek(0)
                    buf = b""
            except OSError:
                pass
            chunk = f.read(65536)
            if not chunk:
                time.sleep(poll)
                continue
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for ln in lines:
                yield ln
        except OSError:
            if f:
                f.close()
            f = None
            time.sleep(1.0)


def train_checklist(state):
    """Plain-language 'do this now' list built from the state - small models forget engineers and moving their army."""
    items = []
    eng = state.get("engineers") or {}
    n_eng = eng.get("total", 0) or 0
    facs = [f for f in (state.get("factories") or []) if f.get("idle") and not f.get("upgrading")]
    if facs:
        ids = [str(f.get("id")) for f in facs][:4]
        if n_eng < 4:
            items.append('IDLE FACTORIES %s and you have only %d engineers: produce ENGINEERS first, e.g. {"a":"produce","factory":"%s","what":"engineer","n":%d}, and in the SAME turn queue combat units after them, e.g. {"a":"produce","factory":"%s","what":"tank","n":10}.'
                         % (ids, n_eng, ids[0], max(2, 5 - n_eng), ids[0]))
        else:
            items.append('IDLE FACTORIES %s: queue combat units, e.g. {"a":"produce","factory":"%s","what":"tank","n":10} (fighters/bombers from an air factory).' % (ids, ids[0]))
    army = state.get("army") or {}
    idle_units = sum((v or {}).get("idle", 0) for k, v in army.items() if k != "scouts")
    total_units = sum((v or {}).get("n", 0) for k, v in army.items() if k != "scouts")
    if idle_units > 0:
        tgt = None
        for c in state.get("contacts") or []:
            if c.get("pos"):
                tgt = c["pos"]
                break
        if tgt is None:
            for e in state.get("enemy_starts") or []:
                if e.get("pos"):
                    tgt = e["pos"]
                    break
        where = ('toward the enemy at %s,%s, e.g. {"a":"attack","squad":"land","x":%s,"z":%s}' % (tgt[0], tgt[1], tgt[0], tgt[1])) if tgt else 'to a gathering point or to scout'
        items.append("%d of your %d combat units are IDLE - an idle army earns nothing: move them %s" % (idle_units, total_units, where))
    idle_eng = eng.get("idle_ids") or []
    if idle_eng:
        items.append("IDLE ENGINEERS %s: give each a job (mass extractor on free_mass, a factory, defences, assist an upgrade)." % idle_eng[:8])
    md = state.get("mex_defense") or {}
    if md.get("undefended") and md.get("mex", 0) >= 2:
        items.append('%d of your %d mass extractors have no point defence / anti-air next to them: {"a":"mex_defense","n":3}' % (md["undefended"], md["mex"]))
    if not items:
        return "TURN CHECKLIST: nothing is idle right now - do NOT repeat earlier orders; plan the next steps or wait."
    return "TURN CHECKLIST (do these THIS turn, in this order; skip what does not apply):\n- " + "\n- ".join(items)


def replace_checklist(state):
    """Per-turn 'do this now' list for the full-game (replace) mode. Small models forget MASS, so it comes first."""
    items = []
    eco = state.get("eco") or {}
    mass = eco.get("mass") or {}
    energy = eco.get("energy") or {}
    ratio, inc = mass.get("stored_ratio"), mass.get("income")
    fm = state.get("free_mass") or []
    mex_tiers = (state.get("structures") or {}).get("mex") or {}
    mex_count = sum(v for v in mex_tiers.values() if isinstance(v, (int, float)))
    pct = "%d%%" % round(ratio * 100) if isinstance(ratio, (int, float)) else "?"
    if fm and (mex_count < 10 or (isinstance(ratio, (int, float)) and ratio < 0.4)):
        x, z = fm[0][0], fm[0][1]
        items.append('MASS FIRST: you have %d mass extractors (mass income %s/s, %s stored) and %d FREE mass spots (nearest at %s,%s). Mass builds everything - build more now: {"a":"build","what":"mex","n":%d,"near":[%s,%s]}.'
                     % (mex_count, inc, pct, len(fm), x, z, min(3, len(fm)), x, z))
    elif mex_count and not fm and (not isinstance(ratio, (int, float)) or ratio < 0.5):
        items.append('MASS: no free mass spots are left - raise mass by UPGRADING extractors: {"a":"upgrade","what":"mex","n":2}.')
    if isinstance(ratio, (int, float)) and ratio > 0.8:
        items.append("Mass is piling up (%s stored): SPEND it - queue units in the factories, build another factory, upgrade extractors." % pct)
    er, einc = energy.get("stored_ratio"), energy.get("income")
    low_t = state.get("power_low_income") or {1: 60, 2: 200, 3: 500}[min(3, max([f.get("tech", 1) for f in (state.get("factories") or [])] + [1]))]
    if (isinstance(er, (int, float)) and er < 0.25) or (isinstance(einc, (int, float)) and einc < low_t):
        items.append('POWER LOW: energy income %s/s (low = under %d/s for your tech level), %s stored: build power generators: {"a":"build","what":"pgen","n":2}.'
                     % (einc, low_t, ("%d%%" % round(er * 100)) if isinstance(er, (int, float)) else "?"))
    md = state.get("mex_defense") or {}
    if md.get("undefended") and md.get("mex", 0) >= 3:
        items.append('MASS EXTRACTOR DEFENCE: %d of %d extractors have no point defence / anti-air next to them: {"a":"mex_defense","n":3}.' % (md["undefended"], md["mex"]))
    idle = (state.get("engineers") or {}).get("idle_ids") or []
    if idle:
        items.append("IDLE ENGINEERS %s: give them jobs - mass extractors first, then power, then factories." % idle[:8])
    if not items:
        return "TURN CHECKLIST: economy looks fine - concentrate on strategy (state.strategy, attacks, scouting)."
    return "TURN CHECKLIST (do these THIS turn, in this order):\n- " + "\n- ".join(items)


class Assembler:
    """Collects  LLMC|S|seq|part|total|payload  (state) and  LLMC|E|...  (episode summary) chunks into whole messages."""

    def __init__(self, on_state, on_info, on_ack, on_episode=None):
        self.parts = {}
        self.on_state, self.on_info, self.on_ack, self.on_episode = on_state, on_info, on_ack, on_episode

    def feed(self, line):
        i = line.find(PREFIX)
        if i < 0:
            return
        rest = line[i + len(PREFIX):].rstrip(b"\r\n")
        tag = rest[:1]
        try:
            if tag == b"I":
                self.on_info(rest[2:].decode("utf-8", "replace"))
            elif tag == b"A":
                f = rest.split(b"|")
                self.on_ack(int(f[1]), int(f[2]))
            elif tag in (b"S", b"E"):
                f = rest.split(b"|", 4)
                seq, part, total, payload = int(f[1]), int(f[2]), int(f[3]), f[4]
                key = (tag, seq)
                d = self.parts.setdefault(key, {})
                d[part] = payload
                if len(d) == total:
                    blob = b"".join(d[k] for k in sorted(d))
                    del self.parts[key]
                    for old in [k for k in self.parts if k[0] == tag and k[1] < seq - 3]:
                        del self.parts[old]
                    obj = json.loads(blob.decode("utf-8", "replace"))
                    if tag == b"E":
                        if self.on_episode:
                            self.on_episode(seq, obj)
                    else:
                        self.on_state(seq, obj)
        except (ValueError, IndexError, KeyError) as e:
            print(f"[bridge] bad log line ignored ({e})")


# ------------------------------------------------------------------------------------------------
# LLM client
# ------------------------------------------------------------------------------------------------
class LLM:
    def __init__(self, args):
        self.args = args
        self.json_mode = not args.no_json_mode
        self.last_finish = None

    def chat(self, messages, temperature=None):
        a = self.args
        body = {"messages": messages, "temperature": a.temperature if temperature is None else temperature, "max_tokens": a.max_tokens, "stream": False}
        if a.model:
            body["model"] = a.model
        if self.json_mode:
            body["response_format"] = {"type": "json_object"}
        headers = {"Content-Type": "application/json"}
        if a.api_key:
            headers["Authorization"] = "Bearer " + a.api_key
        req = urllib.request.Request(a.server.rstrip("/") + "/chat/completions",
                                     data=json.dumps(body).encode(), headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=a.timeout) as r:
                body_bytes = r.read()
            try:
                data = json.loads(body_bytes.decode("utf-8", "replace"))
            except ValueError:
                raise RuntimeError("LLM SERVER sent a non-JSON HTTP body (starts: %r)" % body_bytes[:150])
        except urllib.error.HTTPError as e:
            if e.code == 400 and self.json_mode:
                print("[bridge] server rejected response_format; retrying without JSON mode")
                self.json_mode = False
                return self.chat(messages, temperature)
            raise
        choice = data["choices"][0]
        self.last_finish = choice.get("finish_reason")
        return choice["message"].get("content") or ""


def salvage(text):
    """Last resort for broken JSON: pull the thoughts/notes strings and every complete action object we can parse."""
    dec = json.JSONDecoder()
    out = {"thoughts": "", "notes": "", "actions": []}
    for key in ("thoughts", "notes"):
        m = re.search(r'"%s"\s*:\s*"((?:\\.|[^"\\])*)"' % key, text)
        if m:
            out[key] = m.group(1)
    m = re.search(r'"actions"\s*:\s*\[', text)
    if not m:
        return None
    pos = m.end()
    while pos < len(text):
        c = text[pos]
        if c == "{":
            try:
                obj, end = dec.raw_decode(text, pos)
                if isinstance(obj, dict):
                    out["actions"].append(obj)
                pos = end
                continue
            except json.JSONDecodeError:
                nxt = text.find("{", pos + 1)
                if nxt < 0:
                    break
                pos = nxt
                continue
        if c == "]":
            break
        pos += 1
    return out


def extract_json(text):
    """-> (object, note). Tolerates think-tags, code fences, trailing/missing commas and truncated replies."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
    text = re.sub(r"^.*?</think>", "", text, flags=re.S).strip()   # unterminated opening tag
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m:
        text = m.group(1)
    s_, e_ = text.find("{"), text.rfind("}")
    if s_ < 0:
        raise ValueError("no JSON object in reply")
    raw = text[s_:e_ + 1] if e_ > s_ else text[s_:]
    attempts = [
        raw,
        re.sub(r",\s*([}\]])", r"\1", raw),                                     # trailing commas
        re.sub(r'(["\d\]}el])\s*\n\s*(")', r"\1,\n\2", re.sub(r"}\s*{", "},{", raw)),  # missing commas
    ]
    # comments, Python literals, trailing/missing commas all at once
    c = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    c = re.sub(r"(?m)\s//[^\n]*$", "", c)
    c = re.sub(r":\s*True\b", ": true", c)
    c = re.sub(r":\s*False\b", ": false", c)
    c = re.sub(r":\s*None\b", ": null", c)
    c = re.sub(r",\s*([}\]])", r"\1", re.sub(r"}\s*{", "},{", c))
    attempts.append(c)
    for a in attempts:
        try:
            return json.loads(a), ""
        except json.JSONDecodeError:
            pass
    got = salvage(text[s_:])
    if got is not None and got["actions"]:
        return got, f"reply was malformed JSON; recovered {len(got['actions'])} actions"
    raise ValueError("reply was not valid JSON")


# ------------------------------------------------------------------------------------------------
# validation + Lua serialisation (the game only ever sees plain literals)
# ------------------------------------------------------------------------------------------------
def clean(v, depth=0):
    if v is None or depth > 3:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return round(float(v), 2) if math.isfinite(v) else 0
    if isinstance(v, str):
        return v.encode("ascii", "replace").decode()[:80]
    if isinstance(v, list):
        return [x for x in (clean(i, depth + 1) for i in v[:24]) if x is not None]
    if isinstance(v, dict):
        out = {}
        for k, x in list(v.items())[:12]:
            cx = clean(x, depth + 1)
            if cx is not None:
                out[re.sub(r"[^A-Za-z0-9_]", "", str(k))[:24]] = cx
        return out
    return None


def lua(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(int(v)) if float(v).is_integer() else repr(float(v))
    if isinstance(v, str):
        esc = v.replace("\\", "\\\\").replace('"', '\\"')
        esc = "".join(c if 32 <= ord(c) < 127 else " " for c in esc)
        return '"' + esc + '"'
    if isinstance(v, list):
        return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join('["%s"]=%s' % (k, lua(x)) for k, x in v.items()) + "}"
    return "nil"


def sanitize_actions(raw, warnings, limit, allowed=None):
    acts = []
    if not isinstance(raw, list):
        warnings.append("actions must be a list")
        return acts
    for i, a in enumerate(raw[:limit]):
        if not isinstance(a, dict) or a.get("a") not in (allowed or ALLOWED_ACTIONS):
            warnings.append(f"action {i + 1} dropped: unknown or malformed ({str(a)[:50]})")
            continue
        acts.append(clean(a))
    if len(raw) > limit:
        warnings.append(f"only the first {limit} actions were kept")
    return acts


def write_restart_token(bridge_dir):
    """Ask the game's UI to restart the match: write a NEW token to bridge/restart.lua (see hook/lua/UserSync.lua)."""
    path = os.path.join(bridge_dir, "restart.lua")
    old = 0
    try:
        with open(path, encoding="utf-8") as f:
            m = re.search(r"token\s*=\s*(\d+)", f.read())
            old = int(m.group(1)) if m else 0
    except OSError:
        pass
    token = max(old + 1, int(time.time()))
    with open(path, "w", newline="\n") as f:
        f.write("-- Written by llm_bridge.py after an episode: a NEW token asks the game's UI to restart the match.\nLLMC_RESTART = { token = %d }\n" % token)
    return token


def write_inbox(path, sid, seq, actions, warnings, restart=False):
    text = "LLMC_INBOX = { sid = %s, seq = %d, actions = %s, warnings = %s%s }\n" % (
        lua(sid), seq, lua(actions), lua([w[:100] for w in warnings[:10]]), ", restart = true" if restart else "")
    with open(path, "w", newline="\n") as f:
        f.write(text)


# ------------------------------------------------------------------------------------------------
# the bridge itself
# ------------------------------------------------------------------------------------------------
class Bridge:
    def __init__(self, args):
        self.args = args
        self.llm = LLM(args)
        self.latest = None
        self.cv = threading.Condition()
        self.notes = ""
        self.prev_actions = []
        self.extra = open(args.extra_system, encoding="utf-8").read() if args.extra_system else ""
        self.asm = Assembler(self.on_state, self.on_info, self.on_ack, self.on_episode)
        self.last_ack = 0
        self.trainer = None            # created on the first TRAIN-mode state
        self.pending_end = None        # episode summary waiting to be processed by the worker
        self.episodes_done = 0
        self.done = 0                  # highest state seq the worker has answered
        self.mode_checked = False
        self.last_sid = 0
        self.restart_pending = False
        self.last_raw, self.last_system, self.last_user = "", "", ""

    def get_trainer(self):
        if self.trainer is None:
            self.trainer = Trainer(self.args, extract_json)
        return self.trainer

    def on_info(self, text):
        print("[game]", text)
        if text.startswith("START"):
            self.notes, self.prev_actions, self.last_ack = "", [], 0
            self.mode_checked = False
            if self.restart_pending:
                self.restart_pending = False
                print("[train] the new match has started - the automatic restart worked.")
            with self.cv:
                self.latest = None
                self.done = 0
            write_inbox(self.args.inbox, 0, 0, [], [])  # clear stale orders from a previous game

    def on_ack(self, seq, count):
        self.last_ack = seq
        print(f"[game] executed orders for turn {seq} ({count} actions)")

    def on_episode(self, seq, summary):
        with self.cv:
            self.pending_end = summary
            self.cv.notify()

    def on_state(self, seq, state):
        self.last_sid = state.get("sid", self.last_sid)
        exp = getattr(self.args, "mode", None)
        if exp and not self.mode_checked and exp not in ("replace", "overlay"):
            self.mode_checked = True
            actual = state.get("mode")
            if actual != exp:
                print(f"[bridge] WARNING: you chose '{exp}' but the running game reports mode '{actual or 'replace/overlay'}'. "
                      f"The mod reads the mode when a match STARTS - restart the game (the bridge wrote {os.path.join(os.path.dirname(os.path.abspath(self.args.inbox)), 'mode.lua')}).")
        with self.cv:
            self.latest = (seq, state)
            self.cv.notify()

    def messages(self, state):
        user = (
            "GAME STATE:\n" + json.dumps(state, separators=(",", ":")) +
            "\n\nYOUR NOTES FROM LAST TURN: " + (self.notes or "(none yet - this is the start of the game)") +
            "\nYOUR LAST ORDERS: " + json.dumps(self.prev_actions, separators=(",", ":"))[:1500] +
            "\n\nAnswer with the JSON object only."
        )
        mode = state.get("mode")
        if mode == "train":
            user = user.replace("\n\nAnswer with the JSON object only.", "\n\n" + train_checklist(state) + "\n\nAnswer with the JSON object only.")
        elif mode not in ("micro", "sacu", "army"):
            user = user.replace("\n\nAnswer with the JSON object only.", "\n\n" + replace_checklist(state) + "\n\nAnswer with the JSON object only.")
        if mode == "train":
            base_prompt = TRAIN_PROMPT + "\n\n" + self.get_trainer().context_text()
        elif mode == "army":
            base_prompt = MICRO_PROMPT + ARMY_ADDENDUM
        elif mode in ("micro", "sacu"):
            base_prompt = GATEWAY_PROMPT
        else:
            base_prompt = SYSTEM_PROMPT
        sysmsg = base_prompt + (("\n\n" + self.extra) if self.extra else "")
        return [{"role": "system", "content": sysmsg}, {"role": "user", "content": user}]

    def log_bad(self, text, err):
        try:
            path = os.path.join(os.path.dirname(os.path.abspath(self.args.inbox)), "bad_replies.log")
            with open(path, "a", encoding="utf-8") as f:
                f.write("=== %s  %s\n%s\n\n" % (time.strftime("%H:%M:%S"), err, text))
        except OSError:
            pass

    def decide(self, state):
        """One LLM round-trip (plus one repair retry) -> (thoughts, notes, actions, warnings)."""
        warnings = []
        msgs = self.messages(state)
        train = state.get("mode") == "train"
        temp = self.get_trainer().temperature() if train else None
        text = self.llm.chat(msgs, temp)
        truncated = self.llm.last_finish == "length"
        try:
            obj, note = extract_json(text)
        except ValueError as e:
            self.log_bad(text, e)
            if self.args.verbose:
                print("[llm raw]", text[:1200])
            print(f"[bridge] unusable reply ({e}{', cut off by max_tokens' if truncated else ''}); asking the model to redo it")
            retry = msgs + [
                {"role": "assistant", "content": text[:3000]},
                {"role": "user", "content": "That was not valid JSON" + (" (it was cut off - be much shorter)" if truncated else "") +
                 ". Reply again with ONLY one valid JSON object: {\"thoughts\":\"...\",\"notes\":\"...\",\"actions\":[...]}. "
                 "Keep thoughts under 15 words and use at most 12 actions."},
            ]
            text = self.llm.chat(retry, temp)
            truncated = self.llm.last_finish == "length"
            try:
                obj, note = extract_json(text)          # raises if still broken
            except ValueError as e2:
                self.log_bad(text, e2)
                raise ValueError(f"reply still not valid JSON after retry ({e2}); see bridge/bad_replies.log")
        if note:
            warnings.append(note)
            print("[bridge]", note)
        if truncated:
            warnings.append("reply was cut off by the token limit; keep replies shorter")
            print("[bridge] reply hit max_tokens - consider raising --max-tokens")
        micro = state.get("mode") in ("micro", "army", "sacu")
        acts = sanitize_actions(obj.get("actions", []), warnings, min(self.args.max_actions, 12) if micro else self.args.max_actions,
                                TRAIN_ACTIONS if train else ((MICRO_ACTIONS if state.get("mode") == "army" else GATEWAY_ACTIONS) if micro else None))
        self.last_raw, self.last_system, self.last_user = text, msgs[0]["content"], msgs[1]["content"]
        notes = str(obj.get("notes", ""))[:400]
        return str(obj.get("thoughts", ""))[:300], notes, acts, warnings

    def handle_episode_end(self, summary):
        write_inbox(self.args.inbox, 0, 0, [], [])          # no stale orders for the next match
        if self.trainer is not None:
            self.trainer.end_episode(summary, self.llm)
        self.episodes_done += 1
        stopping = bool(self.args.max_episodes and self.episodes_done >= self.args.max_episodes)
        game_restart = (not stopping) and (not self.args.restart_cmd) and (not self.args.no_game_restart)
        if stopping:
            nxt = ("TRAINING STOPPED: --max-episodes %d reached. When you want to continue, resume with the command above, then START A NEW GAME."
                   % self.args.max_episodes)
        elif self.args.restart_cmd:
            nxt = ("NEXT: A NEW GAME IS STARTING - the restart command was run: %s\n"
                   " If no new game appears, START A NEW GAME YOURSELF; the bridge continues automatically when it does." % self.args.restart_cmd)
        elif game_restart:
            nxt = ("NEXT: THE MOD RESTARTS THE MATCH ITSELF now (RestartSession, the same call LOUD's menu uses) - the playbook is saved.\n"
                   " If no new game appears within a minute, START A NEW GAME YOURSELF; the bridge continues automatically.")
        else:
            nxt = "NEXT: START A NEW GAME NOW (automatic restart is off). The bridge continues automatically as soon as the new game begins."
        if self.trainer is not None:
            self.trainer.announce(nxt)
        if stopping:
            os._exit(0)
        if self.args.restart_cmd:
            try:
                subprocess.Popen(self.args.restart_cmd, shell=True)
            except OSError as e:
                print("[train] restart command failed:", e)
        elif game_restart:
            # the playbook is saved: ask the game to restart the match. Two signals: a new token in bridge/restart.lua (polled by
            # the UI hook, independent of the sim) and a restart flag in inbox.lua (polled by the sim as a backup).
            write_inbox(self.args.inbox, self.last_sid or 0, 0, [], [], restart=True)
            token = write_restart_token(os.path.dirname(os.path.abspath(self.args.inbox)))
            self.restart_pending = True
            print(f"[train] restart requested (token {token}); waiting up to {self.args.restart_timeout}s for the new match to start...")
            threading.Timer(self.args.restart_timeout, self.restart_watchdog).start()

    def restart_watchdog(self):
        """Called some seconds after a restart request: if no new match has started, say exactly what to check."""
        if not self.restart_pending:
            return
        print("\n" + "=" * 78)
        print(" THE MATCH DID NOT RESTART within %ds. The playbook IS saved - nothing is lost." % self.args.restart_timeout)
        print(" Look at the [game] lines above / the game log:")
        print("   - 'LLMC|I|UI restart watcher started'   missing -> the UI hook (hook/lua/UserSync.lua) is not loaded in your LOUD;")
        print("                                                     is the mod enabled, and does LOUD's /lua/UserSync.lua have an OnSync()?")
        print("   - 'LLMC|I|Restart requested ... calling RestartSession()' present but no restart -> RestartSession() ran and did nothing;")
        print("   - 'LLMC|I|ERR RestartSession() failed: ...'  -> the error text says why (e.g. the function does not exist in that state);")
        print("   - none of the above after the episode ended -> the UI watcher cannot read bridge/restart.lua (file access).")
        print(" For now start a new match yourself (the bridge continues automatically), or use --restart-cmd / --restart-fallback-cmd.")
        print("=" * 78 + "\n")
        if self.args.restart_fallback_cmd:
            print("[train] running the fallback restart command:", self.args.restart_fallback_cmd)
            try:
                subprocess.Popen(self.args.restart_fallback_cmd, shell=True)
            except OSError as e:
                print("[train] fallback restart command failed:", e)
        self.restart_pending = False

    def worker(self):
        while True:
            with self.cv:
                while self.pending_end is None and (self.latest is None or self.latest[0] <= self.done):
                    self.cv.wait()
                end = self.pending_end
                self.pending_end = None
                seq, state = (None, None) if end is not None else self.latest
            if end is not None:
                try:
                    self.handle_episode_end(end)
                except Exception as e:
                    print(f"[train] episode end handling failed: {type(e).__name__}: {e}")
                continue

            train = state.get("mode") == "train"
            if train:
                tr = self.get_trainer()
                tr.begin(state.get("sid"))
                tr.on_state(state)                     # reward of the previous step arrives with this state
            t0 = time.time()
            try:
                thoughts, notes, acts, warnings = self.decide(state)
            except Exception as e:  # network error, bad JSON, ...
                print(f"[bridge] turn {seq}: LLM call failed: {type(e).__name__}: {e}")
                write_inbox(self.args.inbox, state.get("sid", 0), seq, [],
                            [f"your last reply was unusable ({str(e)[:60]}); reply with ONE valid JSON object"])
                self.done = seq
                continue
            self.done = seq
            with self.cv:
                ended = self.pending_end is not None
            if ended:                                   # the episode finished while the model was thinking
                continue
            if notes:
                self.notes = notes
            self.prev_actions = acts
            if train:
                self.trainer.record(state, self.last_system, self.last_user, self.last_raw, thoughts, notes, acts)
            write_inbox(self.args.inbox, state.get("sid", 0), seq, acts, warnings)
            print(f"[bridge] turn {seq} (game t={state.get('t')}s) {time.time() - t0:.1f}s, {len(acts)} actions")
            if thoughts:
                print("         thoughts:", thoughts)
            for w in warnings:
                print("         warning:", w)
            if self.args.verbose:
                print("         ", json.dumps(acts))

    def run(self):
        a = self.args
        log = a.log
        if not log:
            for c in default_log_candidates():
                if os.path.exists(c):
                    log = c
                    break
        if not log:
            sys.exit("Could not find the game log. Pass --log <path> (the file given to the game with /log).")
        if not os.path.exists(a.inbox):
            sys.exit(f"inbox file not found: {a.inbox}\nPass --inbox <path to LLMCommander/bridge/inbox.lua>")
        print(f"[bridge] llm_bridge v{BRIDGE_VERSION}\n[bridge] log:    {log}\n[bridge] inbox:  {a.inbox}\n[bridge] server: {a.server}")
        threading.Thread(target=self.worker, daemon=True).start()
        for line in tail_lines(log, from_start=a.from_start):
            self.asm.feed(line)


def selftest(args):
    b = Bridge(args)
    print("Sending a sample state to", args.server, "...")
    t0 = time.time()
    thoughts, notes, acts, warnings = b.decide(SAMPLE_TRAIN_STATE if args.selftest_mode == "train" else ((SAMPLE_ARMY_STATE if args.selftest_mode == "army" else dict(SAMPLE_MICRO_STATE, mode=args.selftest_mode)) if args.selftest_mode in ("micro", "sacu", "army") else SAMPLE_STATE))
    print(f"reply in {time.time() - t0:.1f}s\nthoughts: {thoughts}\nnotes: {notes}\nactions:")
    for x in acts:
        print("  ", json.dumps(x))
    for w in warnings:
        print("warning:", w)
    print("\nLua that would be written to inbox.lua:\n" + "LLMC_INBOX = { actions = %s }" % lua(acts))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description="LLM Commander bridge for SupCom FA / LOUD")
    p.add_argument("--log", help="game log file (the one passed to the game with /log). Default: auto-detect game.log")
    p.add_argument("--inbox", default=os.path.join(here, "inbox.lua"), help="path to LLMCommander/bridge/inbox.lua")
    p.add_argument("--server", default="http://127.0.0.1:8080/v1", help="OpenAI-compatible base URL (llama-server, Ollama: http://localhost:11434/v1, LM Studio: http://localhost:1234/v1)")
    p.add_argument("--model", default="", help="model name (needed by Ollama / LM Studio, ignored by llama-server)")
    p.add_argument("--api-key", default="")
    p.add_argument("--temperature", type=float, default=0.4)
    p.add_argument("--max-tokens", type=int, default=2500)
    p.add_argument("--timeout", type=float, default=300)
    p.add_argument("--max-actions", type=int, default=24)
    p.add_argument("--no-json-mode", action="store_true", help="do not send response_format=json_object")
    p.add_argument("--extra-system", help="text file appended to the system prompt (e.g. '/no_think' or personality)")
    p.add_argument("--from-start", action="store_true", help="read the log from its beginning instead of its end")
    p.add_argument("--mode", choices=[m[0] for m in menu.MODES], default=None, help="skip the menu and run this mode (the choice is written to bridge/mode.lua for the game)")
    p.add_argument("--no-menu", action="store_true", help="do not show the start-up menu; leave the game on its configured mode")
    p.add_argument("--menu", action="store_true", help="show the menu even when stdin is not a terminal")
    p.add_argument("--train-dir", default=os.path.join(here, "train"), help="TRAIN mode: where episode logs, lessons.json, stats.csv and dataset.jsonl go")
    p.add_argument("--temp-start", type=float, default=0.9, help="TRAIN: sampling temperature in the first episode (exploration)")
    p.add_argument("--temp-end", type=float, default=0.3, help="TRAIN: temperature after --temp-episodes episodes (exploitation)")
    p.add_argument("--temp-episodes", type=int, default=30)
    p.add_argument("--gamma", type=float, default=0.97, help="TRAIN: discount for the logged return-to-go")
    p.add_argument("--restart-cmd", default="", help="TRAIN: shell command that restarts the match after an episode (see README)")
    p.add_argument("--reset-lessons", action="store_true", help="TRAIN: delete the saved playbook (lessons.json, best.json) before starting; episode logs and stats are kept")
    p.add_argument("--restart-timeout", type=int, default=90, help="TRAIN: seconds to wait for the match to restart before explaining what to check")
    p.add_argument("--restart-fallback-cmd", default="", help="TRAIN: command to run if the automatic in-game restart did not happen within --restart-timeout")
    p.add_argument("--no-game-restart", action="store_true", help="TRAIN: do not let the mod restart the match with RestartSession() after an episode")
    p.add_argument("--max-episodes", type=int, default=0, help="TRAIN: stop after this many episodes (0 = never)")
    p.add_argument("--selftest-mode", choices=["micro", "sacu", "army", "train", "full"], default="micro", help="which game mode the --selftest sample state is for")
    p.add_argument("--selftest", action="store_true", help="query the LLM once with a sample state and exit")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    if args.selftest:
        selftest(args)
    else:
        interactive = args.menu or (sys.stdin.isatty() and args.mode is None and not args.no_menu)
        if interactive and not menu.run_menu(args, here):
            print("bye")
            return
        if args.mode:
            path = menu.write_mode(os.path.dirname(os.path.abspath(args.inbox)), args.mode)
            menu.after_selection_notice(args.mode, path)
        bridge = None
        try:
            bridge = Bridge(args)
            bridge.run()
        except KeyboardInterrupt:
            print("\n[bridge] bye")
            if bridge is not None and bridge.trainer is not None:
                print("[train] stopped. Playbook: %s\n[train] To resume in a new session, run the same command again:\n   %s" % (
                    os.path.abspath(bridge.trainer.lessons_path), bridge.trainer.resume_command()))


if __name__ == "__main__":
    main()
