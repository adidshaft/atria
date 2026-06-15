#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

whoop_csv="$tmpdir/whoop-learning.csv"
reference_csv="$tmpdir/reference.csv"
derived_reference_csv="$tmpdir/reference-derived.csv"
ready_whoop_csv="$tmpdir/whoop-ready-resp-learning.csv"
bad_reason_whoop_csv="$tmpdir/whoop-bad-reason.csv"
gap_reason_whoop_csv="$tmpdir/whoop-gap-reason-learning.csv"
legacy_ln_whoop_csv="$tmpdir/whoop-ready-legacy-ln.csv"
nonfinite_whoop_csv="$tmpdir/whoop-nonfinite.csv"
nonfinite_reference_csv="$tmpdir/reference-nonfinite.csv"
missing_rr_reference_csv="$tmpdir/reference-missing-rr.csv"
gap_whoop_csv="$tmpdir/whoop-gap.csv"
bad_reference_csv="$tmpdir/reference-bad-metrics.csv"
offset_reference_csv="$tmpdir/reference-offset.csv"
stale_whoop_csv="$tmpdir/whoop-stale-no-clean-marker.csv"
late_marker_whoop_csv="$tmpdir/whoop-late-clean-marker.csv"
bad_marker_whoop_csv="$tmpdir/whoop-bad-clean-marker-time.csv"
short_elapsed_whoop_csv="$tmpdir/whoop-summary-short-elapsed.csv"
missing_elapsed_whoop_csv="$tmpdir/whoop-summary-missing-elapsed.csv"
missing_resp_whoop_csv="$tmpdir/whoop-summary-missing-resp.csv"
numeric_resp_whoop_csv="$tmpdir/whoop-summary-numeric-resp.csv"
min_resp_whoop_csv="$tmpdir/whoop-summary-min-resp.csv"
max_resp_whoop_csv="$tmpdir/whoop-summary-max-resp.csv"
malformed_resp_whoop_csv="$tmpdir/whoop-summary-malformed-resp.csv"
resp_mismatch_whoop_csv="$tmpdir/whoop-summary-resp-mismatch.csv"
resp_bpm_mismatch_whoop_csv="$tmpdir/whoop-summary-resp-bpm-mismatch.csv"
early_summary_whoop_csv="$tmpdir/whoop-summary-before-ready.csv"
summary_before_last_rr_whoop_csv="$tmpdir/whoop-summary-before-last-rr.csv"
summary_before_last_hrv_whoop_csv="$tmpdir/whoop-summary-before-last-hrv.csv"
bad_resp_whoop_csv="$tmpdir/whoop-summary-bad-resp.csv"
whoop_report="$tmpdir/whoop-report.json"
reference_report="$tmpdir/reference-report.json"
ready_report="$tmpdir/ready-report.json"
bad_reason_report="$tmpdir/bad-reason-report.json"
gap_reason_report="$tmpdir/gap-reason-report.json"
derived_reference_report="$tmpdir/derived-reference-report.json"
legacy_ln_report="$tmpdir/legacy-ln-report.json"
nonfinite_report="$tmpdir/nonfinite-report.json"
nonfinite_reference_report="$tmpdir/nonfinite-reference-report.json"
missing_rr_reference_report="$tmpdir/missing-rr-reference-report.json"
gap_report="$tmpdir/gap-report.json"
bad_reference_report="$tmpdir/bad-reference-report.json"
offset_reference_report="$tmpdir/offset-reference-report.json"
stale_report="$tmpdir/stale-report.json"
late_marker_report="$tmpdir/late-marker-report.json"
bad_marker_report="$tmpdir/bad-marker-report.json"
short_elapsed_report="$tmpdir/short-elapsed-report.json"
missing_elapsed_report="$tmpdir/missing-elapsed-report.json"
missing_resp_report="$tmpdir/missing-resp-report.json"
numeric_resp_report="$tmpdir/numeric-resp-report.json"
min_resp_report="$tmpdir/min-resp-report.json"
max_resp_report="$tmpdir/max-resp-report.json"
malformed_resp_report="$tmpdir/malformed-resp-report.json"
resp_mismatch_report="$tmpdir/resp-mismatch-report.json"
resp_bpm_mismatch_report="$tmpdir/resp-bpm-mismatch-report.json"
early_summary_report="$tmpdir/early-summary-report.json"
summary_before_last_rr_report="$tmpdir/summary-before-last-rr-report.json"
summary_before_last_hrv_report="$tmpdir/summary-before-last-hrv-report.json"
bad_resp_report="$tmpdir/bad-resp-report.json"

