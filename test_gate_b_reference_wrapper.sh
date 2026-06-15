#!/usr/bin/env bash
set -euo pipefail

label="test-wrapper-$(date -u +%Y%m%dT%H%M%SZ)-$$"
evidence_dir="docs/evidence/gate-b/${label}"
fail_label="${label}-offset"
fail_evidence_dir="docs/evidence/gate-b/${fail_label}"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir" "$evidence_dir" "$fail_evidence_dir"' EXIT

whoop_csv="$tmpdir/whoop-ready.csv"
reference_csv="$tmpdir/reference.csv"
offset_reference_csv="$tmpdir/reference-offset.csv"
wrapper_log="$tmpdir/wrapper.log"
fail_wrapper_log="$tmpdir/wrapper-fail.log"

python3 - "$whoop_csv" "$reference_csv" "$offset_reference_csv" <<'PY'
import csv
import sys

whoop_path, reference_path, offset_reference_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(whoop_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["elapsed_ms", "kind", "source", "opcode", "len", "label", "value"])
    writer.writerow([
        0,
        "capture_meta",
        "app",
        "",
        "",
        "",
        "started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=wrapper-smoke",
    ])
    writer.writerow([
        0,
        "capture_meta",
        "app",
        "",
        "",
        "",
        "schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw",
    ])
    writer.writerow([0, "hrv_quality", "app", "", "", "", "clean_rr_window_started"])
    for elapsed_ms in range(0, 301_000, 1000):
        writer.writerow([elapsed_ms, "rr", "0x28", "28", "", "", 1000])
    writer.writerow([
        300_000,
        "hrv",
        "analyzer",
        "",
        "",
        "",
        "raw=301 kept=301 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=300 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning",
    ])
    writer.writerow([
        300_000,
        "capture_summary",
        "app",
        "",
        "",
        "",
        "ready=1 elapsed=300 raw=301 kept=301 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=300 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning",
    ])

with open(reference_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["elapsed_ms", "rr_ms"])
    for elapsed_ms in range(0, 301_000, 1000):
        writer.writerow([elapsed_ms, 1000])

with open(offset_reference_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["elapsed_ms", "rr_ms"])
    for elapsed_ms in range(10_000, 311_000, 1000):
        writer.writerow([elapsed_ms, 1000])
PY

./gate_b_reference.sh "$whoop_csv" "$reference_csv" "$label" > "$wrapper_log"

manifest="${evidence_dir}/MANIFEST.txt"
report="${evidence_dir}/report.json"
validator_log="${evidence_dir}/validator.log"
checksums="${evidence_dir}/SHA256SUMS"

for path in "$manifest" "$report" "$validator_log" "$checksums"; do
  if [[ ! -s "$path" ]]; then
    printf 'FAIL: expected non-empty wrapper artifact: %s\n' "$path" >&2
    exit 1
  fi
done

