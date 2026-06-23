#!/usr/bin/env bash
set -euo pipefail

device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
bundle_id=${ATRIA_BUNDLE_ID:-${WHOOP_BUNDLE_ID:-com.adidshaft.atria}}
evidence_dir=""

usage() {
  cat <<'EOF'
Usage:
  ./pull_atria_state.sh [--device DEVICE_ID] [--bundle-id BUNDLE_ID] --evidence-dir DIR

Copies Atria's current on-device state without building, installing, launching,
or terminating the app. This is for long-wear evidence pulls where preserving the
running BLE session matters.

Pulled files, when present:
  - sessions.json
  - atria-active-session.json
  - atria-active-session.segments/
  - historical-archive.jsonl
  - app preferences plist
  - process-check.txt
  - pull-summary.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device_id=${2:?--device requires a value}
      shift 2
      ;;
    --bundle-id)
      bundle_id=${2:?--bundle-id requires a value}
      shift 2
      ;;
    --evidence-dir)
      evidence_dir=${2:?--evidence-dir requires a value}
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

if [[ -z "$device_id" ]]; then
  printf 'Set ATRIA_DEVICE_ID or pass --device with your physical iPhone CoreDevice identifier.\n' >&2
  exit 64
fi

if [[ -z "$evidence_dir" ]]; then
  usage >&2
  exit 2
fi

mkdir -p "$evidence_dir"
summary="$evidence_dir/pull-summary.txt"
: > "$summary"

copy_from_container() {
  local source_path=$1
  local destination_path=$2
  local label=$3

  if xcrun devicectl device copy from \
    --device "$device_id" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" \
    --source "$source_path" \
    --destination "$destination_path" >> "$summary" 2>&1; then
    printf '%s_status=ok\n' "$label" | tee -a "$summary"
    printf '%s_source=%s\n' "$label" "$source_path" | tee -a "$summary"
    printf '%s_file=%s\n' "$label" "$destination_path" | tee -a "$summary"
    return 0
  fi
  printf '%s_status=missing\n' "$label" | tee -a "$summary"
  printf '%s_source=%s\n' "$label" "$source_path" | tee -a "$summary"
  return 1
}

printf 'pull_mode=non_disruptive_copy_only\n' | tee -a "$summary"
printf 'device_id=%s\n' "$device_id" | tee -a "$summary"
printf 'bundle_id=%s\n' "$bundle_id" | tee -a "$summary"
printf 'evidence_dir=%s\n' "$evidence_dir" | tee -a "$summary"