cat > "$whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=test"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=0 rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
5000,capture_summary,app,,,,"ready=0 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
CSV

cat > "$reference_csv" <<'CSV'
elapsed_ms,rr_ms
0,1000
1000,1000
2000,1000
3000,1000
4000,1000
5000,1000
CSV

cat > "$derived_reference_csv" <<'CSV'
rr_ms
1000
1000
1000
1000
1000
1000
CSV

cat > "$ready_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=test"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 reason=ready rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 reason=ready rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
CSV

cat > "$bad_reason_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=bad_reason"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 reason=maybe rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
CSV

cat > "$gap_reason_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=gap_reason"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
8000,rr,0x28,28,,,1000
8000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=8 max_rr_gap_s=4.0 ready=0 reason=gap rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
8000,capture_summary,app,,,,"ready=0 elapsed=8 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=8 max_rr_gap_s=4.0 reason=gap rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
CSV

cat > "$legacy_ln_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=legacy_ln"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 ln=0.00 resp=learning"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 ln=0.00 resp=learning"
CSV

cat > "$nonfinite_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=test"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,NaN
CSV

cat > "$nonfinite_reference_csv" <<'CSV'
elapsed_ms,rr_ms
0,1000
1000,inf
CSV

cat > "$missing_rr_reference_csv" <<'CSV'
elapsed_ms,bpm
0,60
1000,60
CSV

cat > "$gap_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=gap"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
6000,rr,0x28,28,,,1000
7000,rr,0x28,28,,,1000
8000,rr,0x28,28,,,1000
8000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=8 max_rr_gap_s=4.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
8000,capture_summary,app,,,,"ready=1 elapsed=8 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=8 max_rr_gap_s=4.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
CSV

cat > "$bad_reference_csv" <<'CSV'
elapsed_ms,rr_ms
0,1000
1000,1030
2000,1000
3000,1030
4000,1000
5000,1030
CSV

cat > "$offset_reference_csv" <<'CSV'
elapsed_ms,rr_ms
10000,1000
11000,1000
12000,1000
13000,1000
14000,1000
15000,1000
CSV

cat > "$stale_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=stale"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
CSV

cat > "$late_marker_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=late_marker"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,rr,0x28,28,,,1000
1000,hrv_quality,app,,,,clean_rr_window_started
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
CSV

cat > "$bad_marker_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=bad_marker"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
NaN,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
CSV

cat > "$short_elapsed_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=short_elapsed"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
5000,capture_summary,app,,,,"ready=1 elapsed=3 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
CSV

cat > "$missing_elapsed_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=missing_elapsed"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
5000,capture_summary,app,,,,"ready=1 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
CSV

cat > "$missing_resp_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=missing_resp"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00"
CSV

cat > "$numeric_resp_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=numeric_resp"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=12.5"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=12.5"
CSV

cat > "$min_resp_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=min_resp"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=6.0"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=6.0"
CSV

cat > "$max_resp_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=max_resp"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=30.0"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=30.0"
CSV

cat > "$malformed_resp_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=malformed_resp"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=fast"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=fast"
CSV

cat > "$resp_mismatch_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=resp_mismatch"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=12.5"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
CSV

cat > "$resp_bpm_mismatch_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=resp_bpm_mismatch"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=12.5"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=12.6"
CSV

cat > "$early_summary_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=early_summary"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
4000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
CSV

