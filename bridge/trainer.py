"""
LLM Commander :: TRAIN mode bookkeeping (episode logs, lessons, reflection, dataset).

A llama.cpp / Ollama server cannot update its own weights while it serves requests, so "learning" happens in two ways:
  1. IN-CONTEXT (automatic, every episode): after each episode the model reflects on what the reward function
     said, and rewrites a compact playbook (train/lessons.json). The playbook, an experiment to try, and the best run
     so far are put in the prompt of every later turn. This is trial-and-error learning without touching weights.
  2. OFFLINE (optional): every step is logged with its reward and return-to-go (train/dataset.jsonl); train_export.py
     turns the best episodes into a fine-tuning dataset (rejection-sampling SFT) for LoRA training elsewhere.
"""
import csv
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time


def _load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def act_summary(acts, limit=6):
    """['build mex x2', 'produce tank x5', ...] -- short text of an action list."""
    out = []
    for a in (acts or [])[:limit]:
        what = a.get("what") or a.get("cmd") or a.get("squad") or a.get("name") or ""
        n = a.get("n")
        out.append(("%s %s%s" % (a.get("a", "?"), what, (" x%g" % n) if isinstance(n, (int, float)) else "")).strip())
    if len(acts or []) > limit:
        out.append("+%d more" % (len(acts) - limit))
    return ", ".join(out)


REFLECT_SYSTEM = """You are the learning module of an agent that plays Supreme Commander: Forged Alliance (LOUD) by trial and error.
After every episode you get the result, the reward breakdown and a timeline of what the agent did. Your job is to improve the agent's PLAYBOOK for the next episode.
Rules:
- The goal is to WIN: destroy the enemy army as fast as possible. Games last 20-30 minutes (short) up to 1-3 hours (long) and the opponent gets tougher the longer the game runs, so EARLY wins are worth the most (a speed bonus up to +300 on top of +500); a long game is a warning sign - write rules about what to do earlier. A win is worth +500 and a loss -500; economy points are scaled down and capped, so they only matter as a means to a stronger army. Reward earned by exploiting the reward function without actually playing to win (for example spamming the cheapest units, or stalling) must be called out as a mistake, with a rule to avoid it. When the agent lost or timed out, work out WHY (too passive, attacked too early/late, lost its commander, weak economy) and write rules that fix that.
- Keep rules that appear to have helped, REMOVE or rewrite rules that correlate with worse returns, add what the timeline suggests (build orders, timings, when to attack, what to avoid).
- Be concrete and short: imperative sentences with numbers/timings (game seconds) where possible.
- Propose ONE experiment for the next episode (a deliberate change to learn from).
Reply with ONLY one JSON object:
{"lessons": ["<=14 short rules"], "avoid": ["<=8 short mistakes to avoid"], "next_experiment": "<one sentence>", "analysis": "<=2 sentences"}"""


