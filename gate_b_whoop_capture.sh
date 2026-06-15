#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./gate_b_whoop_capture.sh [run-label] [--seconds N] [--device DEVICE_ID] [--no-build]

Runs the known-good physical-iPhone Gate B WHOOP-side capture recipe:
  - build/install/launch on adidshaft's cabled iPhone
  - auto-start Capture
  - send the validated START, then the debug duplicate 0301 probe after 8s
  - stop at the first validation-ready 5-minute HRV window
  - stop and save near timeout even if HRV is still learning
  - pull the saved WHOOP CSV into docs/evidence/gate-b/<run-label>/

This produces the WHOOP-side evidence only. Gate B still exits only after a
matched external RR/IBI reference is prepared and compared with gate_b_reference.sh.
EOF
}

label="$(date -u +"%Y%m%dT%H%M%SZ")-gate-b-reference"
seconds=720
device_arg=()
build_arg=()

if [[ $# -gt 0 && "${1:-}" != --* ]]; then
  label=$1
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds)
      seconds=${2:?--seconds requires a value}
      shift 2
      ;;
    --device)
      device_arg=(--device "${2:?--device requires a value}")
      shift 2
      ;;
    --no-build)
      build_arg=(--no-build)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

case "$seconds" in
  ''|*[!0-9]*)
    printf 'Invalid --seconds value: %s\n' "$seconds" >&2
    exit 64
    ;;
esac

evidence_dir="docs/evidence/gate-b/${label}"
log_path="${evidence_dir}/live-device.log"
manifest="${evidence_dir}/WHOOP_CAPTURE_MANIFEST.txt"

if [[ -d "$evidence_dir" ]] && [[ -n "$(find "$evidence_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  printf 'Refusing to overwrite existing Gate B WHOOP capture directory: %s\n' "$evidence_dir" >&2
  printf 'Choose a new run-label, or move the existing evidence aside first.\n' >&2
  exit 73
fi

mkdir -p "$evidence_dir"

command=(
  ./live_device_debug.sh
  --seconds "$seconds"
  --until-ready
  --auto-capture
  --stop-when-ready
  --auto-stop-after "$((seconds > 5 ? seconds - 5 : seconds))"
  --label "$label"
  --log "$log_path"
  --realtime-start-retries 0
  --probe-command 0301
  --probe-command-delay 8
  --pull-capture "$evidence_dir"
)
if [[ ${#device_arg[@]} -gt 0 ]]; then
  command=("${command[@]:0:1}" "${device_arg[@]}" "${command[@]:1}")
fi
if [[ ${#build_arg[@]} -gt 0 ]]; then
  command=("${command[@]:0:1}" "${build_arg[@]}" "${command[@]:1}")
fi

printf 'Running Gate B WHOOP-side capture into %s\n' "$evidence_dir"
printf 'Command:'
printf ' %q' "${command[@]}"
printf '\n'

capture_exit=0
"${command[@]}" || capture_exit=$?

created_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
git_commit=$(git rev-parse HEAD)
git_status=$(git status --short)
if [[ -z "$git_status" ]]; then
  git_status="clean"
fi
pulled_capture=$(find "$evidence_dir" -maxdepth 1 -type f -name 'whoop-capture-*.csv' | sort | tail -n 1)

{
  printf 'gate_b_whoop_capture_manifest_version=1\n'
  printf 'created_at_utc=%s\n' "$created_at_utc"
  printf 'run_label=%s\n' "$label"
  printf 'git_commit=%s\n' "$git_commit"
  printf 'git_status=%s\n' "$git_status"
  printf 'seconds=%s\n' "$seconds"
  printf 'live_log=%s\n' "$log_path"
  printf 'pulled_capture=%s\n' "$pulled_capture"
  printf 'capture_exit_code=%d\n' "$capture_exit"
  printf 'capture_command='
  printf '%q ' "${command[@]}"
  printf '\n'
  printf 'next_reference_step=./prepare_reference_rr.py reference-export.csv %s/reference-rr.csv --window-s 300 --window-end-s <reference-window-end-seconds>\n' "$evidence_dir"
  printf 'next_validation_step=./gate_b_reference.sh %s %s/reference-rr.csv %s\n' "${pulled_capture:-${evidence_dir}/whoop-capture-...csv}" "$evidence_dir" "$label"
} > "$manifest"

if [[ -n "$pulled_capture" ]]; then
  (
    cd "$evidence_dir"
    shasum -a 256 "$(basename "$pulled_capture")" live-device.log WHOOP_CAPTURE_MANIFEST.txt > WHOOP_CAPTURE_SHA256SUMS
  )
fi

printf 'WHOOP capture manifest: %s\n' "$manifest"
if [[ -n "$pulled_capture" ]]; then
  printf 'Pulled WHOOP CSV: %s\n' "$pulled_capture"
else
  printf 'No pulled WHOOP CSV found. See %s for the device transcript.\n' "$log_path" >&2
fi

exit "$capture_exit"