cat > "$summary_before_last_rr_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=summary_before_last_rr"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
6000,rr,0x28,28,,,1000
CSV

cat > "$summary_before_last_hrv_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=summary_before_last_hrv"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=learning"
6000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=0 rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
CSV

cat > "$bad_resp_whoop_csv" <<'CSV'
elapsed_ms,kind,source,opcode,len,label,value
0,capture_meta,app,,,,"started_at_utc=2026-06-12T00:00:00Z app_bundle=com.aman.whoopapp ios=26.5 model=iPhone strap=WHOOP label=bad_resp"
0,capture_meta,app,,,,"schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"
0,hrv_quality,app,,,,clean_rr_window_started
0,rr,0x28,28,,,1000
1000,rr,0x28,28,,,1000
2000,rr,0x28,28,,,1000
3000,rr,0x28,28,,,1000
4000,rr,0x28,28,,,1000
5000,rr,0x28,28,,,1000
5000,hrv,analyzer,,,,"raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 ready=1 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=45.0"
5000,capture_summary,app,,,,"ready=1 elapsed=5 raw=6 kept=6 rejected_out_of_range=0 rejected_delta_over_20_percent=0 interpolated=0 conf=100 window=5 max_rr_gap_s=1.0 rmssd=0.0 sdnn=0.0 pnn50=0.0 lnrmssd=0.00 resp=45.0"
CSV

./validate_hrv.py "$whoop_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$whoop_report" >/dev/null

./validate_hrv.py "$ready_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$ready_report" >/dev/null

./validate_hrv.py "$ready_whoop_csv" \
  --reference "$derived_reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$derived_reference_report" >/dev/null

./validate_hrv.py "$legacy_ln_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$legacy_ln_report" >/dev/null

./validate_hrv.py "$numeric_resp_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$numeric_resp_report" >/dev/null

./validate_hrv.py "$min_resp_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$min_resp_report" >/dev/null

./validate_hrv.py "$max_resp_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$max_resp_report" >/dev/null

if ./validate_hrv.py "$whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$reference_report" >/dev/null 2>&1; then
  printf 'FAIL: reference mode accepted an unready learning capture\n' >&2
  exit 1
fi

if ./validate_hrv.py "$bad_reason_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$bad_reason_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted an invalid HRV readiness reason\n' >&2
  exit 1
fi

./validate_hrv.py "$gap_reason_whoop_csv" \
  --min-duration-s 8 \
  --min-kept 5 \
  --max-rr-gap-s 5 \
  --report "$gap_reason_report" >/dev/null

if ./validate_hrv.py "$nonfinite_whoop_csv" \
  --min-duration-s 1 \
  --min-kept 1 \
  --report "$nonfinite_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a non-finite RR value\n' >&2
  exit 1
fi

if ./validate_hrv.py "$ready_whoop_csv" \
  --reference "$nonfinite_reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$nonfinite_reference_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a non-finite reference RR value\n' >&2
  exit 1
fi

if ./validate_hrv.py "$ready_whoop_csv" \
  --reference "$missing_rr_reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$missing_rr_reference_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a reference CSV without an RR column\n' >&2
  exit 1
fi

if ./validate_hrv.py "$gap_whoop_csv" \
  --min-duration-s 8 \
  --min-kept 5 \
  --max-rr-gap-s 3 \
  --report "$gap_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a capture with a long RR timestamp gap\n' >&2
  exit 1
fi

if ./validate_hrv.py "$ready_whoop_csv" \
  --reference "$bad_reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$bad_reference_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a clinically divergent reference capture\n' >&2
  exit 1
fi

if ./validate_hrv.py "$ready_whoop_csv" \
  --reference "$offset_reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$offset_reference_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a time-offset reference capture\n' >&2
  exit 1
fi

if ./validate_hrv.py "$stale_whoop_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$stale_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a schema-2 capture without the clean-window marker\n' >&2
  exit 1
fi

