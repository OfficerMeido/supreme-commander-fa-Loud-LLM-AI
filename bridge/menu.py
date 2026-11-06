"""
Start-up menu for llm_bridge.py: pick the mode (and the few options that go with it), write it where the mod reads it.

The game decides its mode when a match STARTS: lua/LLMC/Config.lua reads bridge/mode.lua (written here) and lets it override
`Takeover`. So: run the bridge, pick a mode, then start (or restart) the game.
"""
import csv
import json
import os
import sys

MODES = [
    # key, label, description
    ("micro", "Gateway ACUs only", "LOUD plays the whole game; the LLM commands the Quantum Gateway ACUs (defences, Tech 4, mass farms). A rescue watchdog spends floating resources if LOUD stalls."),
    ("sacu", "Gateway ACUs only (strict)", "Same jobs as above, but the mod touches nothing else: no rescue watchdog, slimmer state."),
    ("army", "Army", "LOUD does economy, tech and production; the LLM commands ALL attack units and fights the war."),
    ("replace", "Full game + macro manager", "The slot's built-in AI is switched off; the LLM plays it with the mod's macro manager handling the routine."),
    ("train", "TRAIN (learn by trial and error)", "The LLM plays the whole game with no macro and no rules, is scored by the reward function, reflects after every episode and keeps a playbook."),
    ("overlay", "Overlay (experimental)", "Like Full game, but LOUD's own AI keeps running; they will fight over units."),
]


def mode_file_text(mode):
    return "-- Written by llm_bridge.py (start-up menu). The mod reads this when a match starts.\nLLMC_MODE = { Takeover = '%s' }\n" % mode


def write_mode(bridge_dir, mode):
    path = os.path.join(bridge_dir, "mode.lua")
    with open(path, "w", newline="\n") as f:
        f.write(mode_file_text(mode))
    return path


def _ask(prompt, default=""):
    try:
        ans = input(prompt).strip()
    except EOFError:
        return default
    return ans or default


def _episodes_done(train_dir):
    try:
        with open(os.path.join(train_dir, "stats.csv"), newline="", encoding="utf-8") as f:
            return sum(1 for _ in csv.DictReader(f))
    except OSError:
        return 0


def run_menu(args, here):
    """Interactive menu. Fills args.mode (and, for train mode, args.reset_lessons / max_episodes / restart_cmd). Returns False to quit."""
    last_path = os.path.join(here, "last_mode.json")
    try:
        with open(last_path, encoding="utf-8") as f:
            last = json.load(f).get("mode")
    except (OSError, ValueError):
        last = None
    keys = [m[0] for m in MODES]
    default_idx = keys.index(last) + 1 if last in keys else 1

    bar = "=" * 78
    print("\n" + bar)
    print(" LLM Commander bridge  -  choose what the LLM should do")
    print(bar)
    for i, (k, label, desc) in enumerate(MODES, 1):
        print("  %d) %-32s [%s]" % (i, label, k))
        print("       " + desc)
    print("  q) Quit")
    print("-" * 78)
    while True:
        ans = _ask(" Mode number [Enter = %d]: " % default_idx, str(default_idx)).lower()
        if ans in ("q", "quit", "exit"):
            return False
        if ans.isdigit() and 1 <= int(ans) <= len(MODES):
            mode = keys[int(ans) - 1]
            break
        if ans in keys:
            mode = ans
            break
        print(" Please enter a number from 1 to %d (or q)." % len(MODES))
    args.mode = mode

    if mode == "train":
        n = _episodes_done(args.train_dir)
        print("\n TRAIN mode options")
        if n:
            print("  Found %d finished episode(s) in %s" % (n, os.path.abspath(args.train_dir)))
            c = _ask("  [R]esume with the saved playbook, or [S]tart a fresh playbook (logs are kept)? [R/s]: ", "r").lower()
            args.reset_lessons = c.startswith("s")
        else:
            print("  No earlier episodes found - starting a new training run.")
        m = _ask("  Stop after how many episodes? (0 = never) [%d]: " % args.max_episodes, str(args.max_episodes))
        args.max_episodes = int(m) if m.isdigit() else args.max_episodes
        print("  After each episode the mod restarts the match by itself (RestartSession, the call LOUD's menu uses) once the playbook is saved.")
        r = _ask("  Use an external restart command instead? (blank = no, use the built-in restart) [%s]: " % (args.restart_cmd or "none"), args.restart_cmd)
        args.restart_cmd = r

    try:
        with open(last_path, "w", encoding="utf-8") as f:
            json.dump({"mode": mode}, f)
    except OSError:
        pass
    label = dict((k, l) for k, l, _ in MODES)[mode]
    print("\n Selected: %s [%s]" % (label, mode))
    if mode == "train":
        print("   playbook: %s | episode limit: %s | restart: %s" % (
            "fresh (old one kept as lessons.json.old)" if getattr(args, "reset_lessons", False) else "resume saved playbook",
            args.max_episodes or "none", args.restart_cmd or "automatic (RestartSession)"))
    return True


def after_selection_notice(mode, mode_path):
    print(" Wrote the choice to %s" % mode_path)
    print(" >>> START (or restart) the game now - the mod reads the mode when a match begins. <<<")
    print(" (Waiting for the game; the bridge warns if the running game uses a different mode.)\n")
