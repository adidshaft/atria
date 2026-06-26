#!/usr/bin/env bash
set -euo pipefail

label=${1:-$(date -u +%Y%m%dT%H%M%SZ-reference-handoff)}
device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
seconds=${ATRIA_REFERENCE_HANDOFF_SECONDS:-${REFERENCE_HANDOFF_SECONDS:-240}}
evidence_dir="docs/evidence/reference-handoff/${label}"

if [[ -z "$device_id" ]]; then
  printf 'Set ATRIA_DEVICE_ID to your physical iPhone CoreDevice identifier.\n' >&2
  exit 64
fi

mkdir -p "$evidence_dir"

launch_keepalive_after_failure() {
  {
    echo "ATRIA_REFERENCE_HANDOFF_KEEPALIVE_AFTER_FAILURE=attempt"
    xcrun devicectl device process launch \
      --device "$device_id" \
      --terminate-existing \
      com.adidshaft.atria \
      --atria-capture-label Long_wear \
      --atria-standard-hr-only \
      --atria-long-wear-mode \
      --atria-checkpoint-session-every 60 \
      --atria-auto-save-session-every 900 \
      --atria-log-live-workout-every 60 \
      --atria-auto-save-workout-when-ready 60
    echo "ATRIA_REFERENCE_HANDOFF_KEEPALIVE_AFTER_FAILURE=launched"
  } >> "$evidence_dir/reference-handoff-run.log" 2>&1 || {
    status=$?
    echo "ATRIA_REFERENCE_HANDOFF_KEEPALIVE_AFTER_FAILURE=failed status=$status" \
      >> "$evidence_dir/reference-handoff-run.log"
  }
}

set +e
./live_device_debug.sh \
  --device "$device_id" \
  --seconds "$seconds" \
  --log-gate-status \
  --healthkit-reference-audit \
  --export-rr-reference-package \
  --export-hr-reference-package \
  --pull-reference-package "$evidence_dir" \
  --pull-sessions "$evidence_dir" \
  --standard-hr-only \
  --long-wear-mode \
  --leave-running \
  --quiet-ble-logs \
  --log "$evidence_dir/reference-handoff.log" \
  > "$evidence_dir/reference-handoff-run.log" 2>&1
handoff_status=$?
set -e

if [[ "$handoff_status" -ne 0 ]]; then
  launch_keepalive_after_failure
  {
    echo "ATRIA_REFERENCE_HANDOFF_DIR=$evidence_dir"
    echo "ATRIA_REFERENCE_HANDOFF_STATUS=failed"
    echo "ATRIA_REFERENCE_HANDOFF_EXIT=$handoff_status"
    grep -En "ATRIADBG (rr_reference_package|hr_reference_package|healthkit_reference_audit|gate_status gate=B|gate_status gate=D|gate_status gate=E|execution_priority)|ATRIADBG_(RR|HR)_REFERENCE_PULL_FILE|ATRIADBG_SESSIONS_PULL_FILE|HARNESS_(ERROR|CAPTURE_TIMEOUT)|ATRIA_REFERENCE_HANDOFF_KEEPALIVE_AFTER_FAILURE" \
      "$evidence_dir/reference-handoff.log" \
      "$evidence_dir/reference-handoff-run.log" || true
  } | tee "$evidence_dir/reference-handoff-summary.txt"
  echo "$evidence_dir"
  exit "$handoff_status"
fi

python3 -m json.tool "$evidence_dir/sessions.json" >/dev/null

{
  echo "ATRIA_REFERENCE_HANDOFF_DIR=$evidence_dir"
  grep -En "ATRIADBG (rr_reference_package|hr_reference_package|healthkit_reference_audit|gate_status gate=B|gate_status gate=D|gate_status gate=E|execution_priority)|ATRIADBG_(RR|HR)_REFERENCE_PULL_FILE|ATRIADBG_SESSIONS_PULL_FILE|HARNESS_ERROR" \
    "$evidence_dir/reference-handoff.log" \
    "$evidence_dir/reference-handoff-run.log" || true
} | tee "$evidence_dir/reference-handoff-summary.txt"

python3 - "$evidence_dir" <<'PY' | tee -a "$evidence_dir/reference-handoff-summary.txt"
import json
import sys
from pathlib import Path

evidence_dir = Path(sys.argv[1])

rr_manifest = next(iter(sorted(evidence_dir.glob("atria-rr-reference-*-manifest.json"))), None)
hr_manifest = next(iter(sorted(evidence_dir.glob("atria-hr-reference-*-manifest.json"))), None)

def emit(prefix: str, key: str, value) -> None:
    if isinstance(value, bool):
        value = "1" if value else "0"
    elif value is None:
        value = "none"
    print(f"ATRIA_HANDOFF_{prefix}_{key}={value}")

def load(path: Path | None) -> dict:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}

rr = load(rr_manifest)
hr = load(hr_manifest)

emit("RR", "MANIFEST", rr_manifest.name if rr_manifest else "missing")
emit("RR", "CSV", str(rr.get("csv", "missing")))
emit("RR", "SESSION_LABEL", rr.get("sessionLabel", "missing"))
emit("RR", "READY_FOR_EXTERNAL_REFERENCE", rr.get("readyForExternalReference", False))
emit("RR", "REFERENCE_VALIDATED", rr.get("referenceValidated", False))
emit("RR", "GATE_B_PASSED", rr.get("gateBPassed", False))
emit("RR", "RAW", rr.get("raw"))
emit("RR", "KEPT", rr.get("kept"))
emit("RR", "CONFIDENCE_PERCENT", rr.get("confidencePercent"))
emit("RR", "MAX_GAP_S", rr.get("maxRRGapSeconds"))
emit("RR", "RMSSD_MS", rr.get("rmssdMs"))
emit("RR", "SDNN_MS", rr.get("sdnnMs"))
emit("RR", "PNN50_PERCENT", rr.get("pnn50Percent"))
emit("RR", "LNRMSSD", rr.get("lnRmssd"))

