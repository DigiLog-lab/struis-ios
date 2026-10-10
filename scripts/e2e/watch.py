#!/usr/bin/env python3
"""Screenshot the simulator every ~2s, OCR it, log (t, text). Stops when STOP file appears.
usage: watch.py <udid> <outdir>"""
import subprocess, sys, time, os, hashlib
udid,out=sys.argv[1],sys.argv[2]; os.makedirs(out,exist_ok=True)
OCR=os.path.join(os.path.dirname(__file__),"ocr")
log=open(os.path.join(out,"watch.tsv"),"a")
i=0
while not os.path.exists(os.path.join(out,"STOP")):
    t=time.time(); p=os.path.join(out,f"w{i:05d}.png")
    subprocess.run(["xcrun","simctl","io",udid,"screenshot",p],capture_output=True)
    txt=subprocess.run([OCR,p],capture_output=True,text=True).stdout.split("\t",1)[-1].strip()
    log.write(f"{t:.1f}\t{i}\t{txt}\n"); log.flush()
    i+=1
    time.sleep(max(0,2-(time.time()-t)))