grep -q 'PASS: clinical HRV metrics are within reference tolerances' "$validator_log"
grep -q "Gate B status: pass (exit 0)" "$wrapper_log"
grep -q "Validator log: ${validator_log}" "$wrapper_log"
grep -q 'RMSSD: WHOOP=0.0 ms reference=0.0 ms delta=0.0 ms within_5ms=True' "$wrapper_log"
grep -q 'App replay deltas: RMSSD=0.0 SDNN=0.0 pNN50=0.0 lnRMSSD=0.0 max_gap=0.0s max=0.6' "$wrapper_log"
grep -q 'Summary replay deltas: RMSSD=0.0 SDNN=0.0 pNN50=0.0 lnRMSSD=0.0 max_gap=0.0s max=0.6' "$wrapper_log"
grep -q 'Clean RR marker: value=clean_rr_window_started elapsed=0.0s before_first_rr=True' "$wrapper_log"
grep -q 'Stopped summary: elapsed=300.0s window=300.0s max_gap=1.0s elapsed_ok=True' "$wrapper_log"
grep -q 'Confidence: WHOOP=100.0% reference=100.0% min=75.0%' "$wrapper_log"
grep -q 'Respiratory status: app=learning bpm=; summary=learning bpm=' "$wrapper_log"
grep -q 'Reference import: rr_column=rr_ms time_column=elapsed_ms timeline=timestamp_column unit=milliseconds' "$wrapper_log"
grep -q 'Totals: WHOOP raw=301 duration=300.0s; reference raw=301 duration=300.0s' "$wrapper_log"
grep -q "validator_log=${validator_log}" "$manifest"
grep -q 'report_status=pass' "$manifest"
grep -q 'validator_exit_reason=pass' "$manifest"
grep -q 'app_ready_resp_status=learning' "$manifest"
grep -q 'capture_summary_resp_status=learning' "$manifest"
grep -q 'app_ready_resp_bpm=' "$manifest"
grep -q 'capture_summary_resp_bpm=' "$manifest"
grep -q 'resp_status_match=True' "$manifest"
grep -q 'resp_bpm_delta=' "$manifest"
grep -q 'app_ready_snapshot_row_elapsed_s=300.0' "$manifest"
grep -q 'capture_summary_row_elapsed_s=300.0' "$manifest"
grep -q 'capture_summary_after_ready_snapshot=True' "$manifest"
grep -q 'whoop_last_rr_row_elapsed_s=300.0' "$manifest"
grep -q 'capture_summary_after_last_rr=True' "$manifest"
grep -q 'whoop_last_hrv_row_elapsed_s=300.0' "$manifest"
grep -q 'capture_summary_after_last_hrv=True' "$manifest"
grep -q 'reference_timeline_source=timestamp_column' "$manifest"
grep -q 'capture_summary_elapsed_s=300.0' "$manifest"
grep -q 'capture_summary_window_s=300.0' "$manifest"
grep -q 'capture_summary_max_rr_gap_s=1.0' "$manifest"
grep -q 'capture_summary_elapsed_ok=True' "$manifest"
grep -q 'threshold_max_delta_ms=5.0' "$manifest"
grep -q 'threshold_max_sdnn_delta_ms=5.0' "$manifest"
grep -q 'threshold_max_pnn50_delta_pct=5.0' "$manifest"
grep -q 'threshold_max_lnrmssd_delta=0.2' "$manifest"
grep -q 'threshold_min_duration_s=300.0' "$manifest"
grep -q 'threshold_min_kept=240' "$manifest"
grep -q 'threshold_min_confidence=75.0' "$manifest"
grep -q 'threshold_max_rr_gap_s=3.0' "$manifest"
grep -q 'threshold_max_window_alignment_s=3.0' "$manifest"
grep -q 'threshold_min_resp_bpm=6.0' "$manifest"
grep -q 'threshold_max_resp_bpm=30.0' "$manifest"
grep -q 'threshold_max_resp_match_delta_bpm=0.05' "$manifest"
grep -q 'whoop_total_raw=301' "$manifest"
grep -q 'reference_total_raw=301' "$manifest"
grep -q 'whoop_total_raw_duration_s=300.0' "$manifest"
grep -q 'reference_total_raw_duration_s=300.0' "$manifest"
grep -q 'whoop_raw_duration_s=300.0' "$manifest"
grep -q 'reference_raw_duration_s=300.0' "$manifest"
grep -q 'whoop_max_raw_gap_s=1.0' "$manifest"
grep -q 'reference_max_raw_gap_s=1.0' "$manifest"
grep -q 'clean_rr_marker_value=clean_rr_window_started' "$manifest"
grep -q 'clean_rr_marker_elapsed_s=0.0' "$manifest"
grep -q 'clean_rr_marker_before_first_rr=True' "$manifest"
grep -q 'window_start_delta_s=0.0' "$manifest"
grep -q 'window_end_delta_s=0.0' "$manifest"
grep -q 'delta_rmssd_ms=0.0' "$manifest"
grep -q 'delta_sdnn_ms=0.0' "$manifest"
grep -q 'delta_pnn50_pct=0.0' "$manifest"
grep -q 'delta_lnrmssd=0.0' "$manifest"
grep -q 'app_replay_rmssd_delta=0.0' "$manifest"
grep -q 'app_replay_sdnn_delta=0.0' "$manifest"
grep -q 'app_replay_pnn50_delta=0.0' "$manifest"
grep -q 'app_replay_lnrmssd_delta=0.0' "$manifest"
grep -q 'app_replay_max_rr_gap_delta_s=0.0' "$manifest"
grep -q 'capture_summary_rmssd_delta=0.0' "$manifest"
grep -q 'capture_summary_sdnn_delta=0.0' "$manifest"
grep -q 'capture_summary_pnn50_delta=0.0' "$manifest"
grep -q 'capture_summary_lnrmssd_delta=0.0' "$manifest"
grep -q 'capture_summary_max_rr_gap_delta_s=0.0' "$manifest"
grep -q 'rmssd_within_tolerance=True' "$manifest"
grep -q 'sdnn_within_tolerance=True' "$manifest"
grep -q 'pnn50_within_tolerance=True' "$manifest"
grep -q 'lnrmssd_within_tolerance=True' "$manifest"
grep -q 'validator.log' "$checksums"

