#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./gate_b_reference.sh path/to/whoop-capture.csv path/to/reference-rr.csv [run-label]

Runs the strict Gate B HRV validator and writes a JSON evidence report under:
  docs/evidence/gate-b/<run-label>/report.json

The WHOOP and reference CSVs are copied into that same directory before
validation so the report is reproducible from committed/local evidence files.
The wrapper also writes MANIFEST.txt with the run label, timestamp, git commit,
validator command, and validator exit code.

The run exits non-zero unless the WHOOP capture is validation-ready, app replay
matches the exported app HRV snapshot, the reference capture is validation-ready,
and all clinical HRV metric deltas are within their declared tolerances.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 64
fi

whoop_csv=$1
reference_csv=$2
label=${3:-$(date -u +"%Y%m%dT%H%M%SZ")}
evidence_dir="docs/evidence/gate-b/${label}"
whoop_copy="${evidence_dir}/whoop-capture.csv"
reference_copy="${evidence_dir}/reference-rr.csv"
report="${evidence_dir}/report.json"
checksums="${evidence_dir}/SHA256SUMS"
manifest="${evidence_dir}/MANIFEST.txt"
validator_log="${evidence_dir}/validator.log"

last_csv_value() {
  local csv_path=$1
  local row_kind=$2
  python3 - "$csv_path" "$row_kind" <<'PY'
import csv
import sys

path, row_kind = sys.argv[1], sys.argv[2]
last = ""
with open(path, newline="") as f:
    for row in csv.DictReader(f):
        if row.get("kind") == row_kind:
            last = row.get("value", "")
print(last)
PY
}

report_value() {
  local report_path=$1
  local dotted_path=$2
  python3 - "$report_path" "$dotted_path" <<'PY'
import json
import sys

report_path, dotted_path = sys.argv[1], sys.argv[2]
try:
    with open(report_path) as f:
        value = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)

for part in dotted_path.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    elif isinstance(value, list) and part.isdigit():
        index = int(part)
        value = value[index] if index < len(value) else None
    else:
        value = None
        break

if value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
else:
    print(value)
PY
}

