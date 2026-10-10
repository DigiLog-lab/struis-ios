#!/usr/bin/env python3
"""Find waits where the screen text did not change for more than N seconds.
usage: gaps.py watch.tsv [N] [--ignore-counters]
--ignore-counters: an elapsed-seconds counter ("12秒", "1:05") alone does not count as new information (W11)."""
import sys, re
args=[a for a in sys.argv[1:] if not a.startswith("--")]
ignore="--ignore-counters" in sys.argv
N=float(args[1]) if len(args)>1 else 10
def norm(s):
    if not ignore: return s
    s=re.sub(r"\d+\s*秒","#秒",s)
    return re.sub(r"\b\d{1,2}:\d{2}\b","#:##",s)
rows=[l.rstrip("\n").split("\t",2) for l in open(args[0])]
start=None; prev=None
for t,i,txt in rows:
    key=norm(txt); t=float(t)
    if prev is None or key!=prev[2]:
        if start and prev[0]-start[0]>N:
            print(f"GAP {prev[0]-start[0]:.0f}s frames {start[1]}-{prev[1]}: {start[3][:160]}")
        start=(t,i,key,txt)
    prev=(t,i,key)
if start and prev[0]-start[0]>N: print(f"GAP(open) {prev[0]-start[0]:.0f}s frames {start[1]}-{prev[1]}: {start[3][:160]}")
