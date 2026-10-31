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
import sys
import threading
import time
import urllib.error
import urllib.request

PREFIX = b"LLMC|"

ALLOWED_ACTIONS = {
    "build", "produce", "upgrade", "assist", "reclaim", "enhance",
    "attack", "move", "patrol", "retreat", "stop", "scout", "rally", "strategy",
}

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
 {"a":"assist","target":"<factory id>","n":3}        idle-ish engineers help build/upgrade something
 {"a":"reclaim","near":[x,z],"radius":40,"n":2}      engineers reclaim wrecks/trees for resources
 {"a":"enhance","name":"<name from state.acu.enhancements>"}
 {"a":"attack","squad":SQUAD,"x":X,"z":Z,"fraction":1.0}   attack-move; also "move", "patrol"; "points":[[x,z],[x,z]] for several waypoints; "queue":true to append
 {"a":"retreat","squad":SQUAD}   {"a":"stop","squad":SQUAD}   {"a":"scout","x":X,"z":Z}   {"a":"rally","factory":"all","x":X,"z":Z}
     SQUAD = land fighters bombers gunships naval air scouts all   (engineers and the ACU are never in squads)

RULES
- Coordinates are world [x, z]. Use state.free_mass / free_hydro / contacts / enemy_starts / base for positions.
- Unit ids in the state are strings; copy them exactly.
- Do not repeat orders that are already in progress (check factories[].queue, engineers.idle, structures counts).
- Read state.last_results: it tells you which of your last orders failed and why.
- ECONOMY-ONLY OPENING: while state.economy_only_until is present (first 5 game minutes) only mex, hydro, pgen, fabricator, storage, engineers and mex upgrades work; everything else is refused. Focus on economy and use the time to plan.
- Factory upgrades are refused unless ALL mass extractors are already at the next tier (none upgrading) and energy storage is full; upgrade the mex first, then the factory, then build the higher-tier units.
- Buildings other than mex/hydro/pgen/fabricator/storage are refused while stored mass or energy is low (see last_results); build economy first, then retry.
- Spend resources: if mass or energy is piling up, build more; if one is at zero, build more of that producer first.
- Scout with a cheap scout unit early; attack only with a clearly strong force; retreat if state.under_attack and your army is weak.
- Never output anything except the JSON object."""

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


class Assembler:
    """Collects  LLMC|S|seq|part|total|payload  chunks into whole messages."""

    def __init__(self, on_state, on_info, on_ack):
        self.parts = {}
        self.on_state, self.on_info, self.on_ack = on_state, on_info, on_ack

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
            elif tag == b"S":
                f = rest.split(b"|", 4)
                seq, part, total, payload = int(f[1]), int(f[2]), int(f[3]), f[4]
                d = self.parts.setdefault(seq, {})
                d[part] = payload
                if len(d) == total:
                    blob = b"".join(d[k] for k in sorted(d))
                    del self.parts[seq]
                    for old in [s for s in self.parts if s < seq - 3]:
                        del self.parts[old]
                    self.on_state(seq, json.loads(blob.decode("utf-8", "replace")))
        except (ValueError, IndexError, KeyError) as e:
            print(f"[bridge] bad log line ignored ({e})")


# ------------------------------------------------------------------------------------------------
# LLM client
# ------------------------------------------------------------------------------------------------
class LLM:
    def __init__(self, args):
        self.args = args
        self.json_mode = not args.no_json_mode

    def chat(self, messages):
        a = self.args
        body = {"messages": messages, "temperature": a.temperature, "max_tokens": a.max_tokens, "stream": False}
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
                data = json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 400 and self.json_mode:
                print("[bridge] server rejected response_format; retrying without JSON mode")
                self.json_mode = False
                return self.chat(messages)
            raise
        return data["choices"][0]["message"].get("content") or ""


def extract_json(text):
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m:
        text = m.group(1)
    s, e = text.find("{"), text.rfind("}")
    if s < 0 or e <= s:
        raise ValueError("no JSON object in reply")
    raw = text[s:e + 1]
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return json.loads(re.sub(r",\s*([}\]])", r"\1", raw))  # trailing commas


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


def sanitize_actions(raw, warnings, limit):
    acts = []
    if not isinstance(raw, list):
        warnings.append("actions must be a list")
        return acts
    for i, a in enumerate(raw[:limit]):
        if not isinstance(a, dict) or a.get("a") not in ALLOWED_ACTIONS:
            warnings.append(f"action {i + 1} dropped: unknown or malformed ({str(a)[:50]})")
            continue
        acts.append(clean(a))
    if len(raw) > limit:
        warnings.append(f"only the first {limit} actions were kept")
    return acts


def write_inbox(path, sid, seq, actions, warnings):
    text = "LLMC_INBOX = { sid = %s, seq = %d, actions = %s, warnings = %s }\n" % (
        lua(sid), seq, lua(actions), lua([w[:100] for w in warnings[:10]]))
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
        self.asm = Assembler(self.on_state, self.on_info, self.on_ack)
        self.last_ack = 0

    def on_info(self, text):
        print("[game]", text)
        if text.startswith("START"):
            self.notes, self.prev_actions, self.last_ack = "", [], 0
            with self.cv:
                self.latest = None
            write_inbox(self.args.inbox, 0, 0, [], [])  # clear stale orders from a previous game

    def on_ack(self, seq, count):
        self.last_ack = seq
        print(f"[game] executed orders for turn {seq} ({count} actions)")

    def on_state(self, seq, state):
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
        sysmsg = SYSTEM_PROMPT + (("\n\n" + self.extra) if self.extra else "")
        return [{"role": "system", "content": sysmsg}, {"role": "user", "content": user}]

    def decide(self, state):
        """One LLM round-trip -> (thoughts, notes, actions, warnings)."""
        warnings = []
        text = self.llm.chat(self.messages(state))
        try:
            obj = extract_json(text)
        except ValueError as e:
            if self.args.verbose:
                print("[llm raw]", text[:800])
            raise
        acts = sanitize_actions(obj.get("actions", []), warnings, self.args.max_actions)
        notes = str(obj.get("notes", ""))[:400]
        return str(obj.get("thoughts", ""))[:300], notes, acts, warnings

    def worker(self):
        done = 0
        while True:
            with self.cv:
                while self.latest is None or self.latest[0] <= done:
                    self.cv.wait()
                seq, state = self.latest
            t0 = time.time()
            try:
                thoughts, notes, acts, warnings = self.decide(state)
            except Exception as e:  # network error, bad JSON, ...
                print(f"[bridge] turn {seq}: LLM call failed: {e}")
                write_inbox(self.args.inbox, state.get("sid", 0), seq, [],
                            [f"your last reply was unusable ({str(e)[:60]}); reply with ONE valid JSON object"])
                done = seq
                continue
            done = seq
            if notes:
                self.notes = notes
            self.prev_actions = acts
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
        print(f"[bridge] log:    {log}\n[bridge] inbox:  {a.inbox}\n[bridge] server: {a.server}")
        threading.Thread(target=self.worker, daemon=True).start()
        for line in tail_lines(log, from_start=a.from_start):
            self.asm.feed(line)


def selftest(args):
    b = Bridge(args)
    print("Sending a sample state to", args.server, "...")
    t0 = time.time()
    thoughts, notes, acts, warnings = b.decide(SAMPLE_STATE)
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
    p.add_argument("--max-tokens", type=int, default=1200)
    p.add_argument("--timeout", type=float, default=300)
    p.add_argument("--max-actions", type=int, default=24)
    p.add_argument("--no-json-mode", action="store_true", help="do not send response_format=json_object")
    p.add_argument("--extra-system", help="text file appended to the system prompt (e.g. '/no_think' or personality)")
    p.add_argument("--from-start", action="store_true", help="read the log from its beginning instead of its end")
    p.add_argument("--selftest", action="store_true", help="query the LLM once with a sample state and exit")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    if args.selftest:
        selftest(args)
    else:
        try:
            Bridge(args).run()
        except KeyboardInterrupt:
            print("\n[bridge] bye")


if __name__ == "__main__":
    main()