if xcrun devicectl device info processes --device "$device_id" > "$evidence_dir/processes.txt" 2>&1; then
  if grep -E 'Atria|com\.adidshaft\.atria|/Whoop\.app/Whoop|/Whoop\.app/PlugIns/WhoopWidgetExtension\.appex/WhoopWidgetExtension' "$evidence_dir/processes.txt" > "$evidence_dir/process-check.txt"; then
    printf 'process_status=running\n' | tee -a "$summary"
    if grep -Eq 'Atria|com\.adidshaft\.atria' "$evidence_dir/process-check.txt"; then
      printf 'process_name_status=atria\n' | tee -a "$summary"
    else
      printf 'process_name_status=not_atria\n' | tee -a "$summary"
    fi
    whoop_process_count=$(grep -Ec '/Whoop\.app/(Whoop|PlugIns/WhoopWidgetExtension\.appex/WhoopWidgetExtension)' "$evidence_dir/process-check.txt" || true)
    if [[ "$whoop_process_count" -gt 0 ]]; then
      printf 'official_whoop_process_status=running\n' | tee -a "$summary"
      printf 'official_whoop_process_count=%s\n' "$whoop_process_count" | tee -a "$summary"
      if grep -q '/Whoop\.app/Whoop' "$evidence_dir/process-check.txt"; then
        printf 'official_whoop_main_process=1\n' | tee -a "$summary"
      else
        printf 'official_whoop_main_process=0\n' | tee -a "$summary"
      fi
      if grep -q '/Whoop\.app/PlugIns/WhoopWidgetExtension\.appex/WhoopWidgetExtension' "$evidence_dir/process-check.txt"; then
        printf 'official_whoop_widget_process=1\n' | tee -a "$summary"
      else
        printf 'official_whoop_widget_process=0\n' | tee -a "$summary"
      fi
      printf 'official_whoop_coexistence_risk=1\n' | tee -a "$summary"
    else
      printf 'official_whoop_process_status=not_listed\n' | tee -a "$summary"
      printf 'official_whoop_process_count=0\n' | tee -a "$summary"
      printf 'official_whoop_main_process=0\n' | tee -a "$summary"
      printf 'official_whoop_widget_process=0\n' | tee -a "$summary"
      printf 'official_whoop_coexistence_risk=0\n' | tee -a "$summary"
    fi
    cat "$evidence_dir/process-check.txt" >> "$summary"
  else
    printf 'process_status=not_listed\n' | tee -a "$summary"
    printf 'official_whoop_process_status=not_listed\n' | tee -a "$summary"
    printf 'official_whoop_process_count=0\n' | tee -a "$summary"
    printf 'official_whoop_main_process=0\n' | tee -a "$summary"
    printf 'official_whoop_widget_process=0\n' | tee -a "$summary"
    printf 'official_whoop_coexistence_risk=0\n' | tee -a "$summary"
  fi
else
  printf 'process_status=unknown\n' | tee -a "$summary"
  printf 'official_whoop_process_status=unknown\n' | tee -a "$summary"
fi

copy_from_container "Documents/sessions.json" "$evidence_dir/sessions.json" "sessions" || true

if xcrun devicectl device copy from \
  --device "$device_id" \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id" \
  --source "Documents/atria-active-session.segments" \
  --destination "$evidence_dir/atria-active-session.segments" >> "$summary" 2>&1; then
  printf 'active_journal_segments_status=ok\n' | tee -a "$summary"
  printf 'active_journal_segments_source=Documents/atria-active-session.segments\n' | tee -a "$summary"
  printf 'active_journal_segments_dir=%s\n' "$evidence_dir/atria-active-session.segments" | tee -a "$summary"
else
  printf 'active_journal_segments_status=missing\n' | tee -a "$summary"
fi

active_status=missing
for active_source in "Documents/atria-active-session.json" "Documents/whoop-active-session.json"; do
  if copy_from_container "$active_source" "$evidence_dir/atria-active-session.json" "active_journal"; then
    active_status=ok
    break
  fi
done
if [[ "$active_status" != "ok" ]]; then
  printf 'active_journal_file_status=missing\n' | tee -a "$summary"
fi

copy_from_container "Documents/whoop-historical/historical-archive.jsonl" "$evidence_dir/historical-archive.jsonl" "historical_archive" || true
copy_from_container "Library/Preferences/${bundle_id}.plist" "$evidence_dir/preferences.plist" "preferences" || true

python3 - "$evidence_dir" <<'PY' | tee -a "$summary"
import datetime as dt
import json
import plistlib
import sys
import time
from pathlib import Path

evidence = Path(sys.argv[1])
apple_epoch = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
ist = dt.timezone(dt.timedelta(hours=5, minutes=30), "IST")

def app_time(value):
    if isinstance(value, (int, float)):
        return apple_epoch + dt.timedelta(seconds=float(value))
    if isinstance(value, str):
        text = value[:-1] + "+00:00" if value.endswith("Z") else value
        parsed = dt.datetime.fromisoformat(text)
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
    return None

def bool_int(value):
    return 1 if bool(value) else 0