class Trainer:
    def __init__(self, args, parse_json):
        self.args = args
        self.parse = parse_json
        self.dir = args.train_dir
        os.makedirs(os.path.join(self.dir, "episodes"), exist_ok=True)
        os.makedirs(os.path.join(self.dir, "prompts"), exist_ok=True)
        self.lessons_path = os.path.join(self.dir, "lessons.json")
        self.best_path = os.path.join(self.dir, "best.json")
        self.stats_path = os.path.join(self.dir, "stats.csv")
        self.dataset_path = os.path.join(self.dir, "dataset.jsonl")
        self.lessons = _load(self.lessons_path, {"lessons": [], "avoid": [], "next_experiment": "", "analysis": "", "after_episode": 0})
        self.best = _load(self.best_path, None)
        self.returns = self._read_returns()
        self.episode = len(self.returns) + 1
        self.steps = []
        self.active = False
        self.sid = None
        self.last = None                 # summary of the most recently finished episode
        self.log_path = os.path.join(self.dir, "train.log")

    # ------------------------------------------------------------------ persistence helpers
    def _read_returns(self):
        out = []
        try:
            with open(self.stats_path, newline="", encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    out.append(float(row["total"]))
        except (OSError, ValueError, KeyError):
            pass
        return out

    def _ep_path(self, n=None):
        return os.path.join(self.dir, "episodes", "ep_%04d.jsonl" % (n or self.episode))

    def _save_prompt(self, text):
        sid = hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:10]
        path = os.path.join(self.dir, "prompts", sid + ".txt")
        if not os.path.exists(path):
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        return sid

    # ------------------------------------------------------------------ exploration + prompt context
    def temperature(self):
        a = self.args
        frac = min(1.0, len(self.returns) / float(max(1, a.temp_episodes)))
        return round(a.temp_start + (a.temp_end - a.temp_start) * frac, 3)

    def context_text(self):
        L = self.lessons
        parts = ["TRAINING CONTEXT - you are learning this game by trial and error; this is episode %d (%d finished so far)." % (self.episode, len(self.returns))]
        if self.returns:
            parts.append("Returns of recent episodes: " + ", ".join("%g" % r for r in self.returns[-6:]) + ("  (best %g)" % max(self.returns)))
        if L.get("lessons"):
            parts.append("LESSONS FROM PREVIOUS EPISODES (follow them unless the situation clearly says otherwise):\n" + "\n".join("- " + x for x in L["lessons"]))
        if L.get("avoid"):
            parts.append("AVOID:\n" + "\n".join("- " + x for x in L["avoid"]))
        if L.get("next_experiment"):
            parts.append("EXPERIMENT FOR THIS EPISODE (try it deliberately, so the result teaches something): " + L["next_experiment"])
        b = self.best
        if b:
            parts.append("BEST RUN SO FAR: episode %s, return %g, %s after %ss. Its opening: %s" % (
                b.get("episode"), b.get("total", 0), b.get("result"), b.get("time"), " | ".join(b.get("opening", []))))
        return "\n\n".join(parts)

    # ------------------------------------------------------------------ episode lifecycle
    def begin(self, sid):
        if self.active and self.sid == sid:
            return
        if self.active:
            print("[train] previous episode was interrupted (no episode-end message); discarding it")
        self.active, self.sid, self.steps = True, sid, []
        self.episode = len(self.returns) + 1
        open(self._ep_path(), "w").close()
        print("[train] === episode %d starts (temperature %.2f) ===" % (self.episode, self.temperature()))

    def on_state(self, state):
        """A new observation arrived: its reward is the outcome of the previous step's orders."""
        r = state.get("reward") or {}
        if self.steps and self.steps[-1].get("reward_after") is None:
            s = self.steps[-1]
            s["reward_after"] = r.get("step", 0)
            s["parts"] = r.get("parts", {})
            with open(self._ep_path(), "a", encoding="utf-8") as f:
                f.write(json.dumps(s, ensure_ascii=False) + "\n")
            print("[train] step %s reward %+g  %s" % (s["seq"], s["reward_after"], json.dumps(s["parts"]) if s["parts"] else ""))

    def record(self, state, system, user, raw, thoughts, notes, acts):
        self.steps.append({
            "ep": self.episode, "seq": state.get("seq"), "t": state.get("t"), "sys_id": self._save_prompt(system),
            "user": user, "completion": raw, "thoughts": thoughts, "notes": notes, "actions": acts,
            "reward_after": None, "parts": {},
        })

    def end_episode(self, summary, llm):
        """Episode finished (an army was destroyed): finalise logs, update stats, reflect, save lessons."""
        if not self.active:
            return
        s = self.steps
        if s and s[-1].get("reward_after") is None:
            s[-1]["reward_after"] = summary.get("last_step", 0)
        total = float(summary.get("total", sum(x.get("reward_after") or 0 for x in s)))
        result = summary.get("result", "?")
        # return-to-go
        G = 0.0
        for x in reversed(s):
            G = (x.get("reward_after") or 0) + self.args.gamma * G
            x["return_to_go"] = round(G, 2)
        with open(self._ep_path(), "w", encoding="utf-8") as f:
            for x in s:
                f.write(json.dumps(x, ensure_ascii=False) + "\n")
        with open(self.dataset_path, "a", encoding="utf-8") as f:
            for x in s:
                f.write(json.dumps({
                    "ep": x["ep"], "seq": x["seq"], "sys_id": x["sys_id"], "user": x["user"], "completion": x["completion"],
                    "step_reward": x.get("reward_after"), "return_to_go": x["return_to_go"], "ep_return": total, "result": result,
                }, ensure_ascii=False) + "\n")
        counts = summary.get("counts", {})
        new_file = not os.path.exists(self.stats_path)
        with open(self.stats_path, "a", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            if new_file:
                w.writerow(["episode", "result", "total", "game_seconds", "steps", "kills", "t4_kills", "units_built", "t4_built", "units_lost", "buildings_lost", "mex_lost", "when"])
            w.writerow([self.episode, result, total, summary.get("time"), len(s),
                        counts.get("kill", 0) + counts.get("kill_artillery", 0) + counts.get("kill_nuke", 0) + counts.get("kill_t4", 0),
                        counts.get("kill_t4", 0), counts.get("built_unit", 0), counts.get("built_t4", 0),
                        counts.get("lost_unit", 0), counts.get("lost_building", 0), counts.get("lost_mex", 0), time.strftime("%Y-%m-%d %H:%M:%S")])
        self.last = {"episode": self.episode, "result": result, "total": total, "time": summary.get("time"), "steps": len(s)}
        print("[train] === episode %d over: %s, return %g after %ss, %d steps ===" % (self.episode, result, total, summary.get("time"), len(s)))
        print("[train] reward breakdown:", json.dumps(summary.get("parts", {})))

        if self.best is None or total > self.best.get("total", -1e18):
            self.best = {"episode": self.episode, "total": total, "result": result, "time": summary.get("time"),
                         "opening": ["t=%s: %s" % (x["t"], act_summary(x["actions"], 5)) for x in s[:8]]}
            _save(self.best_path, self.best)
            print("[train] new best run!")

        try:
            self._reflect(llm, summary, total, result)
        except Exception as e:
            print("[train] reflection failed (%s: %s); keeping the old lessons" % (type(e).__name__, e))
        self.returns.append(total)
        self.active = False

    # ------------------------------------------------------------------ end-of-episode announcement
    @staticmethod
    def resume_command():
        """The command line this bridge was started with, so it can be pasted into a new session."""
        # --from-start would replay the old log (and old episode-end messages) in a new session, so leave it out
        argv = [os.path.abspath(sys.argv[0])] + [x for x in sys.argv[1:] if x != "--from-start"]
        py = "python"
        if os.name == "nt":
            return py + " " + subprocess.list2cmdline(argv)
        return py + " " + " ".join(shlex.quote(a) for a in argv)

    def banner(self, next_action):
        """Multi-line text announcing the end of an episode: where everything is saved, how to resume, what to do next."""
        L, last = self.lessons, self.last or {}
        d = os.path.abspath(self.dir)
        bar = "=" * 78
        lines = [
            bar,
            " EPISODE %s HAS ENDED  -  %s, return %g, %s game seconds, %s steps" % (
                last.get("episode", "?"), last.get("result", "?"), last.get("total", 0), last.get("time", "?"), last.get("steps", "?")),
            "-" * 78,
            " PLAYBOOK (lessons) saved at : " + os.path.join(d, "lessons.json"),
            "                               %d lessons, %d things to avoid" % (len(L.get("lessons", [])), len(L.get("avoid", []))),
            " Next experiment             : " + (L.get("next_experiment") or "(none)"),
            " This episode's step log     : " + os.path.join(d, "episodes", "ep_%04d.jsonl" % last.get("episode", 0)),
            " Also saved in that folder   : stats.csv (all episodes), best.json (best run), dataset.jsonl (fine-tuning data), train.log (this log)",
            "",
            " HOW TO RESUME IN A NEW SESSION: start your LLM server, then run the SAME command again (keep the same --train-dir):",
            "   " + self.resume_command(),
            "   It loads the saved playbook and carries on at episode %d. (Delete the train folder to start learning from scratch.)" % (len(self.returns) + 1),
            "",
            " " + next_action,
            bar,
        ]
        return "\n".join(lines)

    def announce(self, next_action):
        text = self.banner(next_action)
        print("\n" + text + "\n")
        try:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S") + "\n" + text + "\n\n")
        except OSError:
            pass

    # ------------------------------------------------------------------ reflection
    def _timeline(self):
        """Reward/action summary per time bucket; buckets grow for long games so the text stays short (~30 buckets)."""
        total_t = max([x.get("t") or 0 for x in self.steps] + [1])
        span = max(120, int(-(-total_t // 30 // 60)) * 60)          # seconds per bucket, a multiple of 60
        buckets = {}
        for x in self.steps:
            b = int((x.get("t") or 0) // span)
            d = buckets.setdefault(b, {"reward": 0.0, "acts": {}})
            d["reward"] += x.get("reward_after") or 0
            for a in x.get("actions") or []:
                k = "%s %s" % (a.get("a"), a.get("what") or a.get("cmd") or a.get("squad") or "")
                d["acts"][k.strip()] = d["acts"].get(k.strip(), 0) + 1
        lines = []
        for b in sorted(buckets):
            d = buckets[b]
            top = sorted(d["acts"].items(), key=lambda kv: -kv[1])[:6]
            lines.append("%d-%d min: reward %+g | %s" % (b * span // 60, (b + 1) * span // 60, d["reward"], ", ".join("%s x%d" % kv for kv in top)))
        return lines

    @staticmethod
    def _fit(payload, limit=9000):
        """JSON text of the payload, thinning the timeline (never cutting the JSON) until it fits."""
        text = json.dumps(payload, separators=(",", ":"))
        tl = payload.get("timeline", [])
        while len(text) > limit and len(tl) > 6:
            del tl[len(tl) // 2]
            text = json.dumps(payload, separators=(",", ":"))
        return text

    def _reflect(self, llm, summary, total, result):
        payload = {
            "episode": self.episode, "result": result, "return": total, "game_seconds": summary.get("time"),
            "reward_totals": summary.get("parts", {}), "reward_event_counts": summary.get("counts", {}),
            "previous_returns": self.returns[-6:], "best_return": max(self.returns + [total]),
            "timeline": self._timeline(),
            "current_playbook": {k: self.lessons.get(k) for k in ("lessons", "avoid", "next_experiment")},
        }
        text = llm.chat([{"role": "system", "content": REFLECT_SYSTEM},
                         {"role": "user", "content": self._fit(payload)}], temperature=0.3)
        obj, _ = self.parse(text)
        new = {
            "lessons": [str(x)[:200] for x in (obj.get("lessons") or [])][:14],
            "avoid": [str(x)[:200] for x in (obj.get("avoid") or [])][:8],
            "next_experiment": str(obj.get("next_experiment", ""))[:260],
            "analysis": str(obj.get("analysis", ""))[:400],
            "after_episode": self.episode,
        }
        if new["lessons"] or new["avoid"]:
            self.lessons = new
            _save(self.lessons_path, new)
        print("[train] analysis:", new["analysis"])
        print("[train] playbook now has %d lessons, %d avoid; next experiment: %s" % (len(new["lessons"]), len(new["avoid"]), new["next_experiment"]))
