# Validation tools

Tools for the [metric validation plan](../../docs/METRIC_VALIDATION_PLAN.md).
Everything they produce is personal health data: keep it in
`~/atria-validation/` (the default) and never commit it. Post only summary
numbers in the metric's issue.

| Tool | Use |
|---|---|
| `pull_day.sh` | `ATRIA_DEVICE_ID=<id> tools/validation/pull_day.sh [label]`. Pulls the latest session backup, step ledger and prefs from the phone, then runs `atria_export.py`. |
| `atria_export.py` | Turns a session backup into `hr.csv`, `rr.csv`, `sleeps.csv` and `rollups.csv`. |
| `ref_hr_strap.py` | Records any standard BLE heart-rate chest strap (Polar, Garmin, Wahoo, Coros, Suunto) to `unix_time,bpm,rr_ms`. It never connects to a WHOOP. Needs `pip install pyobjc-framework-CoreBluetooth`, and must run from a terminal with Bluetooth permission. |
| `../strap-mac/metronome_track.py` | Sample-exact metronome. It writes the labelled windows file the scorer reads. Play it from a normal terminal: sandboxed shells are silent. |
| `score.py` | `score.py hr ATRIA_HR REF_HR WINDOWS`, `score.py rr ATRIA_RR REF_RR WINDOWS` and `score.py sleep ATRIA_SLEEPS DIARY` compare against the reference and print pass or fail against the plan's bars. |
| `test_validation_tools.py` | Offline checks on synthetic data. |

A heart-rate session end to end:

```sh
python3 tools/validation/ref_hr_strap.py ~/atria-validation/hr1/ref.csv --name "Polar" --seconds 1800 &
python3 tools/strap-mac/metronome_track.py 100 300 --label walk --labels ~/atria-validation/hr1/windows.jsonl
ATRIA_DEVICE_ID=<id> tools/validation/pull_day.sh hr1
python3 tools/validation/score.py hr ~/atria-validation/hr1/hr.csv ~/atria-validation/hr1/ref.csv ~/atria-validation/hr1/windows.jsonl
```