def emit_offline_sync_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"preferences_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    requested_at = prefs.get("whoop.offlineSync.rangeLossBackfillRequestedAt")
    started_at = prefs.get("whoop.offlineSync.rangeLossBackfillStartedAt")
    requested_age = max(0.0, now - float(requested_at)) if isinstance(requested_at, (int, float)) and requested_at > 0 else -1.0
    started_age = max(0.0, now - float(started_at)) if isinstance(started_at, (int, float)) and started_at > 0 else -1.0
    print(f"offline_sync_enabled={bool_int(prefs.get('whoop.offlineSync.enabled'))}")
    print(f"offline_sync_attempts={int(prefs.get('whoop.offlineSync.attempts') or 0)}")
    print(f"offline_sync_last_status={prefs.get('whoop.offlineSync.lastStatus') or 'none'}")
    print(f"offline_sync_last_reason={prefs.get('whoop.offlineSync.lastReason') or 'none'}")
    print(f"offline_range_loss_backfill_pending={bool_int(prefs.get('whoop.offlineSync.rangeLossBackfillPending'))}")
    print(f"offline_range_loss_backfill_reason={prefs.get('whoop.offlineSync.rangeLossBackfillReason') or 'none'}")
    print(f"offline_range_loss_backfill_requested_age_s={requested_age:.1f}")
    print(f"offline_range_loss_backfill_started_age_s={started_age:.1f}")

emit_offline_sync_preferences()

def rr_window_audit(prefix, rr, relative_times=False, emit=True):
    rr_values = []
    rr_times = []
    for sample in rr:
        try:
            rr_values.append(int(round(float(sample.get("ms")))))
        except Exception:
            pass
        if sample.get("t") is not None:
            try:
                if relative_times:
                    rr_times.append(float(sample.get("t")))
                else:
                    converted = app_time(sample.get("t"))
                    if converted is not None:
                        rr_times.append(converted.timestamp())
            except Exception:
                pass
    rr_times.sort()
    rr_max_gap = 0.0
    rr_gap_over_3 = 0
    rr_observed_3 = 0.0
    for left, right in zip(rr_times, rr_times[1:]):
        gap = max(0.0, right - left)
        rr_max_gap = max(rr_max_gap, gap)
        if gap > 3:
            rr_gap_over_3 += 1
        else:
            rr_observed_3 += gap
    rr_span = max(0.0, rr_times[-1] - rr_times[0]) if len(rr_times) > 1 else 0.0
    rr_coverage_3 = min(100, max(0, round((rr_observed_3 / rr_span) * 100))) if rr_span > 0 else 0
    bounded_rr = [value for value in rr_values if 300 <= value <= 2000]
    corrected_rr = []
    dropped_delta = 0
    previous_kept = None
    for value in bounded_rr:
        if previous_kept is not None and previous_kept > 0 and abs(value - previous_kept) / previous_kept > 0.20:
            dropped_delta += 1
            continue
        corrected_rr.append(value)
        previous_kept = value
    rr_duration = sum(rr_values) / 1000.0
    kept_percent = round((len(corrected_rr) / len(rr_values)) * 100) if rr_values else 0
    gate_b_ready = (
        rr_duration >= 300
        and rr_max_gap <= 3
        and len(corrected_rr) >= 240
        and kept_percent >= 75
    )
    blockers = []
    if rr_duration < 300:
        blockers.append(f"rr_duration_{int(rr_duration)}s_lt_300s")
    if rr_max_gap > 3:
        blockers.append(f"rr_gap_{rr_max_gap:.1f}s_gt_3s")
    if len(corrected_rr) < 240:
        blockers.append(f"corrected_beats_{len(corrected_rr)}_lt_240")
    if kept_percent < 75:
        blockers.append(f"kept_{kept_percent}p_lt_75p")
    blocker = "none_reference_still_required" if gate_b_ready else ("+".join(blockers) if blockers else "unknown")
    if emit:
        print(f"{prefix}_rr_max_gap_s={rr_max_gap:.1f}")
        print(f"{prefix}_rr_gap_over_3s={rr_gap_over_3}")
        print(f"{prefix}_rr_coverage_3s_percent={rr_coverage_3}")
        print(f"{prefix}_rr_raw_beats={len(rr_values)}")
        print(f"{prefix}_rr_duration_s={rr_duration:.1f}")
        print(f"{prefix}_rr_bounds_kept={len(bounded_rr)}")
        print(f"{prefix}_rr_delta_dropped={dropped_delta}")
        print(f"{prefix}_rr_corrected_beats={len(corrected_rr)}")
        print(f"{prefix}_rr_kept_percent={kept_percent}")
        print(f"{prefix}_rr_gate_b_local_ready={1 if gate_b_ready else 0}")
        print(f"{prefix}_rr_gate_b_local_blocker={blocker}")
    return {
        "ready": gate_b_ready,
        "raw": len(rr_values),
        "duration": rr_duration,
        "corrected": len(corrected_rr),
        "kept_percent": kept_percent,
        "max_gap": rr_max_gap,
        "blocker": blocker,
    }