if ./validate_hrv.py "$late_marker_whoop_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$late_marker_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a clean-window marker after RR rows\n' >&2
  exit 1
fi

if ./validate_hrv.py "$bad_marker_whoop_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$bad_marker_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a clean-window marker with malformed elapsed_ms\n' >&2
  exit 1
fi

if ./validate_hrv.py "$short_elapsed_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$short_elapsed_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a ready summary with elapsed shorter than the HRV window\n' >&2
  exit 1
fi

if ./validate_hrv.py "$missing_elapsed_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$missing_elapsed_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a ready summary without elapsed evidence\n' >&2
  exit 1
fi

if ./validate_hrv.py "$missing_resp_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$missing_resp_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a ready capture without respiratory status\n' >&2
  exit 1
fi

if ./validate_hrv.py "$bad_resp_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$bad_resp_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted an out-of-range respiratory rate\n' >&2
  exit 1
fi

if ./validate_hrv.py "$malformed_resp_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$malformed_resp_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a malformed respiratory status\n' >&2
  exit 1
fi

if ./validate_hrv.py "$resp_mismatch_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$resp_mismatch_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted mismatched respiratory evidence\n' >&2
  exit 1
fi

if ./validate_hrv.py "$resp_bpm_mismatch_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$resp_bpm_mismatch_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted mismatched numeric respiratory values\n' >&2
  exit 1
fi

if ./validate_hrv.py "$early_summary_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$early_summary_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a capture_summary before the ready HRV row\n' >&2
  exit 1
fi

if ./validate_hrv.py "$summary_before_last_rr_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$summary_before_last_rr_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a capture_summary before the final RR row\n' >&2
  exit 1
fi

if ./validate_hrv.py "$summary_before_last_hrv_whoop_csv" \
  --reference "$reference_csv" \
  --min-duration-s 5 \
  --min-kept 5 \
  --report "$summary_before_last_hrv_report" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted a capture_summary before the final HRV row\n' >&2
  exit 1
fi

python3 - "$whoop_report" "$reference_report" "$ready_report" "$bad_reason_report" "$gap_reason_report" "$derived_reference_report" "$legacy_ln_report" "$numeric_resp_report" "$min_resp_report" "$max_resp_report" "$nonfinite_report" "$nonfinite_reference_report" "$missing_rr_reference_report" "$gap_report" "$bad_reference_report" "$offset_reference_report" "$stale_report" "$late_marker_report" "$bad_marker_report" "$short_elapsed_report" "$missing_elapsed_report" "$missing_resp_report" "$bad_resp_report" "$malformed_resp_report" "$resp_mismatch_report" "$resp_bpm_mismatch_report" "$early_summary_report" "$summary_before_last_rr_report" "$summary_before_last_hrv_report" <<'PY'
import json
import sys

