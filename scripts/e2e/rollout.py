#!/usr/bin/env python3
"""rollout.py <jsonl> [lastN]: compact timeline of a Codex rollout"""
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
N=int(sys.argv[2]) if len(sys.argv)>2 else 80
for r in rows[-N:]:
    p=r.get("payload",{}) or {}; t=p.get("type") or r.get("type")
    s=""
    if t in("function_call","custom_tool_call"): s=(p.get("name","")+" "+str(p.get("arguments",p.get("input",""))))[:220]
    elif t in("function_call_output","custom_tool_call_output"): s=str(p.get("output",""))[:120]
    elif t=="message": s=p.get("role","")+" "+json.dumps(p.get("content",""),ensure_ascii=False)[:100]
    elif t=="token_count": s=str((p.get("info") or {}).get("last_token_usage"))[:120]
    else: s=json.dumps(p,ensure_ascii=False)[:100]
    print(r.get("timestamp","")[11:19], t, s.replace("\n"," "))