def rr_segments(rr, relative_times=False, max_gap=3.0):
    keyed = []
    for sample in rr:
        if sample.get("t") is None:
            continue
        try:
            key = float(sample.get("t")) if relative_times else app_time(sample.get("t")).timestamp()
            keyed.append((key, sample))
        except Exception:
            continue
    keyed.sort(key=lambda item: item[0])
    segments = []
    current = []
    previous = None
    for key, sample in keyed:
        if previous is not None and max(0.0, key - previous) > max_gap and current:
            segments.append(current)
            current = []
        current.append(sample)
        previous = key
    if current:
        segments.append(current)
    return segments

sessions_path = evidence / "sessions.json"
if sessions_path.exists():
    try:
        sessions = json.loads(sessions_path.read_text())
        if isinstance(sessions, dict):
            sessions = sessions.get("sessions", [])
        latest = max(sessions, key=lambda s: float(s.get("end", s.get("start", 0)))) if sessions else None
        phone_sessions = [
            session for session in sessions
            if session.get("phoneMotionSource") is not None
            or session.get("phoneMotionSamples") is not None
        ]
        phone_nonzero_sessions = [
            session for session in phone_sessions
            if int(session.get("phoneMotionSamples") or 0) > 0
        ]
        latest_phone = max(phone_sessions, key=lambda s: float(s.get("end", s.get("start", 0)))) if phone_sessions else None
        latest_phone_nonzero = max(phone_nonzero_sessions, key=lambda s: float(s.get("end", s.get("start", 0)))) if phone_nonzero_sessions else None
        print(f"sessions_count={len(sessions)}")
        print(f"phone_motion_sessions={len(phone_sessions)}")
        print(f"phone_motion_nonzero_sessions={len(phone_nonzero_sessions)}")
        best_rr = None
        best_rr_segment = None
        for session in sessions:
            rr_points_for_session = session.get("rrPoints") or []
            if not rr_points_for_session:
                continue
            audit = rr_window_audit("saved_rr_candidate_silent", rr_points_for_session, relative_times=True, emit=False)
            score = (
                1 if audit["ready"] else 0,
                audit["corrected"],
                audit["duration"],
                audit["kept_percent"],
            )
            if best_rr is None or score > best_rr["score"]:
                best_rr = {
                    "score": score,
                    "label": session.get("label", ""),
                    "start": session.get("start", 0),
                    "end": session.get("end", session.get("start", 0)),
                    **audit,
                }
            for segment in rr_segments(rr_points_for_session, relative_times=True):
                segment_audit = rr_window_audit("saved_rr_segment_silent", segment, relative_times=True, emit=False)
                segment_score = (
                    1 if segment_audit["ready"] else 0,
                    segment_audit["corrected"],
                    segment_audit["duration"],
                    segment_audit["kept_percent"],
                )
                if best_rr_segment is None or segment_score > best_rr_segment["score"]:
                    best_rr_segment = {
                        "score": segment_score,
                        "label": session.get("label", ""),
                        "start": session.get("start", 0),
                        "end": session.get("end", session.get("start", 0)),
                        **segment_audit,
                    }
        if best_rr:
            start_best = app_time(best_rr["start"]).astimezone(ist)
            end_best = app_time(best_rr["end"]).astimezone(ist)
            print(f"best_saved_rr_label={best_rr['label']}")
            print(f"best_saved_rr_start={start_best.isoformat()}")
            print(f"best_saved_rr_end={end_best.isoformat()}")
            print(f"best_saved_rr_raw_beats={best_rr['raw']}")
            print(f"best_saved_rr_duration_s={best_rr['duration']:.1f}")
            print(f"best_saved_rr_corrected_beats={best_rr['corrected']}")
            print(f"best_saved_rr_kept_percent={best_rr['kept_percent']}")
            print(f"best_saved_rr_max_gap_s={best_rr['max_gap']:.1f}")
            print(f"best_saved_rr_gate_b_local_ready={1 if best_rr['ready'] else 0}")
            print(f"best_saved_rr_gate_b_local_blocker={best_rr['blocker']}")
            print("best_saved_rr_reference_required=1")
        else:
            print("best_saved_rr_status=missing")
        if best_rr_segment:
            start_segment = app_time(best_rr_segment["start"]).astimezone(ist)
            end_segment = app_time(best_rr_segment["end"]).astimezone(ist)
            print(f"best_saved_rr_segment_label={best_rr_segment['label']}")
            print(f"best_saved_rr_segment_session_start={start_segment.isoformat()}")
            print(f"best_saved_rr_segment_session_end={end_segment.isoformat()}")
            print(f"best_saved_rr_segment_raw_beats={best_rr_segment['raw']}")
            print(f"best_saved_rr_segment_duration_s={best_rr_segment['duration']:.1f}")
            print(f"best_saved_rr_segment_corrected_beats={best_rr_segment['corrected']}")
            print(f"best_saved_rr_segment_kept_percent={best_rr_segment['kept_percent']}")
            print(f"best_saved_rr_segment_max_gap_s={best_rr_segment['max_gap']:.1f}")
            print(f"best_saved_rr_segment_gate_b_local_ready={1 if best_rr_segment['ready'] else 0}")
            print(f"best_saved_rr_segment_gate_b_local_blocker={best_rr_segment['blocker']}")
            print("best_saved_rr_segment_reference_required=1")
        else:
            print("best_saved_rr_segment_status=missing")
        if latest:
            start = app_time(latest.get("start", 0)).astimezone(ist)
            end = app_time(latest.get("end", latest.get("start", 0))).astimezone(ist)
            points = latest.get("points") or []
            rr_points = latest.get("rrPoints") or []
            bpms = [int(p.get("bpm", 0)) for p in points if p.get("bpm") is not None]
            print("file_durability_status=saved_sessions_present")
            print("whoop_primary_data_source=saved_sessions_hr_rr")
            print(f"latest_session_label={latest.get('label', '')}")
            print(f"latest_session_start={start.isoformat()}")
            print(f"latest_session_end={end.isoformat()}")
            print(f"latest_session_points={len(points)}")
            print(f"latest_session_rr_points={len(rr_points)}")
            print(f"latest_session_rr_status={'rr_present' if rr_points else 'hr_only'}")
            print(f"latest_session_duration_s={max(0, int((end - start).total_seconds()))}")
            print(f"latest_session_peak_hr={max(bpms) if bpms else 0}")
            rr_window_audit("latest_session", rr_points, relative_times=True)
        if latest_phone:
            print(f"latest_phone_motion_label={latest_phone.get('label', '')}")
            print(f"latest_phone_motion_source={latest_phone.get('phoneMotionSource', 'missing')}")
            print(f"latest_phone_motion_validated={1 if latest_phone.get('phoneMotionValidated') is True else 0}")
            print("latest_phone_motion_wrist_validated=0")
            print(f"latest_phone_motion_samples={int(latest_phone.get('phoneMotionSamples') or 0)}")
            print(f"latest_phone_motion_mean_delta_g={latest_phone.get('phoneMotionMeanDeltaG', 'missing')}")
            print(f"latest_phone_motion_max_delta_g={latest_phone.get('phoneMotionMaxDeltaG', 'missing')}")
            print(f"latest_phone_motion_over_still_threshold={int(latest_phone.get('phoneMotionOverStillThreshold') or 0)}")
            print(f"latest_phone_motion_still_threshold_g={latest_phone.get('phoneMotionStillThresholdG', 'missing')}")
        else:
            print("phone_motion_status=missing_saved_session_fields")
        if latest_phone_nonzero:
            print(f"latest_phone_motion_nonzero_label={latest_phone_nonzero.get('label', '')}")
            print(f"latest_phone_motion_nonzero_source={latest_phone_nonzero.get('phoneMotionSource', 'missing')}")
            print(f"latest_phone_motion_nonzero_validated={1 if latest_phone_nonzero.get('phoneMotionValidated') is True else 0}")
            print("latest_phone_motion_nonzero_wrist_validated=0")
            print(f"latest_phone_motion_nonzero_samples={int(latest_phone_nonzero.get('phoneMotionSamples') or 0)}")
            print(f"latest_phone_motion_nonzero_mean_delta_g={latest_phone_nonzero.get('phoneMotionMeanDeltaG', 'missing')}")
            print(f"latest_phone_motion_nonzero_max_delta_g={latest_phone_nonzero.get('phoneMotionMaxDeltaG', 'missing')}")
            print(f"latest_phone_motion_nonzero_over_still_threshold={int(latest_phone_nonzero.get('phoneMotionOverStillThreshold') or 0)}")
            print(f"latest_phone_motion_nonzero_still_threshold_g={latest_phone_nonzero.get('phoneMotionStillThresholdG', 'missing')}")
        else:
            print("phone_motion_nonzero_status=missing")
    except Exception as exc:
        print(f"sessions_summary_error={type(exc).__name__}:{exc}")

