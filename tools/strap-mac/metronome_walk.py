"""Metronome-labelled walk trials for step-counter ground truth (no Bluetooth).

The Mac plays a spoken cue, a lead-in pause, then N clicks at the given tempo. The subject takes
exactly one step per click. Truth = N clicks. Start/stop wall times are appended to a label file
so captures (r10_capture.py --raw) can be scored by strap_metrics.py.
Usage: metronome_walk.py SPM CLICKS [--label NAME] [--labels PATH]
"""
from __future__ import annotations

import json
import subprocess
import sys
import time

SPM = float(sys.argv[1])
CLICKS = int(sys.argv[2])
ARGS = sys.argv[3:]
LABEL = ARGS[ARGS.index("--label") + 1] if "--label" in ARGS else f"walk_{int(SPM)}spm"
LABELS = ARGS[ARGS.index("--labels") + 1] if "--labels" in ARGS else "/tmp/atria-ble/walk-labels.jsonl"
CLICK = "/System/Library/Sounds/Tink.aiff"
END = "/System/Library/Sounds/Glass.aiff"

subprocess.run(["say", f"Stand still. Walking at {int(SPM)} steps per minute starts in five seconds."])
time.sleep(5)
interval = 60.0 / SPM
start = time.time()
for i in range(CLICKS):
    target = start + i * interval
    delay = target - time.time()
    if delay > 0:
        time.sleep(delay)
    subprocess.Popen(["afplay", CLICK])
stop = start + (CLICKS - 1) * interval
time.sleep(max(0.0, stop + interval - time.time()))
subprocess.run(["afplay", END])
entry = {"label": LABEL, "spm": SPM, "truth_steps": CLICKS, "start": start, "stop": stop + interval}
with open(LABELS, "a") as f:
    f.write(json.dumps(entry) + "\n")
print(json.dumps(entry))
subprocess.run(["say", "Stop and stand still."])
