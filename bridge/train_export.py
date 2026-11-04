#!/usr/bin/env python3
"""
Turn TRAIN-mode logs into a fine-tuning dataset (rejection-sampling SFT / "best-of-N distillation").

llm_bridge.py in train mode writes train/dataset.jsonl (every step: prompt, the model's raw reply, step reward,
return-to-go, episode return, result) and train/stats.csv. This script keeps only the good behaviour:
  * episodes in the top --top fraction by return (or only wins with --wins-only)
  * steps whose return-to-go is at least --min-rtg
and writes chat-format JSONL ({"messages":[system,user,assistant]}) that LoRA trainers (Unsloth, axolotl, llama-factory, ...)
accept. Train the adapter OUTSIDE the game (llama.cpp's server cannot learn online), convert/merge to GGUF, serve it,
and run more episodes with the new model. Python 3.8+, standard library only.

  python train_export.py --train-dir train --top 0.3 --min-rtg 20 --out sft.jsonl
"""
import argparse
import csv
import json
import os


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser()
    p.add_argument("--train-dir", default=os.path.join(here, "train"))
    p.add_argument("--top", type=float, default=0.3, help="keep the best this fraction of episodes by return")
    p.add_argument("--wins-only", action="store_true")
    p.add_argument("--min-rtg", type=float, default=0.0, help="drop steps whose return-to-go is below this")
    p.add_argument("--out", default="sft.jsonl")
    a = p.parse_args()

    rows = []
    with open(os.path.join(a.train_dir, "stats.csv"), newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append((int(r["episode"]), float(r["total"]), r["result"]))
    if a.wins_only:
        rows = [r for r in rows if r[2] == "win"]
    rows.sort(key=lambda r: -r[1])
    keep = {r[0] for r in rows[:max(1, int(round(len(rows) * a.top)))]} if rows else set()
    print("episodes kept:", sorted(keep))

    prompts, n = {}, 0
    with open(os.path.join(a.train_dir, "dataset.jsonl"), encoding="utf-8") as src, open(a.out, "w", encoding="utf-8") as dst:
        for line in src:
            d = json.loads(line)
            if d["ep"] not in keep or d["return_to_go"] < a.min_rtg or not d.get("completion"):
                continue
            sid = d["sys_id"]
            if sid not in prompts:
                with open(os.path.join(a.train_dir, "prompts", sid + ".txt"), encoding="utf-8") as pf:
                    prompts[sid] = pf.read()
            dst.write(json.dumps({"messages": [
                {"role": "system", "content": prompts[sid]},
                {"role": "user", "content": d["user"]},
                {"role": "assistant", "content": d["completion"]},
            ], "meta": {"episode": d["ep"], "return_to_go": d["return_to_go"], "ep_return": d["ep_return"]}}, ensure_ascii=False) + "\n")
            n += 1
    print("wrote %d training examples to %s" % (n, a.out))


if __name__ == "__main__":
    main()
