"""Sample-exact metronome for step-counter ground truth (no Bluetooth).

metronome_walk.py spawned one `afplay` per click, so clicks drifted whenever the
Mac was busy (owner, 2026-09-24: "randomly fast and slow"). This renders the whole
walk into ONE audio file (lead-in silence, N clicks at an exact interval, an end
chime) and plays it once, so spacing is exact to the sample. Start/stop wall times
come from the file timeline and are appended to the label file.
Usage: metronome_track.py SPM CLICKS [--label NAME] [--labels PATH] [--cue TEXT] [--lead S]
"""
from __future__ import annotations

import json
import math
import struct
import subprocess
import sys
import tempfile
import time
import wave

SPM = float(sys.argv[1])
CLICKS = int(sys.argv[2])
A = sys.argv[3:]
opt = lambda k, d: A[A.index(k) + 1] if k in A else d
LABEL = opt("--label", f"walk_{int(SPM)}spm")
LABELS = opt("--labels", "/tmp/atria-ble/walk-labels.jsonl")
CUE = opt("--cue", "")
LEAD = float(opt("--lead", "5"))
RATE = 44_100
interval = 60.0 / SPM


def tone(freq, dur, amp=0.6):
    n = int(RATE * dur)
    return [amp * math.sin(2 * math.pi * freq * i / RATE) * (1 - i / n) for i in range(n)]


total = LEAD + CLICKS * interval + 1.0
samples = [0.0] * int(RATE * total)
click = tone(1_800, 0.035)
for i in range(CLICKS):
    at = int(RATE * (LEAD + i * interval))
    for j, v in enumerate(click):
        samples[at + j] += v
end_at = int(RATE * (LEAD + CLICKS * interval))
for j, v in enumerate(tone(660, 0.6, 0.5)):
    samples[end_at + j] += v

path = tempfile.mktemp(suffix=".wav")
with wave.open(path, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32_000)) for s in samples))

subprocess.run(["say", f"{CUE} Stand still. {CLICKS} steps at {int(SPM)} per minute. One step per click."])
t0 = time.time()
subprocess.run(["afplay", path])
start = t0 + LEAD
entry = {"cue": CUE, "label": LABEL, "spm": SPM, "truth_steps": CLICKS,
         "start": start, "stop": start + CLICKS * interval, "metronome": "sample_exact"}
with open(LABELS, "a") as f:
    f.write(json.dumps(entry) + "\n")
print(json.dumps(entry))
subprocess.run(["say", "Stop and stand still."])
