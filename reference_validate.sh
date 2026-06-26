#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./reference_validate.sh [run-label] [--rr external-rr.csv] [--hr external-hr.csv] [--clear] [--require-rr-pass] [--require-hr-pass]

Pushes optional independent RR/IBI and HR CSV references into Atria's app
container, runs the on-device validators, logs fast gate status, and pulls the
current sessions.json into docs/evidence/reference-validate/<run-label>/.

Without --rr or --hr it does not push anything; it verifies the current
fail-closed missing-reference state unless reference files are already present
in the app container. Use --clear only when intentionally deleting staged
reference inputs before validation.

Use --require-rr-pass and/or --require-hr-pass for final gate checks where the
command should exit nonzero unless the on-device validator reports the matching
gate pass bit.
EOF
}

label=""
rr_reference=""
hr_reference=""
clear_inputs=0
require_rr_pass=0
require_hr_pass=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rr)
      rr_reference=${2:?--rr requires a CSV path}
      shift 2
      ;;
    --hr)
      hr_reference=${2:?--hr requires a CSV path}
      shift 2
      ;;
    --clear)
      clear_inputs=1
      shift
      ;;
    --require-rr-pass)
      require_rr_pass=1
      shift
      ;;
    --require-hr-pass)
      require_hr_pass=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
    *)
      if [[ -n "$label" ]]; then
        printf 'Unexpected extra argument: %s\n' "$1" >&2
        usage >&2
        exit 64
      fi
      label=$1
      shift
      ;;
  esac
done

label=${label:-$(date -u +%Y%m%dT%H%M%SZ-reference-validate)}
device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
seconds=${ATRIA_REFERENCE_VALIDATE_SECONDS:-${REFERENCE_VALIDATE_SECONDS:-120}}
evidence_dir="docs/evidence/reference-validate/${label}"

if [[ -z "$device_id" ]]; then
  printf 'Set ATRIA_DEVICE_ID to your physical iPhone CoreDevice identifier.\n' >&2
  exit 64
fi

mkdir -p "$evidence_dir"

preflight_reference() {
  local kind=$1
  local source=$2
  local output="$evidence_dir/${kind}-reference-preflight.txt"
  python3 tools/preflight_reference_csv.py "$kind" "$source" > "$output"
  local parsed
  local reason
  local ready
  parsed=$(awk -F= '$1 == "parsed" {print $2}' "$output" | tail -1)
  reason=$(awk -F= '$1 == "reason" {print $2}' "$output" | tail -1)
  ready=$(awk -F= '$1 == "reference_ready" {print $2}' "$output" | tail -1)
  printf 'ATRIA_REFERENCE_PREFLIGHT_%s=ok parsed=%s ready=%s reason=%s report=%s\n' \
    "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" \
    "${parsed:-0}" \
    "${ready:-0}" \
    "${reason:-missing}" \
    "$output" | tee -a "$evidence_dir/reference-preflight-summary.txt"
}

cmd=(
  ./live_device_debug.sh
  --device "$device_id"
  --seconds "$seconds"
  --log-gate-status
  --healthkit-reference-audit
  --validate-rr-reference
  --validate-hr-reference
  --pull-sessions "$evidence_dir"
  --standard-hr-only
  --long-wear-mode
  --quiet-ble-logs
  --log "$evidence_dir/reference-validate.log"
)

if [[ -n "$rr_reference" ]]; then
  preflight_reference rr "$rr_reference"
  cmd+=(--push-rr-reference "$rr_reference")
fi
if [[ -n "$hr_reference" ]]; then
  preflight_reference hr "$hr_reference"
  cmd+=(--push-hr-reference "$hr_reference")
fi
if [[ "$clear_inputs" -eq 1 ]]; then
  cmd+=(--clear-reference-inputs)
fi

"${cmd[@]}" > "$evidence_dir/reference-validate-run.log" 2>&1

python3 -m json.tool "$evidence_dir/sessions.json" >/dev/null

{
  echo "ATRIA_REFERENCE_VALIDATE_DIR=$evidence_dir"
  if [[ -f "$evidence_dir/reference-preflight-summary.txt" ]]; then
    cat "$evidence_dir/reference-preflight-summary.txt"
  fi
  grep -En "ATRIADBG (reference_inputs_clear|rr_reference_validation|rr_reference_validation_reference|hr_reference_validation|hr_reference_validation_reference|healthkit_reference_audit|gate_status gate=B|gate_status gate=C|gate_status gate=D|gate_status gate=E|gate_status gate=G|execution_priority)|ATRIADBG_(RR|HR)_REFERENCE_PUSH_FILE|ATRIADBG_SESSIONS_PULL_FILE|HARNESS_(CAPTURE_TIMEOUT|ERROR)" \
    "$evidence_dir/reference-validate.log" \
    "$evidence_dir/reference-validate-run.log" || true
} | tee "$evidence_dir/reference-validate-summary.txt"

python3 - "$evidence_dir/reference-validate.log" "$evidence_dir/reference-validate-run.log" <<'PY' | tee -a "$evidence_dir/reference-validate-summary.txt"
import sys

rr = {}
hr = {}

def parse_tokens(line: str) -> dict[str, str]:
    tokens: dict[str, str] = {}
    for part in line.split():
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        tokens[key] = value
    return tokens

for path in sys.argv[1:]:
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if "ATRIADBG rr_reference_validation status=" in line and "gate_b_pass=" in line:
                rr = parse_tokens(line)
            if "ATRIADBG hr_reference_validation status=" in line and "gate_d_pass=" in line:
                hr = parse_tokens(line)

def emit(prefix: str, tokens: dict[str, str], pass_key: str) -> None:
    status = tokens.get("status", "missing_log")
    reason = tokens.get("reason", "missing_log")
    passed = tokens.get(pass_key, "0")
    validated = tokens.get("reference_validated", "0")
    source = tokens.get("source", "none")
    print(f"ATRIA_REFERENCE_{prefix}_STATUS={status}")
    print(f"ATRIA_REFERENCE_{prefix}_REASON={reason}")
    print(f"ATRIA_REFERENCE_{prefix}_{pass_key.upper()}={passed}")
    print(f"ATRIA_REFERENCE_{prefix}_VALIDATED={validated}")
    print(f"ATRIA_REFERENCE_{prefix}_SOURCE={source}")

emit("RR", rr, "gate_b_pass")
emit("HR", hr, "gate_d_pass")
PY

if [[ "$require_rr_pass" -eq 1 ]] && ! grep -Fxq "ATRIA_REFERENCE_RR_GATE_B_PASS=1" "$evidence_dir/reference-validate-summary.txt"; then
  printf 'ATRIA_REFERENCE_VALIDATE_ERROR=require_rr_pass_not_met\n' | tee -a "$evidence_dir/reference-validate-summary.txt"
  exit 2
fi

if [[ "$require_hr_pass" -eq 1 ]] && ! grep -Fxq "ATRIA_REFERENCE_HR_GATE_D_PASS=1" "$evidence_dir/reference-validate-summary.txt"; then
  printf 'ATRIA_REFERENCE_VALIDATE_ERROR=require_hr_pass_not_met\n' | tee -a "$evidence_dir/reference-validate-summary.txt"
  exit 2
fi

echo "$evidence_dir"