whoop_report = json.loads(open(sys.argv[1], encoding="utf-8").read())
reference_report = json.loads(open(sys.argv[2], encoding="utf-8").read())
ready_report = json.loads(open(sys.argv[3], encoding="utf-8").read())
bad_reason_report = json.loads(open(sys.argv[4], encoding="utf-8").read())
gap_reason_report = json.loads(open(sys.argv[5], encoding="utf-8").read())
derived_reference_report = json.loads(open(sys.argv[6], encoding="utf-8").read())
legacy_ln_report = json.loads(open(sys.argv[7], encoding="utf-8").read())
numeric_resp_report = json.loads(open(sys.argv[8], encoding="utf-8").read())
min_resp_report = json.loads(open(sys.argv[9], encoding="utf-8").read())
max_resp_report = json.loads(open(sys.argv[10], encoding="utf-8").read())
nonfinite_report = json.loads(open(sys.argv[11], encoding="utf-8").read())
nonfinite_reference_report = json.loads(open(sys.argv[12], encoding="utf-8").read())
missing_rr_reference_report = json.loads(open(sys.argv[13], encoding="utf-8").read())
gap_report = json.loads(open(sys.argv[14], encoding="utf-8").read())
bad_reference_report = json.loads(open(sys.argv[15], encoding="utf-8").read())
offset_reference_report = json.loads(open(sys.argv[16], encoding="utf-8").read())
stale_report = json.loads(open(sys.argv[17], encoding="utf-8").read())
late_marker_report = json.loads(open(sys.argv[18], encoding="utf-8").read())
bad_marker_report = json.loads(open(sys.argv[19], encoding="utf-8").read())
short_elapsed_report = json.loads(open(sys.argv[20], encoding="utf-8").read())
missing_elapsed_report = json.loads(open(sys.argv[21], encoding="utf-8").read())
missing_resp_report = json.loads(open(sys.argv[22], encoding="utf-8").read())
bad_resp_report = json.loads(open(sys.argv[23], encoding="utf-8").read())
malformed_resp_report = json.loads(open(sys.argv[24], encoding="utf-8").read())
resp_mismatch_report = json.loads(open(sys.argv[25], encoding="utf-8").read())
resp_bpm_mismatch_report = json.loads(open(sys.argv[26], encoding="utf-8").read())
early_summary_report = json.loads(open(sys.argv[27], encoding="utf-8").read())
summary_before_last_rr_report = json.loads(open(sys.argv[28], encoding="utf-8").read())
summary_before_last_hrv_report = json.loads(open(sys.argv[29], encoding="utf-8").read())

