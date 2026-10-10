#!/usr/bin/env python3
"""Send one command to E2EDriverUITests. usage: ui.py op [key=value ...]"""
import json, sys, time, os
D=os.environ.get("DRV",os.path.join(os.environ["E2E_DIR"],"drv"))
seqf=os.path.join(D,"seq")
seq=int(open(seqf).read()) + 1 if os.path.exists(seqf) else 1
open(seqf,"w").write(str(seq))
cmd={"seq":seq,"op":sys.argv[1]}
for a in sys.argv[2:]:
    k,v=a.split("=",1)
    try: v=float(v) if k in ("x","y","x2","y2","duration","timeout") else v
    except: pass
    cmd[k]=v
tmp=os.path.join(D,"cmd.json.tmp"); json.dump(cmd,open(tmp,"w"),ensure_ascii=False); os.rename(tmp,os.path.join(D,"cmd.json"))
deadline=time.time()+float(cmd.get("timeout",30))+120
while time.time()<deadline:
    try:
        r=open(os.path.join(D,"result.txt")).read()
        if r.startswith(f"{seq} "): print(r[len(str(seq))+1:]); sys.exit(0)
    except FileNotFoundError: pass
    time.sleep(0.2)
print("TIMEOUT"); sys.exit(1)