python3 - "$report" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert report["status"] == "pass", report
assert report["rmssd_within_tolerance"] is True, report
assert report["quality_markers"] == [
    {"elapsed_s": 0.0, "value": "clean_rr_window_started"}
], report
assert report["reference_metric_within_tolerance"] == {
    "rmssd": True,
    "sdnn": True,
    "pnn50": True,
    "lnrmssd": True,
}, report
assert report["thresholds"]["max_rr_gap_s"] == 3.0, report
assert report["thresholds"]["max_window_alignment_s"] == 3.0, report
assert report["thresholds"]["min_resp_bpm"] == 6.0, report
assert report["thresholds"]["max_resp_bpm"] == 30.0, report
assert report["thresholds"]["max_resp_match_delta_bpm"] == 0.05, report
assert report["resp_status_match"] is True, report
assert report["resp_bpm_delta"] is None, report
assert report["app_ready_snapshot_row_elapsed_s"] == 300.0, report
assert report["capture_summary_row_elapsed_s"] == 300.0, report
assert report["capture_summary_after_ready_snapshot"] is True, report
assert report["whoop_last_rr_row_elapsed_s"] == 300.0, report
assert report["capture_summary_after_last_rr"] is True, report
assert report["whoop_last_hrv_row_elapsed_s"] == 300.0, report
assert report["capture_summary_after_last_hrv"] is True, report
assert report["reference_metadata"]["timeline_source"] == "timestamp_column", report
assert report["whoop"]["raw_duration_s"] == 300.0, report
assert report["reference"]["raw_duration_s"] == 300.0, report
assert report["window_alignment"]["window_start_delta_s"] == 0.0, report
assert report["window_alignment"]["window_end_delta_s"] == 0.0, report
assert report["app_replay_count_deltas"]["max_rr_gap_s"] == 0.0, report
assert report["capture_summary"]["max_rr_gap_s"] == 1.0, report
assert report["capture_summary_max_rr_gap_delta_s"] == 0.0, report
PY

if ./gate_b_reference.sh "$whoop_csv" "$offset_reference_csv" "$fail_label" > "$fail_wrapper_log" 2>&1; then
  printf 'FAIL: wrapper accepted an offset reference evidence run\n' >&2
  exit 1
fi

fail_manifest="${fail_evidence_dir}/MANIFEST.txt"
fail_report="${fail_evidence_dir}/report.json"
fail_validator_log="${fail_evidence_dir}/validator.log"
fail_checksums="${fail_evidence_dir}/SHA256SUMS"

for path in "$fail_manifest" "$fail_report" "$fail_validator_log" "$fail_checksums"; do
  if [[ ! -s "$path" ]]; then
    printf 'FAIL: expected non-empty failed wrapper artifact: %s\n' "$path" >&2
    exit 1
  fi
done

grep -q 'FAIL: reference final window is not time-aligned' "$fail_validator_log"
grep -q "Gate B status: fail (exit 3)" "$fail_wrapper_log"
grep -q 'Failure: reference final window is not time-aligned' "$fail_wrapper_log"
grep -q 'Reference import: rr_column=rr_ms time_column=elapsed_ms timeline=timestamp_column unit=milliseconds' "$fail_wrapper_log"
grep -q 'Alignment: start_delta=10.0s end_delta=10.0s max=3.0s' "$fail_wrapper_log"
grep -q 'report_status=fail' "$fail_manifest"
grep -q 'report_failure=reference final window is not time-aligned' "$fail_manifest"
grep -q 'report_alignment_failures=\["window_start_delta_s","window_end_delta_s"\]' "$fail_manifest"
grep -q 'window_start_delta_s=10.0' "$fail_manifest"
grep -q 'window_end_delta_s=10.0' "$fail_manifest"
grep -q 'validator_exit_code=3' "$fail_manifest"
grep -q 'validator_exit_reason=reference_metric_or_alignment_failure' "$fail_manifest"
grep -q 'validator.log' "$fail_checksums"

python3 - "$fail_report" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert report["status"] == "fail", report
assert report["failure"] == "reference final window is not time-aligned", report
assert report["alignment_failures"] == ["window_start_delta_s", "window_end_delta_s"], report
assert report["window_alignment"]["window_start_delta_s"] == 10.0, report
assert report["window_alignment"]["window_end_delta_s"] == 10.0, report
PY

printf 'PASS: Gate B wrapper retains validator evidence and manifest summary\n'
