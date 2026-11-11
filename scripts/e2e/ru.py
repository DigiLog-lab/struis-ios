#!/usr/bin/env python3
"""ru.py: run the steps (a JSON list on stdin) against RealUsageDriverUITests (claude/real-usage-test only).

Each step is a command for the driver ({"op": "tapid", "id": "..."}), with optional extras handled here:
  "shot": "name"   screenshot after the step (JPEG, long side 1300 px) into $DEVBOX_FILES
  "tree": true     print the list of visible elements after the step (type, id, label, value, frame)
  "settle": 1.5    seconds to wait after the step, before shot/tree
Steps handled here alone: {"op":"shot","name":..}, {"op":"paper","lines":[..]} (the photo the fake camera takes),
{"op":"sh","cmd":".."}.
"""
import json, os, subprocess, sys, time

RU = os.environ.get("RU_DIR") or os.path.join(os.environ["RUNNER_TEMP"], "ru")
DRV = os.path.join(RU, "drv")
OUT = os.environ.get("DEVBOX_FILES") or os.path.join(RU, "out")
UDID = os.environ["SIMULATOR_UDID"] if "RU_UDID" not in os.environ else os.environ["RU_UDID"]
HERE = os.path.dirname(os.path.abspath(__file__))
TYPES = {1: "other", 9: "button", 48: "text", 49: "field", 52: "textview", 43: "image", 40: "switch", 59: "slider",
         75: "cell", 46: "scroll", 39: "link", 2: "group", 3: "window", 42: "icon", 44: "searchfield", 4: "sheet",
         7: "alert", 22: "navbar", 30: "tabbar", 60: "pageindicator", 41: "toggle", 54: "datepicker", 57: "picker",
         58: "pickerwheel", 76: "layoutarea", 12: "checkbox"}
os.makedirs(OUT, exist_ok=True)


def send(cmd):
    seqf = os.path.join(DRV, "seq")
    seq = int(open(seqf).read()) + 1 if os.path.exists(seqf) else 1
    open(seqf, "w").write(str(seq))
    cmd = dict(cmd, seq=seq)
    tmp = os.path.join(DRV, "cmd.json.tmp")
    json.dump(cmd, open(tmp, "w"), ensure_ascii=False)
    os.rename(tmp, os.path.join(DRV, "cmd.json"))
    deadline = time.time() + float(cmd.get("timeout", 30)) + 180
    while time.time() < deadline:
        try:
            r = open(os.path.join(DRV, "result.txt")).read()
            if r.startswith(f"{seq} "):
                return r[len(str(seq)) + 1:]
        except FileNotFoundError:
            pass
        time.sleep(0.1)
    return "TIMEOUT"


def shot(name):
    path = os.path.join(OUT, name + ".jpg")
    subprocess.run(["xcrun", "simctl", "io", UDID, "screenshot", "--type=jpeg", path], capture_output=True)
    subprocess.run(["sips", "-Z", "1300", path], capture_output=True)


def tree(bundle=None):
    cmd = {"op": "snap", "name": "snap"}
    if bundle:
        cmd["bundle"] = bundle
    r = send(cmd)
    if not r.startswith("/"):
        print("  tree:", r)
        return
    for line in open(r, encoding="utf-8").read().splitlines():
        parts = line.split("\t")
        kind = TYPES.get(int(parts[0]), parts[0])
        if kind in ("window", "other", "group", "scroll") and not parts[1] and not parts[3] and len(parts[2]) == 0:
            continue
        print("  " + " | ".join([kind, parts[1], parts[2][:300], parts[3][:200], parts[4], parts[5]]))


steps = json.load(sys.stdin)
for i, step in enumerate(steps):
    extras = {k: step.pop(k) for k in ("shot", "tree", "settle") if k in step}
    op = step.get("op")
    started = time.time()
    if op == "shot":
        shot(step["name"]); result = "shot"
    elif op == "paper":
        cam = os.path.join(RU, "camera.jpg")
        r = subprocess.run([os.path.join(RU, "venv/bin/python"), os.path.join(HERE, "makepaper.py"), cam, *step["lines"]],
                           capture_output=True, text=True)
        result = "paper ok" if r.returncode == 0 else "paper failed " + r.stderr[-300:]
    elif op == "sh":
        r = subprocess.run(step["cmd"], shell=True, capture_output=True, text=True)
        result = (r.stdout + r.stderr)[-1500:]
    elif op is None:
        result = "-"
    else:
        result = send(step)
    brief = {k: v for k, v in step.items() if k not in ("strokes",)}
    print(f"[{i}] {json.dumps(brief, ensure_ascii=False)[:160]} -> {result} ({time.time() - started:.1f}s)", flush=True)
    if "settle" in extras:
        time.sleep(float(extras["settle"]))
    if "shot" in extras:
        shot(extras["shot"])
    if extras.get("tree"):
        tree(extras["tree"] if isinstance(extras["tree"], str) else None)
