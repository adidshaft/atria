#!/usr/bin/env bash
set -euo pipefail

label="gate-e-hrr50-workout"
analysis_label=""
seconds=1200
verify_after=""
evidence_dir=""
mode="hr-only"
rest_hr=""
max_hr=""
timezone="IST"
live_debug_extra=()

usage() {
  cat <<'EOF'
Usage:
  ./gate_e_workout_audit.sh [--label LABEL] [--seconds N] [--verify-after N]
                             [--evidence-dir DIR] [--mode hr-only|full]
                             [--analysis-label LABEL]
                             [--rest HR] [--max-hr HR] [--timezone UTC|IST]
                             [--live-debug-arg ARG ...]

Runs the deterministic Gate E workout audit on the physical iPhone:
  - build/install/launch through live_device_debug.sh
  - low-radio HR-only capture by default
  - checkpoint + strict auto-save + delayed workout validation
  - pull Documents/sessions.json, the active Long Wear journal, and verified backup
  - summarize the WHOOPDBG log, pulled current store, and active journal

By default the log analyzer considers all labels. This is intentional because a
persisted Long wear run can keep logging live rows as "Long wear" even when the
debug verifier is checking a separate label.

This does not relax the production workout detector. Missing stream time and
below-threshold HR remain blockers.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      label=${2:?--label requires a value}
      shift 2
      ;;
    --seconds)
      seconds=${2:?--seconds requires a value}
      shift 2
      ;;
    --verify-after)
      verify_after=${2:?--verify-after requires a value}
      shift 2
      ;;
    --evidence-dir)
      evidence_dir=${2:?--evidence-dir requires a value}
      shift 2
      ;;
    --mode)
      mode=${2:?--mode requires hr-only or full}
      shift 2
      ;;
    --analysis-label)
      analysis_label=${2:?--analysis-label requires a value}
      shift 2
      ;;
    --rest)
      rest_hr=${2:?--rest requires a value}
      shift 2
      ;;
    --max-hr)
      max_hr=${2:?--max-hr requires a value}
      shift 2
      ;;
    --timezone)
      timezone=${2:?--timezone requires UTC or IST}
      shift 2
      ;;
    --live-debug-arg)
      live_debug_extra+=("${2:?--live-debug-arg requires a value}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --seconds value: %s\n' "$seconds" >&2
  exit 2
fi
if [[ -n "$verify_after" && ! "$verify_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --verify-after value: %s\n' "$verify_after" >&2
  exit 2
fi
case "$mode" in
  hr-only|full) ;;
  *)
    printf 'Invalid --mode value: %s\n' "$mode" >&2
    exit 2
    ;;
esac
case "$timezone" in
  UTC|IST) ;;
  *)
    printf 'Invalid --timezone value: %s\n' "$timezone" >&2
    exit 2
    ;;
esac

if [[ -z "$verify_after" ]]; then
  verify_after=900
  if awk "BEGIN { exit !($seconds < 900) }"; then
    verify_after=$(awk "BEGIN { v=$seconds-10; if (v < 5) v=5; printf \"%.0f\", v }")
  fi
fi

if [[ -z "$evidence_dir" ]]; then
  stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  evidence_dir="docs/evidence/gate-e/${stamp}-workout-audit"
fi

mkdir -p "$evidence_dir/current-container" "$evidence_dir/pulled-backups"

log_path="$evidence_dir/live-device.log"
command_log="$evidence_dir/command-output.log"
log_analysis="$evidence_dir/gate-e-log-analysis.txt"
store_analysis="$evidence_dir/current-store-analysis.tsv"
summary="$evidence_dir/summary.txt"

preset=(--gate-e-workout-capture)
if [[ "$mode" == "hr-only" ]]; then
  preset=(--gate-e-hr-only-workout-capture)
fi