def reconstructed_segmented_journal(evidence):
    directory = evidence / "atria-active-session.segments"
    if not directory.exists():
        return None
    rows = []
    for path in directory.glob("*.json"):
        try:
            segment = json.loads(path.read_text())
        except Exception:
            continue
        if segment.get("schema") == 2:
            rows.append(segment)
    rows.sort(key=lambda row: int(row.get("sequence", 0)))
    if not rows:
        return None
    first = rows[0]
    journal = {
        "schema": 1,
        "id": first.get("id"),
        "label": first.get("label", ""),
        "startedAt": first.get("startedAt"),
        "updatedAt": first.get("updatedAt"),
        "samples": [],
        "rrSamples": [],
        "rawHRNotifications": first.get("rawHRNotifications", 0),
        "acceptedHRSamples": first.get("acceptedHRSamples", 0),
        "zeroHRSamples": first.get("zeroHRSamples", 0),
        "heldArtifacts": first.get("heldArtifacts", 0),
        "droppedArtifacts": first.get("droppedArtifacts", 0),
        "rawHRGaps": first.get("rawHRGaps", 0),
        "acceptedHRGaps": first.get("acceptedHRGaps", 0),
        "maxRawHRGap": first.get("maxRawHRGap", 0),
        "maxAcceptedHRGap": first.get("maxAcceptedHRGap", 0),
        "batteryLevel": first.get("batteryLevel"),
        "thermalState": first.get("thermalState"),
        "lowPowerMode": first.get("lowPowerMode"),
        "powerMode": first.get("powerMode"),
        "cadenceMultiplier": first.get("cadenceMultiplier"),
    }
    for segment in rows:
        if segment.get("id") != journal["id"]:
            continue
        if len(journal["samples"]) == int(segment.get("sampleStartIndex", len(journal["samples"]))):
            journal["samples"].extend(segment.get("samples") or [])
        if len(journal["rrSamples"]) == int(segment.get("rrSampleStartIndex", len(journal["rrSamples"]))):
            journal["rrSamples"].extend(segment.get("rrSamples") or [])
        for key in ("label", "updatedAt", "rawHRNotifications", "acceptedHRSamples", "zeroHRSamples",
                    "heldArtifacts", "droppedArtifacts", "rawHRGaps", "acceptedHRGaps",
                    "maxRawHRGap", "maxAcceptedHRGap", "batteryLevel", "thermalState",
                    "lowPowerMode", "powerMode", "cadenceMultiplier"):
            journal[key] = segment.get(key, journal.get(key))
    return journal