if [[ -d "$evidence_dir" ]] && [[ -n "$(find "$evidence_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  printf 'Refusing to overwrite existing Gate B evidence directory: %s\n' "$evidence_dir" >&2
  printf 'Choose a new run-label, or move the existing evidence aside first.\n' >&2
  exit 73
fi

git_status=$(git status --short)
if [[ -z "$git_status" ]]; then
  git_status="clean"
fi

mkdir -p "$evidence_dir"
cp "$whoop_csv" "$whoop_copy"
cp "$reference_csv" "$reference_copy"

validator_exit=0
./validate_hrv.py "$whoop_copy" \
  --reference "$reference_copy" \
  --report "$report" > "$validator_log" 2>&1 || validator_exit=$?
cat "$validator_log"

created_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
git_commit=$(git rev-parse HEAD)
whoop_capture_meta=$(last_csv_value "$whoop_copy" "capture_meta")
whoop_capture_summary=$(last_csv_value "$whoop_copy" "capture_summary")
capture_started_at_utc=$(report_value "$report" "capture_context.started_at_utc")
capture_app_bundle=$(report_value "$report" "capture_context.app_bundle")
capture_ios=$(report_value "$report" "capture_context.ios")
capture_model=$(report_value "$report" "capture_context.model")
capture_strap=$(report_value "$report" "capture_context.strap")
capture_label=$(report_value "$report" "capture_context.label")
capture_contract=$(report_value "$report" "capture_contract")
reference_rr_column=$(report_value "$report" "reference_metadata.rr_column")
reference_time_column=$(report_value "$report" "reference_metadata.time_column")
reference_timeline_source=$(report_value "$report" "reference_metadata.timeline_source")
reference_time_unit=$(report_value "$report" "reference_metadata.time_unit")
report_status=$(report_value "$report" "status")
report_failure=$(report_value "$report" "failure")
report_failures=$(report_value "$report" "failures")
report_alignment_failures=$(report_value "$report" "alignment_failures")
app_ready_resp_status=$(report_value "$report" "app_ready_resp_status")
capture_summary_resp_status=$(report_value "$report" "capture_summary_resp_status")
app_ready_resp_bpm=$(report_value "$report" "app_ready_resp_bpm")
capture_summary_resp_bpm=$(report_value "$report" "capture_summary_resp_bpm")
resp_status_match=$(report_value "$report" "resp_status_match")
resp_bpm_delta=$(report_value "$report" "resp_bpm_delta")
app_ready_snapshot_row_elapsed_s=$(report_value "$report" "app_ready_snapshot_row_elapsed_s")
capture_summary_row_elapsed_s=$(report_value "$report" "capture_summary_row_elapsed_s")
capture_summary_after_ready_snapshot=$(report_value "$report" "capture_summary_after_ready_snapshot")
whoop_last_rr_row_elapsed_s=$(report_value "$report" "whoop_last_rr_row_elapsed_s")
capture_summary_after_last_rr=$(report_value "$report" "capture_summary_after_last_rr")
whoop_last_hrv_row_elapsed_s=$(report_value "$report" "whoop_last_hrv_row_elapsed_s")
capture_summary_after_last_hrv=$(report_value "$report" "capture_summary_after_last_hrv")
capture_summary_elapsed_s=$(report_value "$report" "capture_summary.elapsed")
capture_summary_window_s=$(report_value "$report" "capture_summary.window")
capture_summary_max_rr_gap_s=$(report_value "$report" "capture_summary.max_rr_gap_s")
threshold_max_delta_ms=$(report_value "$report" "thresholds.max_delta_ms")
threshold_max_sdnn_delta_ms=$(report_value "$report" "thresholds.max_sdnn_delta_ms")
threshold_max_pnn50_delta_pct=$(report_value "$report" "thresholds.max_pnn50_delta_pct")
threshold_max_lnrmssd_delta=$(report_value "$report" "thresholds.max_lnrmssd_delta")
threshold_max_app_replay_delta_ms=$(report_value "$report" "thresholds.max_app_replay_delta_ms")
threshold_min_duration_s=$(report_value "$report" "thresholds.min_duration_s")
threshold_min_kept=$(report_value "$report" "thresholds.min_kept")
threshold_min_confidence=$(report_value "$report" "thresholds.min_confidence")
threshold_max_rr_gap_s=$(report_value "$report" "thresholds.max_rr_gap_s")
threshold_max_window_alignment_s=$(report_value "$report" "thresholds.max_window_alignment_s")
threshold_min_resp_bpm=$(report_value "$report" "thresholds.min_resp_bpm")
threshold_max_resp_bpm=$(report_value "$report" "thresholds.max_resp_bpm")
threshold_max_resp_match_delta_bpm=$(report_value "$report" "thresholds.max_resp_match_delta_bpm")
strap_rmssd_ms=$(report_value "$report" "atria.rmssd")
reference_rmssd_ms=$(report_value "$report" "reference.rmssd")
whoop_confidence_percent=$(report_value "$report" "atria.confidence_percent")
reference_confidence_percent=$(report_value "$report" "reference.confidence_percent")
whoop_total_raw=$(report_value "$report" "whoop_total.raw")
reference_total_raw=$(report_value "$report" "reference_total.raw")
whoop_total_raw_duration_s=$(report_value "$report" "whoop_total.raw_duration_s")
reference_total_raw_duration_s=$(report_value "$report" "reference_total.raw_duration_s")
whoop_raw_duration_s=$(report_value "$report" "atria.raw_duration_s")
reference_raw_duration_s=$(report_value "$report" "reference.raw_duration_s")
whoop_corrected_duration_s=$(report_value "$report" "atria.corrected_duration_s")
reference_corrected_duration_s=$(report_value "$report" "reference.corrected_duration_s")
whoop_max_raw_gap_s=$(report_value "$report" "atria.max_raw_gap_s")
reference_max_raw_gap_s=$(report_value "$report" "reference.max_raw_gap_s")
clean_rr_marker_elapsed_s=$(report_value "$report" "quality_markers.0.elapsed_s")
clean_rr_marker_value=$(report_value "$report" "quality_markers.0.value")
window_start_delta_s=$(report_value "$report" "window_alignment.window_start_delta_s")
window_end_delta_s=$(report_value "$report" "window_alignment.window_end_delta_s")
delta_rmssd_ms=$(report_value "$report" "delta_rmssd_ms")
delta_sdnn_ms=$(report_value "$report" "reference_metric_deltas.sdnn")
delta_pnn50_pct=$(report_value "$report" "reference_metric_deltas.pnn50")
delta_lnrmssd=$(report_value "$report" "reference_metric_deltas.lnrmssd")
app_replay_rmssd_delta=$(report_value "$report" "app_replay_metric_deltas.rmssd")
app_replay_sdnn_delta=$(report_value "$report" "app_replay_metric_deltas.sdnn")
app_replay_pnn50_delta=$(report_value "$report" "app_replay_metric_deltas.pnn50")
app_replay_lnrmssd_delta=$(report_value "$report" "app_replay_metric_deltas.lnrmssd")
app_replay_max_rr_gap_delta_s=$(report_value "$report" "app_replay_count_deltas.max_rr_gap_s")
capture_summary_rmssd_delta=$(report_value "$report" "capture_summary_metric_deltas.rmssd")
capture_summary_sdnn_delta=$(report_value "$report" "capture_summary_metric_deltas.sdnn")
capture_summary_pnn50_delta=$(report_value "$report" "capture_summary_metric_deltas.pnn50")
capture_summary_lnrmssd_delta=$(report_value "$report" "capture_summary_metric_deltas.lnrmssd")
capture_summary_max_rr_gap_delta_s=$(report_value "$report" "capture_summary_max_rr_gap_delta_s")
rmssd_within_tolerance=$(report_value "$report" "rmssd_within_tolerance")
sdnn_within_tolerance=$(report_value "$report" "reference_metric_within_tolerance.sdnn")
pnn50_within_tolerance=$(report_value "$report" "reference_metric_within_tolerance.pnn50")
lnrmssd_within_tolerance=$(report_value "$report" "reference_metric_within_tolerance.lnrmssd")
clean_rr_marker_before_first_rr=$(python3 - "$clean_rr_marker_elapsed_s" "$(report_value "$report" "atria.window_start_s")" <<'PY'
import sys

marker, first_rr = sys.argv[1], sys.argv[2]
try:
    print(str(float(marker) <= float(first_rr)))
except ValueError:
    print("")
PY
)
capture_summary_elapsed_ok=$(python3 - "$capture_summary_elapsed_s" "$capture_summary_window_s" "$threshold_min_duration_s" <<'PY'
import sys

elapsed, window, minimum = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    elapsed = float(elapsed)
    window = float(window)
    minimum = float(minimum)
except ValueError:
    print("")
else:
    print(str(elapsed + 1 >= window and elapsed + 1 >= minimum))
PY
)
validator_exit_reason=$(python3 - "$validator_exit" <<'PY'
import sys

reasons = {
    0: "pass",
    1: "missing_rr_rows",
    2: "whoop_not_validation_ready",
    3: "reference_metric_or_alignment_failure",
    4: "reference_not_validation_ready",
    5: "app_ready_snapshot_failure",
    6: "capture_summary_failure",
    7: "capture_contract_failure",
    8: "nonmonotonic_timestamps",
    9: "malformed_csv_rows",
}
try:
    code = int(sys.argv[1])
except ValueError:
    code = None
print(reasons.get(code, "unknown"))
PY
)
validator_sha256=$(shasum -a 256 validate_hrv.py | awk '{print $1}')

{
  printf 'gate_b_evidence_manifest_version=1\n'
  printf 'created_at_utc=%s\n' "$created_at_utc"
  printf 'run_label=%s\n' "$label"
  printf 'git_commit=%s\n' "$git_commit"
  printf 'git_status=%s\n' "$git_status"
  printf 'whoop_source=%s\n' "$whoop_csv"
  printf 'reference_source=%s\n' "$reference_csv"
  printf 'whoop_copy=%s\n' "$whoop_copy"
  printf 'reference_copy=%s\n' "$reference_copy"
  printf 'report=%s\n' "$report"
  printf 'validator_log=%s\n' "$validator_log"
  printf 'validator_exit_reason=%s\n' "$validator_exit_reason"
  printf 'whoop_capture_meta=%s\n' "$whoop_capture_meta"
  printf 'whoop_capture_summary=%s\n' "$whoop_capture_summary"
  printf 'capture_started_at_utc=%s\n' "$capture_started_at_utc"
  printf 'capture_app_bundle=%s\n' "$capture_app_bundle"
  printf 'capture_ios=%s\n' "$capture_ios"
  printf 'capture_model=%s\n' "$capture_model"
  printf 'capture_strap=%s\n' "$capture_strap"
  printf 'capture_label=%s\n' "$capture_label"
  printf 'capture_contract=%s\n' "$capture_contract"
  printf 'reference_rr_column=%s\n' "$reference_rr_column"
  printf 'reference_time_column=%s\n' "$reference_time_column"
  printf 'reference_timeline_source=%s\n' "$reference_timeline_source"
  printf 'reference_time_unit=%s\n' "$reference_time_unit"
  printf 'report_status=%s\n' "$report_status"
  printf 'report_failure=%s\n' "$report_failure"
  printf 'report_failures=%s\n' "$report_failures"
  printf 'report_alignment_failures=%s\n' "$report_alignment_failures"
  printf 'app_ready_resp_status=%s\n' "$app_ready_resp_status"
  printf 'capture_summary_resp_status=%s\n' "$capture_summary_resp_status"
  printf 'app_ready_resp_bpm=%s\n' "$app_ready_resp_bpm"
  printf 'capture_summary_resp_bpm=%s\n' "$capture_summary_resp_bpm"
  printf 'resp_status_match=%s\n' "$resp_status_match"
  printf 'resp_bpm_delta=%s\n' "$resp_bpm_delta"
  printf 'app_ready_snapshot_row_elapsed_s=%s\n' "$app_ready_snapshot_row_elapsed_s"
  printf 'capture_summary_row_elapsed_s=%s\n' "$capture_summary_row_elapsed_s"
  printf 'capture_summary_after_ready_snapshot=%s\n' "$capture_summary_after_ready_snapshot"
  printf 'whoop_last_rr_row_elapsed_s=%s\n' "$whoop_last_rr_row_elapsed_s"
  printf 'capture_summary_after_last_rr=%s\n' "$capture_summary_after_last_rr"
  printf 'whoop_last_hrv_row_elapsed_s=%s\n' "$whoop_last_hrv_row_elapsed_s"
  printf 'capture_summary_after_last_hrv=%s\n' "$capture_summary_after_last_hrv"
  printf 'capture_summary_elapsed_s=%s\n' "$capture_summary_elapsed_s"
  printf 'capture_summary_window_s=%s\n' "$capture_summary_window_s"
  printf 'capture_summary_max_rr_gap_s=%s\n' "$capture_summary_max_rr_gap_s"
  printf 'capture_summary_elapsed_ok=%s\n' "$capture_summary_elapsed_ok"
  printf 'threshold_max_delta_ms=%s\n' "$threshold_max_delta_ms"
  printf 'threshold_max_sdnn_delta_ms=%s\n' "$threshold_max_sdnn_delta_ms"
  printf 'threshold_max_pnn50_delta_pct=%s\n' "$threshold_max_pnn50_delta_pct"
  printf 'threshold_max_lnrmssd_delta=%s\n' "$threshold_max_lnrmssd_delta"
  printf 'threshold_max_app_replay_delta_ms=%s\n' "$threshold_max_app_replay_delta_ms"
  printf 'threshold_min_duration_s=%s\n' "$threshold_min_duration_s"
  printf 'threshold_min_kept=%s\n' "$threshold_min_kept"
  printf 'threshold_min_confidence=%s\n' "$threshold_min_confidence"
  printf 'threshold_max_rr_gap_s=%s\n' "$threshold_max_rr_gap_s"
  printf 'threshold_max_window_alignment_s=%s\n' "$threshold_max_window_alignment_s"
  printf 'threshold_min_resp_bpm=%s\n' "$threshold_min_resp_bpm"
  printf 'threshold_max_resp_bpm=%s\n' "$threshold_max_resp_bpm"
  printf 'threshold_max_resp_match_delta_bpm=%s\n' "$threshold_max_resp_match_delta_bpm"
  printf 'strap_rmssd_ms=%s\n' "$strap_rmssd_ms"
  printf 'reference_rmssd_ms=%s\n' "$reference_rmssd_ms"
  printf 'whoop_confidence_percent=%s\n' "$whoop_confidence_percent"
  printf 'reference_confidence_percent=%s\n' "$reference_confidence_percent"
  printf 'whoop_total_raw=%s\n' "$whoop_total_raw"
  printf 'reference_total_raw=%s\n' "$reference_total_raw"
  printf 'whoop_total_raw_duration_s=%s\n' "$whoop_total_raw_duration_s"
  printf 'reference_total_raw_duration_s=%s\n' "$reference_total_raw_duration_s"
  printf 'whoop_raw_duration_s=%s\n' "$whoop_raw_duration_s"
  printf 'reference_raw_duration_s=%s\n' "$reference_raw_duration_s"
  printf 'whoop_corrected_duration_s=%s\n' "$whoop_corrected_duration_s"
  printf 'reference_corrected_duration_s=%s\n' "$reference_corrected_duration_s"
  printf 'whoop_max_raw_gap_s=%s\n' "$whoop_max_raw_gap_s"
  printf 'reference_max_raw_gap_s=%s\n' "$reference_max_raw_gap_s"
  printf 'clean_rr_marker_value=%s\n' "$clean_rr_marker_value"
  printf 'clean_rr_marker_elapsed_s=%s\n' "$clean_rr_marker_elapsed_s"
  printf 'clean_rr_marker_before_first_rr=%s\n' "$clean_rr_marker_before_first_rr"
  printf 'window_start_delta_s=%s\n' "$window_start_delta_s"
  printf 'window_end_delta_s=%s\n' "$window_end_delta_s"
  printf 'delta_rmssd_ms=%s\n' "$delta_rmssd_ms"
  printf 'delta_sdnn_ms=%s\n' "$delta_sdnn_ms"
  printf 'delta_pnn50_pct=%s\n' "$delta_pnn50_pct"
  printf 'delta_lnrmssd=%s\n' "$delta_lnrmssd"
  printf 'app_replay_rmssd_delta=%s\n' "$app_replay_rmssd_delta"
  printf 'app_replay_sdnn_delta=%s\n' "$app_replay_sdnn_delta"
  printf 'app_replay_pnn50_delta=%s\n' "$app_replay_pnn50_delta"
  printf 'app_replay_lnrmssd_delta=%s\n' "$app_replay_lnrmssd_delta"
  printf 'app_replay_max_rr_gap_delta_s=%s\n' "$app_replay_max_rr_gap_delta_s"
  printf 'capture_summary_rmssd_delta=%s\n' "$capture_summary_rmssd_delta"
  printf 'capture_summary_sdnn_delta=%s\n' "$capture_summary_sdnn_delta"
  printf 'capture_summary_pnn50_delta=%s\n' "$capture_summary_pnn50_delta"
  printf 'capture_summary_lnrmssd_delta=%s\n' "$capture_summary_lnrmssd_delta"
  printf 'capture_summary_max_rr_gap_delta_s=%s\n' "$capture_summary_max_rr_gap_delta_s"
  printf 'rmssd_within_tolerance=%s\n' "$rmssd_within_tolerance"
  printf 'sdnn_within_tolerance=%s\n' "$sdnn_within_tolerance"
  printf 'pnn50_within_tolerance=%s\n' "$pnn50_within_tolerance"
  printf 'lnrmssd_within_tolerance=%s\n' "$lnrmssd_within_tolerance"
  printf 'validator_command=./validate_hrv.py %s --reference %s --report %s\n' \
    "$whoop_copy" "$reference_copy" "$report"
  printf 'validator_sha256=%s\n' "$validator_sha256"
  printf 'validator_exit_code=%d\n' "$validator_exit"
  printf 'host=%s\n' "$(hostname)"
  printf 'uname=%s\n' "$(uname -a)"
} > "$manifest"

(
  cd "$evidence_dir"
  shasum -a 256 whoop-capture.csv reference-rr.csv report.json validator.log MANIFEST.txt > SHA256SUMS
)

printf '\nGate B status: %s (exit %d)\n' "$report_status" "$validator_exit"
if [[ -n "$report_failure" ]]; then
  printf 'Failure: %s\n' "$report_failure"
fi
printf 'RMSSD: WHOOP=%s ms reference=%s ms delta=%s ms within_5ms=%s\n' \
  "$strap_rmssd_ms" "$reference_rmssd_ms" "$delta_rmssd_ms" "$rmssd_within_tolerance"
printf 'Reference deltas: SDNN=%s ms/%s ok=%s; pNN50=%s pct/%s ok=%s; lnRMSSD=%s/%s ok=%s\n' \
  "$delta_sdnn_ms" "$threshold_max_sdnn_delta_ms" "$sdnn_within_tolerance" \
  "$delta_pnn50_pct" "$threshold_max_pnn50_delta_pct" "$pnn50_within_tolerance" \
  "$delta_lnrmssd" "$threshold_max_lnrmssd_delta" "$lnrmssd_within_tolerance"
printf 'App replay deltas: RMSSD=%s SDNN=%s pNN50=%s lnRMSSD=%s max_gap=%ss max=%s\n' \
  "$app_replay_rmssd_delta" "$app_replay_sdnn_delta" "$app_replay_pnn50_delta" \
  "$app_replay_lnrmssd_delta" "$app_replay_max_rr_gap_delta_s" \
  "$threshold_max_app_replay_delta_ms"
printf 'Summary replay deltas: RMSSD=%s SDNN=%s pNN50=%s lnRMSSD=%s max_gap=%ss max=%s\n' \
  "$capture_summary_rmssd_delta" "$capture_summary_sdnn_delta" \
  "$capture_summary_pnn50_delta" "$capture_summary_lnrmssd_delta" \
  "$capture_summary_max_rr_gap_delta_s" "$threshold_max_app_replay_delta_ms"
printf 'Confidence: WHOOP=%s%% reference=%s%% min=%s%%\n' \
  "$whoop_confidence_percent" "$reference_confidence_percent" "$threshold_min_confidence"
printf 'Respiratory status: app=%s bpm=%s; summary=%s bpm=%s\n' \
  "$app_ready_resp_status" "$app_ready_resp_bpm" \
  "$capture_summary_resp_status" "$capture_summary_resp_bpm"
printf 'Reference import: rr_column=%s time_column=%s timeline=%s unit=%s\n' \
  "$reference_rr_column" "$reference_time_column" \
  "$reference_timeline_source" "$reference_time_unit"
printf 'Totals: WHOOP raw=%s duration=%ss; reference raw=%s duration=%ss\n' \
  "$whoop_total_raw" "$whoop_total_raw_duration_s" \
  "$reference_total_raw" "$reference_total_raw_duration_s"
printf 'Window: WHOOP raw=%ss corrected=%ss gap=%ss; reference raw=%ss corrected=%ss gap=%ss; max_gap=%ss\n' \
  "$whoop_raw_duration_s" "$whoop_corrected_duration_s" "$whoop_max_raw_gap_s" \
  "$reference_raw_duration_s" "$reference_corrected_duration_s" "$reference_max_raw_gap_s" \
  "$threshold_max_rr_gap_s"
printf 'Clean RR marker: value=%s elapsed=%ss before_first_rr=%s\n' \
  "$clean_rr_marker_value" "$clean_rr_marker_elapsed_s" "$clean_rr_marker_before_first_rr"
printf 'Stopped summary: elapsed=%ss window=%ss max_gap=%ss elapsed_ok=%s\n' \
  "$capture_summary_elapsed_s" "$capture_summary_window_s" \
  "$capture_summary_max_rr_gap_s" "$capture_summary_elapsed_ok"
printf 'Alignment: start_delta=%ss end_delta=%ss max=%ss\n' \
  "$window_start_delta_s" "$window_end_delta_s" "$threshold_max_window_alignment_s"
printf '\nGate B report: %s\n' "$report"
printf 'WHOOP CSV: %s\n' "$whoop_copy"
printf 'Reference CSV: %s\n' "$reference_copy"
printf 'Validator log: %s\n' "$validator_log"
printf 'Manifest: %s\n' "$manifest"
printf 'SHA256: %s\n' "$checksums"

exit "$validator_exit"