cmd=(
  ./live_device_debug.sh
  "${preset[@]}"
  --label "$label"
  --seconds "$seconds"
  --verify-workout-label "$label"
  --verify-workout-after "$verify_after"
  --pull-sessions "$evidence_dir/current-container"
  --pull-backups "$evidence_dir/pulled-backups"
  --log "$log_path"
)
if [[ ${#live_debug_extra[@]} -gt 0 ]]; then
  cmd+=("${live_debug_extra[@]}")
fi

{
  printf 'gate_e_workout_audit label=%s seconds=%s verify_after=%s mode=%s evidence_dir=%s\n' \
    "$label" "$seconds" "$verify_after" "$mode" "$evidence_dir"
  printf 'command='
  printf '%q ' "${cmd[@]}"
  printf '\n'
  "${cmd[@]}"
} | tee "$command_log"

{
  printf 'active_journal_pull_start=1\n'
  active_destination="$evidence_dir/current-container/atria-active-session.json"
  active_status=missing_or_failed
  copy_device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
  if [[ -z "$copy_device_id" ]]; then
    printf 'active_journal_pull_status=skipped_missing_ATRIA_DEVICE_ID\n'
  fi
  for active_source in Documents/atria-active-session.json Documents/whoop-active-session.json; do
    [[ -n "$copy_device_id" ]] || break
    if xcrun devicectl device copy from \
      --device "$copy_device_id" \
      --domain-type appDataContainer \
      --domain-identifier com.adidshaft.atria \
      --source "$active_source" \
      --destination "$active_destination"; then
      active_status=ok
      printf 'active_journal_pull_status=ok\n'
      printf 'active_journal_pull_source=%s\n' "$active_source"
      printf 'active_journal_pull_file=%s\n' "$active_destination"
      break
    fi
  done
  if [[ "$active_status" != "ok" ]]; then
    printf 'active_journal_pull_status=missing_or_failed\n'
  fi
} | tee -a "$command_log"

python3 tools/analyze_gate_e_workout_log.py "$command_log" --label "$analysis_label" > "$log_analysis"

if [[ -z "$rest_hr" ]]; then
  rest_hr=$(awk -F= '$1 == "rest_hr" { print $2; exit }' "$log_analysis")
fi
if [[ -z "$max_hr" ]]; then
  max_hr=$(awk -F= '$1 == "max_hr" { print $2; exit }' "$log_analysis")
fi

sessions_json="$evidence_dir/current-container/sessions.json"
if [[ -f "$sessions_json" && "$rest_hr" =~ ^[0-9]+$ && "$max_hr" =~ ^[0-9]+$ ]]; then
  store_cmd=(python3 tools/analyze_workout_store.py "$sessions_json"
    --rest "$rest_hr" --max-hr "$max_hr" --timezone "$timezone" --limit 30)
  if [[ -f "$evidence_dir/current-container/atria-active-session.json" ]]; then
    store_cmd+=(--active-journal "$evidence_dir/current-container/atria-active-session.json")
  fi
  "${store_cmd[@]}" > "$store_analysis"
else
  {
    printf 'current_store_analysis_skipped=1\n'
    printf 'sessions_json=%s\n' "$sessions_json"
    printf 'rest_hr=%s\n' "${rest_hr:-missing}"
    printf 'max_hr=%s\n' "${max_hr:-missing}"
  } > "$store_analysis"
fi

{
  printf 'label=%s\n' "$label"
  printf 'mode=%s\n' "$mode"
  printf 'analysis_label=%s\n' "${analysis_label:-any}"
  printf 'seconds=%s\n' "$seconds"
  printf 'verify_after=%s\n' "$verify_after"
  printf 'evidence_dir=%s\n' "$evidence_dir"
  printf 'log=%s\n' "$log_path"
  printf 'analyzed_log=%s\n' "$command_log"
  printf 'sessions_json=%s\n' "$sessions_json"
  printf '\n[log_analysis]\n'
  sed -n '1,120p' "$log_analysis"
  printf '\n[current_store_head]\n'
  sed -n '1,20p' "$store_analysis"
} > "$summary"

printf 'WHOOP_GATE_E_AUDIT_DIR=%s\n' "$evidence_dir"
printf 'WHOOP_GATE_E_AUDIT_SUMMARY=%s\n' "$summary"