assert whoop_report["status"] == "replay_ok", whoop_report
assert whoop_report["accuracy_comparison"] == "skipped", whoop_report
assert whoop_report["capture_context"]["started_at_utc"] == "2026-06-12T00:00:00Z", whoop_report
assert whoop_report["capture_context"]["app_bundle"] == "com.aman.whoopapp", whoop_report
assert whoop_report["capture_context"]["label"] == "test", whoop_report
assert whoop_report["capture_contract"]["schema"] == "2", whoop_report
assert whoop_report["capture_contract"]["correction"] == "drop_300_2000_delta20_interpolate", whoop_report
assert whoop_report["capture_contract"]["confidence"] == "kept_over_raw", whoop_report
assert whoop_report["quality_markers"] == [
    {"elapsed_s": 0.0, "value": "clean_rr_window_started"}
], whoop_report
assert len(whoop_report["capture_metadata_rows"]) == 2, whoop_report
assert reference_report["status"] == "fail", reference_report
assert reference_report["failure"] == "no ready app hrv snapshot found", reference_report
assert ready_report["status"] == "pass", ready_report
assert ready_report["hrv_readiness_reasons"] == ["ready"], ready_report
assert ready_report["last_hrv_readiness_reason"] == "ready", ready_report
assert ready_report["app_ready_snapshot_reason"] == "ready", ready_report
assert ready_report["capture_summary_reason"] == "ready", ready_report
assert ready_report["delta_rmssd_ms"] == 0, ready_report
assert ready_report["rmssd_within_tolerance"] is True, ready_report
assert ready_report["reference_metric_tolerances"]["rmssd"] == 5.0, ready_report
assert ready_report["reference_metric_tolerances"]["sdnn"] == 5.0, ready_report
assert ready_report["reference_metric_tolerances"]["pnn50"] == 5.0, ready_report
assert ready_report["reference_metric_tolerances"]["lnrmssd"] == 0.2, ready_report
assert ready_report["reference_metric_within_tolerance"] == {
    "rmssd": True,
    "sdnn": True,
    "pnn50": True,
    "lnrmssd": True,
}, ready_report
assert legacy_ln_report["status"] == "pass", legacy_ln_report
assert legacy_ln_report["app_ready_snapshot"]["ln"] == 0.0, legacy_ln_report
assert legacy_ln_report["app_ready_snapshot"]["lnrmssd"] == 0.0, legacy_ln_report
assert legacy_ln_report["capture_summary"]["ln"] == 0.0, legacy_ln_report
assert legacy_ln_report["capture_summary"]["lnrmssd"] == 0.0, legacy_ln_report
assert legacy_ln_report["capture_summary_metric_deltas"]["lnrmssd"] == 0.0, legacy_ln_report
assert ready_report["window_alignment"]["window_start_delta_s"] == 0, ready_report
assert ready_report["window_alignment"]["window_end_delta_s"] == 0, ready_report
assert ready_report["app_ready_resp_status"] == "learning", ready_report
assert ready_report["capture_summary_resp_status"] == "learning", ready_report
assert ready_report["app_ready_resp_bpm"] is None, ready_report
assert ready_report["capture_summary_resp_bpm"] is None, ready_report
assert ready_report["thresholds"]["min_resp_bpm"] == 6.0, ready_report
assert ready_report["thresholds"]["max_resp_bpm"] == 30.0, ready_report
assert ready_report["thresholds"]["max_resp_match_delta_bpm"] == 0.05, ready_report
assert ready_report["resp_status_match"] is True, ready_report
assert ready_report["resp_bpm_delta"] is None, ready_report
assert ready_report["app_ready_snapshot_row_elapsed_s"] == 5.0, ready_report
assert ready_report["capture_summary_row_elapsed_s"] == 5.0, ready_report
assert ready_report["capture_summary_after_ready_snapshot"] is True, ready_report
assert ready_report["whoop_last_rr_row_elapsed_s"] == 5.0, ready_report
assert ready_report["capture_summary_after_last_rr"] is True, ready_report
assert ready_report["whoop_last_hrv_row_elapsed_s"] == 5.0, ready_report
assert ready_report["capture_summary_after_last_hrv"] is True, ready_report
assert bad_reason_report["status"] == "fail", bad_reason_report
assert bad_reason_report["failure"] == "app hrv snapshot has invalid readiness reason", bad_reason_report
assert bad_reason_report["invalid_readiness_reasons"] == ["maybe"], bad_reason_report
assert gap_reason_report["status"] == "replay_ok", gap_reason_report
assert gap_reason_report["hrv_readiness_reasons"] == ["gap"], gap_reason_report
assert gap_reason_report["last_hrv_readiness_reason"] == "gap", gap_reason_report
assert numeric_resp_report["status"] == "pass", numeric_resp_report
assert numeric_resp_report["app_ready_resp_status"] == "numeric", numeric_resp_report
assert numeric_resp_report["capture_summary_resp_status"] == "numeric", numeric_resp_report
assert numeric_resp_report["app_ready_resp_bpm"] == 12.5, numeric_resp_report
assert numeric_resp_report["capture_summary_resp_bpm"] == 12.5, numeric_resp_report
assert numeric_resp_report["resp_status_match"] is True, numeric_resp_report
assert numeric_resp_report["resp_bpm_delta"] == 0.0, numeric_resp_report
assert min_resp_report["status"] == "pass", min_resp_report
assert min_resp_report["app_ready_resp_bpm"] == min_resp_report["thresholds"]["min_resp_bpm"], min_resp_report
assert min_resp_report["capture_summary_resp_bpm"] == min_resp_report["thresholds"]["min_resp_bpm"], min_resp_report
assert max_resp_report["status"] == "pass", max_resp_report
assert max_resp_report["app_ready_resp_bpm"] == max_resp_report["thresholds"]["max_resp_bpm"], max_resp_report
assert max_resp_report["capture_summary_resp_bpm"] == max_resp_report["thresholds"]["max_resp_bpm"], max_resp_report
assert ready_report["reference_metadata"]["timeline_source"] == "timestamp_column", ready_report
assert derived_reference_report["status"] == "pass", derived_reference_report
assert derived_reference_report["reference_metadata"]["timeline_source"] == "derived_from_rr", derived_reference_report
assert derived_reference_report["reference_metadata"]["time_unit"] == "derived_from_rr", derived_reference_report
assert derived_reference_report["reference_metadata"]["time_column"] is None, derived_reference_report
assert derived_reference_report["window_alignment"]["window_start_delta_s"] == 1.0, derived_reference_report
assert derived_reference_report["window_alignment"]["window_end_delta_s"] == 1.0, derived_reference_report
assert nonfinite_report["status"] == "fail", nonfinite_report
assert nonfinite_report["failure"] == "WHOOP RR CSV contains malformed rows", nonfinite_report
assert nonfinite_reference_report["status"] == "fail", nonfinite_reference_report
assert nonfinite_reference_report["failure"] == "REF RR CSV contains malformed rows", nonfinite_reference_report
assert missing_rr_reference_report["status"] == "fail", missing_rr_reference_report
assert missing_rr_reference_report["failure"] == "REF RR CSV contains malformed rows", missing_rr_reference_report
assert missing_rr_reference_report["malformed_rows"]["examples"][0]["failure"] == "missing_rr_column", missing_rr_reference_report
assert gap_report["status"] == "fail", gap_report
assert gap_report["whoop"]["max_raw_gap_s"] == 4.0, gap_report
assert "WHOOP max RR gap 4.0s > 3.0s" in gap_report["failures"], gap_report
assert bad_reference_report["status"] == "fail", bad_reference_report
assert bad_reference_report["failure"] == "reference HRV metric delta exceeds tolerance", bad_reference_report
assert bad_reference_report["reference_metric_within_tolerance"]["rmssd"] is False, bad_reference_report
assert bad_reference_report["reference_metric_within_tolerance"]["sdnn"] is False, bad_reference_report
assert bad_reference_report["reference_metric_within_tolerance"]["pnn50"] is True, bad_reference_report
assert bad_reference_report["reference_metric_within_tolerance"]["lnrmssd"] is False, bad_reference_report
assert offset_reference_report["status"] == "fail", offset_reference_report
assert offset_reference_report["failure"] == "reference final window is not time-aligned", offset_reference_report
assert offset_reference_report["thresholds"]["max_window_alignment_s"] == 3.0, offset_reference_report
assert offset_reference_report["window_alignment"]["window_start_delta_s"] == 10000 / 1000, offset_reference_report
assert offset_reference_report["window_alignment"]["window_end_delta_s"] == 10000 / 1000, offset_reference_report
assert offset_reference_report["alignment_failures"] == ["window_start_delta_s", "window_end_delta_s"], offset_reference_report
assert stale_report["status"] == "fail", stale_report
assert stale_report["failure"] == "clean RR window marker missing", stale_report
assert late_marker_report["status"] == "fail", late_marker_report
assert late_marker_report["failure"] == "clean RR window marker occurs after first RR", late_marker_report
assert bad_marker_report["status"] == "fail", bad_marker_report
assert bad_marker_report["failure"] == "WHOOP quality marker RR CSV contains malformed rows", bad_marker_report
assert bad_marker_report["malformed_rows"]["examples"][0]["kind"] == "hrv_quality", bad_marker_report
assert short_elapsed_report["status"] == "fail", short_elapsed_report
assert short_elapsed_report["failure"] == "capture_summary elapsed is shorter than validation window", short_elapsed_report
assert missing_elapsed_report["status"] == "fail", missing_elapsed_report
assert missing_elapsed_report["failure"] == "capture_summary is missing count/confidence/window fields", missing_elapsed_report
assert missing_elapsed_report["missing_count_fields"] == ["elapsed"], missing_elapsed_report
assert missing_resp_report["status"] == "fail", missing_resp_report
assert missing_resp_report["failure"] == "ready app hrv snapshot is missing respiratory status", missing_resp_report
assert missing_resp_report["app_ready_resp_status"] is None, missing_resp_report
assert bad_resp_report["status"] == "fail", bad_resp_report
assert bad_resp_report["failure"] == "ready app hrv snapshot respiratory rate out of range", bad_resp_report
assert bad_resp_report["app_ready_resp_status"] == "numeric", bad_resp_report
assert bad_resp_report["app_ready_resp_bpm"] == 45.0, bad_resp_report
assert malformed_resp_report["status"] == "fail", malformed_resp_report
assert malformed_resp_report["failure"] == "ready app hrv snapshot is missing respiratory status", malformed_resp_report
assert malformed_resp_report["app_ready_resp_status"] == "fast", malformed_resp_report
assert malformed_resp_report["app_ready_resp_bpm"] is None, malformed_resp_report
assert resp_mismatch_report["status"] == "fail", resp_mismatch_report
assert resp_mismatch_report["failure"] == "capture_summary respiratory status does not match ready app snapshot", resp_mismatch_report
assert resp_mismatch_report["app_ready_resp_status"] == "numeric", resp_mismatch_report
assert resp_mismatch_report["capture_summary_resp_status"] == "learning", resp_mismatch_report
assert resp_mismatch_report["resp_status_match"] is False, resp_mismatch_report
assert resp_bpm_mismatch_report["status"] == "fail", resp_bpm_mismatch_report
assert resp_bpm_mismatch_report["failure"] == "capture_summary respiratory rate does not match ready app snapshot", resp_bpm_mismatch_report
assert resp_bpm_mismatch_report["app_ready_resp_status"] == "numeric", resp_bpm_mismatch_report
assert resp_bpm_mismatch_report["capture_summary_resp_status"] == "numeric", resp_bpm_mismatch_report
assert resp_bpm_mismatch_report["resp_status_match"] is True, resp_bpm_mismatch_report
assert abs(resp_bpm_mismatch_report["resp_bpm_delta"] - 0.1) < 1e-9, resp_bpm_mismatch_report
assert early_summary_report["status"] == "fail", early_summary_report
assert early_summary_report["failure"] == "capture_summary occurs before ready app hrv snapshot", early_summary_report
assert early_summary_report["app_ready_snapshot_row_elapsed_s"] == 5.0, early_summary_report
assert early_summary_report["capture_summary_row_elapsed_s"] == 4.0, early_summary_report
assert early_summary_report["capture_summary_after_ready_snapshot"] is False, early_summary_report
assert summary_before_last_rr_report["status"] == "fail", summary_before_last_rr_report
assert summary_before_last_rr_report["failure"] == "capture_summary occurs before final RR row", summary_before_last_rr_report
assert summary_before_last_rr_report["app_ready_snapshot_row_elapsed_s"] == 5.0, summary_before_last_rr_report
assert summary_before_last_rr_report["capture_summary_row_elapsed_s"] == 5.0, summary_before_last_rr_report
assert summary_before_last_rr_report["whoop_last_rr_row_elapsed_s"] == 6.0, summary_before_last_rr_report
assert summary_before_last_rr_report["capture_summary_after_ready_snapshot"] is True, summary_before_last_rr_report
assert summary_before_last_rr_report["capture_summary_after_last_rr"] is False, summary_before_last_rr_report
assert summary_before_last_hrv_report["status"] == "fail", summary_before_last_hrv_report
assert summary_before_last_hrv_report["failure"] == "capture_summary occurs before final HRV row", summary_before_last_hrv_report
assert summary_before_last_hrv_report["app_ready_snapshot_row_elapsed_s"] == 5.0, summary_before_last_hrv_report
assert summary_before_last_hrv_report["capture_summary_row_elapsed_s"] == 5.0, summary_before_last_hrv_report
assert summary_before_last_hrv_report["whoop_last_rr_row_elapsed_s"] == 5.0, summary_before_last_hrv_report
assert summary_before_last_hrv_report["whoop_last_hrv_row_elapsed_s"] == 6.0, summary_before_last_hrv_report
assert summary_before_last_hrv_report["capture_summary_after_last_rr"] is True, summary_before_last_hrv_report
assert summary_before_last_hrv_report["capture_summary_after_last_hrv"] is False, summary_before_last_hrv_report
PY

printf 'PASS: learning-token HRV exports and malformed reference rejection behave as expected\n'
