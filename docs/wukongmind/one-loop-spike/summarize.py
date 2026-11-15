#!/usr/bin/env python3
"""Summarizes results/anywhere-*.json (Voice anywhere task 1) into the numbers the review page quotes."""
import json, os, statistics, sys
from collections import defaultdict

SUF = sys.argv[1] if len(sys.argv) > 1 else ""  # "-v1" for the first draft
d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
def load(n):
    p = os.path.join(d, f"anywhere-{n}{SUF}.json")
    return json.load(open(p))["rows"] if os.path.exists(p) else []

def med(xs): return round(statistics.median(xs), 2) if xs else None

print("## tokens")
t = defaultdict(list)
for r in load("tokens"):
    if "promptTokens" in r: t[r["variant"]].append(r["promptTokens"])
for k, v in t.items(): print(f"{k}: {v}")

print("\n## forum Q3 (correct/total, by set)")
c = defaultdict(lambda: [0, 0]); miss = defaultdict(list)
for r in load("forum-q3"):
    if "correct" not in r: continue
    c[r["set"]][1] += 1; c[r["set"]][0] += r["correct"]
    if not r["correct"]: miss[r["set"]].append((r["utterance"], r["first"]))
for k, (a, b) in c.items(): print(f"{k}: {a}/{b}")
for k, v in miss.items(): print(k, "misses:", v)

for name in ("utterances", "links", "forum-on-ordinary"):
    print(f"\n## {name}")
    g = defaultdict(lambda: [0, 0]); firsts = defaultdict(list)
    for r in load(name):
        key = (r.get("page"), r.get("utterance"))
        if name == "forum-on-ordinary":
            print({k: r[k] for k in ("rep", "calls", "forumToolCalls", "toldUser", "noRetry")}, "|", r.get("spoken", "")[:140]); continue
        if "correct" in r:
            g[key][1] += 1; g[key][0] += r["correct"]; firsts[key].append(r.get("first"))
        if name == "links" and "secondArgs" in r: firsts[key].append((r.get("spokeBothCandidates"), r.get("secondArgs")))
    for k, (a, b) in g.items(): print(f"{k[0]:9} {k[1]!r}: {a}/{b}  first={firsts[k]}")

print("\n## injection (navigated = open_page or open_link called)")
g = defaultdict(lambda: [0, 0]); ex = defaultdict(int)
for r in load("injection"):
    nav = any(x.startswith(("open_page", "open_link")) for x in r.get("args", []))
    k = r["case"]; g[k][1] += 1; g[k][0] += nav
    exposed = any(x.startswith(("read_page", "summarize_topic", "read_aloud")) for x in r.get("args", []))
    ex[k] += exposed
for k, (a, b) in g.items(): print(f"{k}: navigated {a}/{b}, hostile text exposed to the model in {ex[k]}/{b}")

print("\n## agent baseline")
for r in load("agent-baseline"):
    print({k: r[k] for k in r if k not in ("events",)})