emit("HR", "MANIFEST", hr_manifest.name if hr_manifest else "missing")
emit("HR", "CSV", str(hr.get("csv", "missing")))
emit("HR", "SESSION_LABEL", hr.get("sessionLabel", "missing"))
emit("HR", "READY_FOR_EXTERNAL_REFERENCE", hr.get("readyForExternalReference", False))
emit("HR", "REFERENCE_VALIDATED", hr.get("referenceValidated", False))
emit("HR", "GATE_D_PASSED", hr.get("gateDPassed", False))
emit("HR", "SAMPLES", hr.get("hrSamples"))
emit("HR", "DURATION_S", hr.get("durationSeconds"))
emit("HR", "OBSERVED_S", hr.get("observedSeconds"))
emit("HR", "COVERAGE_PERCENT", hr.get("streamCoveragePercent"))
emit("HR", "AVG", hr.get("avgHR"))
emit("HR", "PEAK", hr.get("peakHR"))
emit("HR", "RESTING", hr.get("restingHR"))
PY

python3 - "$evidence_dir" <<'PY'
import json
import sys
from pathlib import Path

evidence_dir = Path(sys.argv[1])
rr_manifest = next(iter(sorted(evidence_dir.glob("atria-rr-reference-*-manifest.json"))), None)
hr_manifest = next(iter(sorted(evidence_dir.glob("atria-hr-reference-*-manifest.json"))), None)

def load(path: Path | None) -> dict:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}

def value(data: dict, key: str, default: str = "missing") -> str:
    raw = data.get(key, default)
    if raw is None:
        return default
    return str(raw)

rr = load(rr_manifest)
hr = load(hr_manifest)
rr_csv = Path(value(rr, "csv", "missing")).name if value(rr, "csv", "").startswith("Documents/") else value(rr, "csv")
hr_csv = Path(value(hr, "csv", "missing")).name if value(hr, "csv", "").startswith("Documents/") else value(hr, "csv")
rr_csv_path = evidence_dir / rr_csv if rr_csv != "missing" else Path("missing")
hr_csv_path = evidence_dir / hr_csv if hr_csv != "missing" else Path("missing")

next_steps = f"""# Atria Reference Handoff - Next Steps

This folder contains the latest Atria-authored reference packages pulled from
the physical iPhone. They are **not** independent references by themselves.
Gate B and Gate D stay blocked until these files are compared against separate
RR/IBI or HR recordings.

## Gate B RR/HRV

- Atria RR CSV: `{rr_csv_path}`
- Source session: `{value(rr, "sessionLabel")}`
- Atria RMSSD: `{value(rr, "rmssdMs")} ms`
- Kept/raw/confidence: `{value(rr, "kept")}/{value(rr, "raw")}/{value(rr, "confidencePercent")}%`
- Max RR gap: `{value(rr, "maxRRGapSeconds")} s`

Put an independent RR/IBI CSV that covers the same 5-minute window somewhere on
this Mac, then run:

```sh
python3 tools/preflight_reference_csv.py rr /path/to/independent-rr.csv
./reference_validate.sh gate-b-external-rr-$(date -u +%Y%m%dT%H%M%SZ) --rr /path/to/independent-rr.csv --require-rr-pass
```

The external CSV can use headers like `rr_ms`, `ibi_ms`, `interval_ms`, or
`value`, plus optional time headers such as `elapsed_ms`, `time_s`, or `t`.
Never use the Atria CSV itself as the reference except for parser smoke tests.

## Gate D HR

- Atria HR CSV: `{hr_csv_path}`
- Source session: `{value(hr, "sessionLabel")}`
- Samples/duration/coverage: `{value(hr, "hrSamples")}/{value(hr, "durationSeconds")}s/{value(hr, "streamCoveragePercent")}%`
- Avg/peak/resting HR: `{value(hr, "avgHR")}/{value(hr, "peakHR")}/{value(hr, "restingHR")}`

Put an independent HR CSV from a chest strap or another non-Atria source
somewhere on this Mac, then run:

```sh
python3 tools/preflight_reference_csv.py hr /path/to/independent-hr.csv
./reference_validate.sh gate-d-external-hr-$(date -u +%Y%m%dT%H%M%SZ) --hr /path/to/independent-hr.csv --require-hr-pass
```

The HR CSV can use headers like `hr`, `heart_rate`, `bpm`, or `value`, plus
optional time headers such as `elapsed_ms`, `time_s`, or `t`.

## Current Truth

- No HRV, Recovery, workout, or HealthKit HRV/workout metric should be promoted
  from this handoff alone.
- Passing validation must happen on the physical iPhone through
  `reference_validate.sh`, because the app's persisted gate bits are the
  authority.
"""

(evidence_dir / "REFERENCE_NEXT_STEPS.md").write_text(next_steps)
print(f"ATRIA_REFERENCE_NEXT_STEPS={evidence_dir / 'REFERENCE_NEXT_STEPS.md'}")
PY

echo "$evidence_dir"