journal_path = evidence / "atria-active-session.json"
journal = None
if journal_path.exists():
    try:
        journal = json.loads(journal_path.read_text())
    except Exception as exc:
        print(f"active_journal_file_summary_error={type(exc).__name__}:{exc}")
if journal is None:
    journal = reconstructed_segmented_journal(evidence)
    if journal is not None:
        try:
            journal_path.write_text(json.dumps(journal, indent=2, sort_keys=True))
            print("active_journal_reconstructed_from_segments=1")
        except Exception as exc:
            print(f"active_journal_reconstruct_write_error={type(exc).__name__}:{exc}")
if journal is not None:
    print("active_journal_final_status=ok")
    try:
        samples = journal.get("samples") or []
        rr = journal.get("rrSamples") or []
        started = app_time(journal.get("startedAt", samples[0].get("t") if samples else 0))
        updated = app_time(journal.get("updatedAt", samples[-1].get("t") if samples else 0))
        bpms = [int(sample.get("bpm", 0)) for sample in samples if sample.get("bpm") is not None]
        now = dt.datetime.now(dt.timezone.utc)
        print(f"active_journal_schema={journal.get('schema')}")
        print(f"active_journal_label={journal.get('label', '')}")
        print(f"active_journal_samples={len(samples)}")
        print(f"active_journal_rr_values={len(rr)}")
        print(f"active_journal_rr_status={'rr_present' if rr else 'hr_only'}")
        print(f"active_journal_started={started.astimezone(ist).isoformat() if started else 'none'}")
        print(f"active_journal_updated={updated.astimezone(ist).isoformat() if updated else 'none'}")
        age = max(0, int((now - updated.astimezone(dt.timezone.utc)).total_seconds())) if updated else -1
        freshness = "fresh" if 0 <= age <= 90 else "stale"
        continuity = "active"
        continuity_reason = "fresh_journal"
        if freshness == "stale":
            continuity = "stalled"
            continuity_reason = "stale_journal"
        elif len(samples) < 2:
            continuity = "stalled"
            continuity_reason = "insufficient_active_samples"
        elif not rr:
            continuity = "hr_only"
            continuity_reason = "no_active_rr"
        print(f"active_journal_age_s={age}")
        print(f"active_journal_freshness={freshness}")
        print(f"active_journal_continuity_status={continuity}")
        print(f"active_journal_continuity_reason={continuity_reason}")
        if continuity == "stalled" and sessions_path.exists():
            print("active_journal_interruption_class=live_stream_interrupted_saved_sessions_present")
            print("file_durability_status=saved_sessions_preserved")
            print("live_stream_consistency_status=interrupted_not_file_loss")
        print(f"active_journal_duration_s={max(0, int((updated - started).total_seconds())) if started and updated else 0}")
        print(f"active_journal_peak_hr={max(bpms) if bpms else 0}")
        rr_window_audit("active_journal", rr, relative_times=False)
    except Exception as exc:
        print(f"active_journal_summary_error={type(exc).__name__}:{exc}")
else:
    print("active_journal_final_status=missing")
PY
