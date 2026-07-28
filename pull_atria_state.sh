#!/usr/bin/env bash
set -euo pipefail

device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
bundle_id=${ATRIA_BUNDLE_ID:-${WHOOP_BUNDLE_ID:-com.adidshaft.atria}}
evidence_dir=""
runtime_only=0
installed_provenance_only=0
devicectl_cmd=()

usage() {
  cat <<'EOF'
Usage:
  ./pull_atria_state.sh [--device DEVICE_ID] [--bundle-id BUNDLE_ID] [--runtime-only] [--installed-provenance-only] --evidence-dir DIR

Copies Atria's current on-device state without building, installing, launching,
or terminating the app. This is for long-wear evidence pulls where preserving the
running BLE session matters.

Use --runtime-only for a small, non-disruptive checkpoint of sessions, the
active journal, preferences, provenance, and authoritative runtime state. It
intentionally skips the large historical archive, sensor captures, and step
calibration archive. A later full pull remains required for archive acceptance.

Use --installed-provenance-only when proving an already-running installed build
after the worktree has legitimately advanced. Installed binding/integrity still
fails closed; source drift is reported separately instead of invalidating the
older binary's runtime evidence.

Pulled files, when present:
  - sessions.json
  - daily-rollups.json
  - atria-active-session.json
  - atria-active-session.segments/
  - historical-archive.jsonl
  - historical-archive.diagnostics.json
  - historical-archive.identity.jsonl
  - historical-archive.manifest.json
  - historical-archive-segments/
  - atria-captures/ plus SHA-256 manifest
  - atria-step-calibration/
  - recovered completed step-calibration manifest (when present)
  - authoritative workout/route/step-ledger state plus SHA-256 manifest
  - installed-app-provenance.json plus current installed-app-metadata.json
  - app preferences plist
  - app-group preferences plist (widget publication)
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
    --runtime-only)
      runtime_only=1
      shift
      ;;
    --installed-provenance-only)
      installed_provenance_only=1
      shift
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

if [[ -e "$evidence_dir" ]]; then
  if [[ ! -d "$evidence_dir" ]]; then
    printf 'Evidence path exists and is not a directory: %s\n' "$evidence_dir" >&2
    exit 73
  fi
  if find "$evidence_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    printf 'Evidence directory must be new or empty: %s\n' "$evidence_dir" >&2
    exit 73
  fi
fi

if [[ -n "${ATRIA_DEVICETCL:-}" ]]; then
  devicectl_cmd=("$ATRIA_DEVICETCL")
elif xcrun --find devicectl >/dev/null 2>&1; then
  devicectl_cmd=(xcrun devicectl)
elif command -v devicectl >/dev/null 2>&1; then
  devicectl_cmd=(devicectl)
elif [[ -x /Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl ]]; then
  devicectl_cmd=(/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl)
else
  printf 'Unable to find devicectl via xcrun, PATH, or CoreDevice framework fallback.\n' >&2
  exit 69
fi

mkdir -p "$evidence_dir"
summary="$evidence_dir/pull-summary.txt"
: > "$summary"

copy_from_container() {
  local source_path=$1
  local destination_path=$2
  local label=$3

  if "${devicectl_cmd[@]}" device copy from \
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

copy_from_group_container() {
  local source_path=$1
  local destination_path=$2
  local label=$3
  local group_id=$4

  if "${devicectl_cmd[@]}" device copy from \
    --device "$device_id" \
    --domain-type appGroupDataContainer \
    --domain-identifier "$group_id" \
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

copy_first_from_container() {
  local destination_path=$1
  local label=$2
  shift 2

  rm -f "${destination_path}.partial"

  local source_path
  for source_path in "$@"; do
    if "${devicectl_cmd[@]}" device copy from \
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
  done
  if [[ -s "$destination_path" ]]; then
    local partial_bytes
    partial_bytes=$(wc -c < "$destination_path" | tr -d ' ')
    : > "${destination_path}.partial"
    printf '%s_status=partial_copy\n' "$label" | tee -a "$summary"
    printf '%s_file=%s\n' "$label" "$destination_path" | tee -a "$summary"
    printf '%s_partial_bytes=%s\n' "$label" "$partial_bytes" | tee -a "$summary"
    return 0
  fi
  printf '%s_status=missing\n' "$label" | tee -a "$summary"
  printf '%s_sources=%s\n' "$label" "$*" | tee -a "$summary"
  return 1
}

# Preserve every evidence path while avoiding another physical copy when an
# archive artifact is byte-identical to one in an earlier sibling pull. The
# replacement is atomic: create the hard link first, then rename it over the
# newly pulled file. A failed link leaves the fresh copy untouched.
deduplicate_archive_file() {
  local current_path=$1
  local label=$2
  [[ -f "$current_path" ]] || return 0

  local evidence_parent
  local current_size
  local candidate_path=""
  evidence_parent=$(dirname "$evidence_dir")
  current_size=$(stat -f '%z' "$current_path")
  while IFS= read -r -d '' possible_path; do
    [[ "$possible_path" == "$current_path" ]] && continue
    # Nested phase pulls (for example pre-relaunch + post-backfill evidence)
    # intentionally share one evidence root. Byte-identical immutable archive
    # artifacts are safe to hard-link there too; excluding the whole current
    # root recreated hundreds of megabytes inside every multi-phase proof.
    if cmp -s "$possible_path" "$current_path"; then
      candidate_path=$possible_path
      break
    fi
  done < <(find "$evidence_parent" -type f \
    -name "$(basename "$current_path")" \
    -size "${current_size}c" -print0 2>/dev/null)

  if [[ -z "$candidate_path" ]]; then
    printf '%s_dedup_status=unique\n' "$label" | tee -a "$summary"
    return 0
  fi

  local temporary_link="${current_path}.dedupe-link-$$"
  if ln "$candidate_path" "$temporary_link" 2>/dev/null; then
    mv -f "$temporary_link" "$current_path"
    printf '%s_dedup_status=hardlinked\n' "$label" | tee -a "$summary"
    printf '%s_dedup_source=%s\n' "$label" "$candidate_path" | tee -a "$summary"
    printf '%s_dedup_saved_bytes=%s\n' "$label" "$current_size" | tee -a "$summary"
  else
    printf '%s_dedup_status=unavailable_fresh_copy_retained\n' "$label" | tee -a "$summary"
  fi
}

printf 'pull_mode=non_disruptive_copy_only\n' | tee -a "$summary"
printf 'device_id=%s\n' "$device_id" | tee -a "$summary"
printf 'bundle_id=%s\n' "$bundle_id" | tee -a "$summary"
printf 'evidence_dir=%s\n' "$evidence_dir" | tee -a "$summary"

installed_metadata="$evidence_dir/installed-app-metadata.json"
if "${devicectl_cmd[@]}" device info apps \
  --device "$device_id" \
  --bundle-id "$bundle_id" \
  --require-container-access \
  --include-container-paths \
  --include-app-group-identifiers \
  --json-output "$installed_metadata" >> "$summary" 2>&1; then
  printf 'installed_app_metadata_status=ok\n' | tee -a "$summary"
  printf 'installed_app_metadata_file=%s\n' "$installed_metadata" | tee -a "$summary"
else
  printf 'installed_app_metadata_status=missing\n' | tee -a "$summary"
fi

if "${devicectl_cmd[@]}" device info processes --device "$device_id" > "$evidence_dir/processes.txt" 2>&1; then
  atria_main_pattern='/Atria\.app/Atria([[:space:]]|$)'
  atria_widget_pattern='/Atria\.app/PlugIns/AtriaWidget\.appex/AtriaWidget([[:space:]]|$)'
  whoop_widget_pattern='/Whoop\.app/PlugIns/(WhoopWidgetExtension|AtriaWidgetExtension)\.appex/(WhoopWidgetExtension|AtriaWidgetExtension)'
  if grep -E "${atria_main_pattern}|${atria_widget_pattern}|/Whoop\.app/Whoop|${whoop_widget_pattern}" "$evidence_dir/processes.txt" > "$evidence_dir/process-check.txt"; then
    if grep -Eq "$atria_main_pattern" "$evidence_dir/process-check.txt"; then
      printf 'process_status=running\n' | tee -a "$summary"
      printf 'process_name_status=atria\n' | tee -a "$summary"
      printf 'atria_main_process=1\n' | tee -a "$summary"
    else
      printf 'process_status=not_listed\n' | tee -a "$summary"
      printf 'process_name_status=not_atria\n' | tee -a "$summary"
      printf 'atria_main_process=0\n' | tee -a "$summary"
    fi
    if grep -Eq "$atria_widget_pattern" "$evidence_dir/process-check.txt"; then
      printf 'atria_widget_process=1\n' | tee -a "$summary"
    else
      printf 'atria_widget_process=0\n' | tee -a "$summary"
    fi
    whoop_process_count=$(grep -Ec "/Whoop\.app/(Whoop|PlugIns/(WhoopWidgetExtension|AtriaWidgetExtension)\.appex/(WhoopWidgetExtension|AtriaWidgetExtension))" "$evidence_dir/process-check.txt" || true)
    if [[ "$whoop_process_count" -gt 0 ]]; then
      printf 'official_whoop_process_status=running\n' | tee -a "$summary"
      printf 'official_whoop_process_count=%s\n' "$whoop_process_count" | tee -a "$summary"
      if grep -q '/Whoop\.app/Whoop' "$evidence_dir/process-check.txt"; then
        printf 'official_whoop_main_process=1\n' | tee -a "$summary"
      else
        printf 'official_whoop_main_process=0\n' | tee -a "$summary"
      fi
      if grep -Eq "$whoop_widget_pattern" "$evidence_dir/process-check.txt"; then
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
    printf 'process_name_status=not_atria\n' | tee -a "$summary"
    printf 'atria_main_process=0\n' | tee -a "$summary"
    printf 'atria_widget_process=0\n' | tee -a "$summary"
    printf 'official_whoop_process_status=not_listed\n' | tee -a "$summary"
    printf 'official_whoop_process_count=0\n' | tee -a "$summary"
    printf 'official_whoop_main_process=0\n' | tee -a "$summary"
    printf 'official_whoop_widget_process=0\n' | tee -a "$summary"
    printf 'official_whoop_coexistence_risk=0\n' | tee -a "$summary"
  fi
else
  printf 'process_status=unknown\n' | tee -a "$summary"
  printf 'process_name_status=unknown\n' | tee -a "$summary"
  printf 'atria_main_process=unknown\n' | tee -a "$summary"
  printf 'atria_widget_process=unknown\n' | tee -a "$summary"
  printf 'official_whoop_process_status=unknown\n' | tee -a "$summary"
fi

copy_from_container "Documents/atria-installed-app-provenance.json" \
  "$evidence_dir/installed-app-provenance.json" \
  "installed_app_provenance" || true
copy_from_container "Documents/sessions.json" "$evidence_dir/sessions.json" "sessions" || true
copy_from_container "Documents/sessions-cold.json" "$evidence_dir/sessions-cold.json" "sessions_cold" || true
copy_from_container "Documents/daily-rollups.json" "$evidence_dir/daily-rollups.json" "daily_rollups" || true
copy_from_container "Documents/daily-metrics.json" "$evidence_dir/daily-metrics.json" "daily_metrics" || true
copy_from_container "Documents/confirmed-workouts.json" "$evidence_dir/confirmed-workouts.json" "confirmed_workouts" || true

if "${devicectl_cmd[@]}" device copy from \
  --device "$device_id" \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id" \
  --source "Documents/atria-active-session.segments" \
  --destination "$evidence_dir/atria-active-session.segments" >> "$summary" 2>&1; then
  printf 'active_journal_segments_status=ok\n' | tee -a "$summary"
  printf 'active_journal_segments_source=Documents/atria-active-session.segments\n' | tee -a "$summary"
  printf 'active_journal_segments_dir=%s\n' "$evidence_dir/atria-active-session.segments" | tee -a "$summary"
  printf 'active_journal_storage_mode=segmented_canonical\n' | tee -a "$summary"
else
  if [[ -d "$evidence_dir/atria-active-session.segments" ]] && \
     find "$evidence_dir/atria-active-session.segments" -type f -print -quit | grep -q .; then
    : > "$evidence_dir/atria-active-session.segments.partial"
    printf 'active_journal_segments_status=partial_copy\n' | tee -a "$summary"
  else
    printf 'active_journal_segments_status=missing\n' | tee -a "$summary"
  fi
  printf 'active_journal_storage_mode=flat_snapshot_or_missing\n' | tee -a "$summary"
fi

if ! copy_first_from_container "$evidence_dir/atria-active-session.json" "active_journal_snapshot" \
  "Documents/atria-active-session.json" \
  "Documents/whoop-active-session.json"; then
  printf 'active_journal_file_status=missing_snapshot_segments_may_reconstruct\n' | tee -a "$summary"
fi

if (( runtime_only == 0 )); then
  copy_first_from_container "$evidence_dir/historical-archive.jsonl" "historical_archive" \
    "Documents/atria-historical/historical-archive.jsonl" \
    "Documents/whoop-historical/historical-archive.jsonl" || true
  copy_from_container "Documents/atria-historical/historical-archive.diagnostics.json" \
    "$evidence_dir/historical-archive.diagnostics.json" \
    "historical_archive_index" || true
  copy_from_container "Documents/atria-historical/historical-archive.identity.jsonl" \
    "$evidence_dir/historical-archive.identity.jsonl" \
    "historical_archive_identity_index" || true
  copy_from_container "Documents/atria-historical/historical-archive.manifest.json" \
    "$evidence_dir/historical-archive.manifest.json" \
    "historical_archive_manifest" || true
  copy_from_container "Documents/atria-historical/historical-archive.catalog-v2.json" \
    "$evidence_dir/historical-archive.catalog-v2.json" \
    "historical_archive_catalog" || true
  copy_from_container "Documents/atria-historical/historical-archive.identity.durability.json" \
    "$evidence_dir/historical-archive.identity.durability.json" \
    "historical_archive_identity_durability" || true
  copy_from_container "Documents/atria-historical/full-drain-authority-v1" \
    "$evidence_dir/historical-full-drain-authority-v1" \
    "historical_full_drain_authority" || true
  # The full-drain authority carries the selected ledger digest, but the
  # canonical ledger itself is the only evidence that binds that digest to the
  # exact UUID, bounds, generation, and per-second expected mask. Preserve it
  # in every full pull so an older pending gap cannot satisfy a newer controlled
  # recovery trial. This is a read-only container copy.
  copy_from_container "Library/Application Support/Atria/HistoricalRecovery" \
    "$evidence_dir/historical-gap-ledger-v2" \
    "historical_gap_ledger" || true
  copy_from_container "Documents/atria-historical/segments" \
    "$evidence_dir/historical-archive-segments" \
    "historical_archive_segments" || true
  deduplicate_archive_file "$evidence_dir/historical-archive.jsonl" \
    "historical_archive"
  deduplicate_archive_file "$evidence_dir/historical-archive.identity.jsonl" \
    "historical_archive_identity_index"
  if [[ -d "$evidence_dir/historical-archive-segments" ]]; then
    archive_segment_index=0
    while IFS= read -r -d '' archive_segment; do
      archive_segment_index=$((archive_segment_index + 1))
      deduplicate_archive_file "$archive_segment" \
        "historical_archive_segment_${archive_segment_index}"
    done < <(find -s "$evidence_dir/historical-archive-segments" \
      -type f -name '*.jsonl' -print0)
  fi
  copy_from_container "Documents/atria-captures" \
    "$evidence_dir/atria-captures" \
    "explicit_sensor_captures" || true
  if [[ -d "$evidence_dir/atria-captures" ]]; then
    capture_manifest="$evidence_dir/atria-captures.sha256"
    find -s "$evidence_dir/atria-captures" -type f -exec shasum -a 256 {} \; > "$capture_manifest"
    capture_file_count=$(wc -l < "$capture_manifest" | tr -d ' ')
    capture_total_bytes=$(find -s "$evidence_dir/atria-captures" -type f -exec stat -f '%z' {} \; \
      | awk '{ total += $1 } END { print total + 0 }')
    printf 'explicit_sensor_captures_file_count=%s\n' "$capture_file_count" | tee -a "$summary"
    printf 'explicit_sensor_captures_total_bytes=%s\n' "$capture_total_bytes" | tee -a "$summary"
    printf 'explicit_sensor_captures_manifest=%s\n' "$capture_manifest" | tee -a "$summary"
  fi
  copy_from_container "Documents/atria-step-calibration" \
    "$evidence_dir/atria-step-calibration" \
    "step_calibration_archive" || true
else
  printf 'pull_profile=runtime_only\n' | tee -a "$summary"
  printf 'historical_archive_status=skipped_runtime_only\n' | tee -a "$summary"
  printf 'historical_archive_identity_index_status=skipped_runtime_only\n' | tee -a "$summary"
  printf 'historical_archive_manifest_status=skipped_runtime_only\n' | tee -a "$summary"
  printf 'historical_archive_segments_status=skipped_runtime_only\n' | tee -a "$summary"
  printf 'explicit_sensor_captures_status=skipped_runtime_only\n' | tee -a "$summary"
  printf 'step_calibration_archive_status=skipped_runtime_only\n' | tee -a "$summary"
fi
copy_from_container "Library/Preferences/${bundle_id}.plist" "$evidence_dir/preferences.plist" "preferences" || true
app_group_id="group.${bundle_id}"
copy_from_group_container "Library/Preferences/${app_group_id}.plist" \
  "$evidence_dir/app-group-preferences.plist" \
  "app_group_preferences" \
  "$app_group_id" || true

if [[ -f "$evidence_dir/installed-app-provenance.json" && -f "$installed_metadata" ]]; then
  if (( installed_provenance_only == 1 )); then
    python3 "$(dirname "$0")/tools/app_build_provenance.py" verify \
      --identity "$evidence_dir/installed-app-provenance.json" \
      --installed-metadata "$installed_metadata" \
      --source-root "$(dirname "$0")" \
      --installed-only 2>&1 | tee -a "$summary" || true
  else
    python3 "$(dirname "$0")/tools/app_build_provenance.py" verify \
      --identity "$evidence_dir/installed-app-provenance.json" \
      --installed-metadata "$installed_metadata" \
      --source-root "$(dirname "$0")" 2>&1 | tee -a "$summary" || true
  fi
else
  printf 'app_provenance_status=fail\n' | tee -a "$summary"
  printf 'app_provenance_blockers=missing_provenance_or_installed_metadata\n' | tee -a "$summary"
fi

runtime_state_dir="$evidence_dir/authoritative-runtime-state"
mkdir -p "$runtime_state_dir"
copy_from_container "Library/Application Support/Atria/pending-workout-intent-v1.json" \
  "$runtime_state_dir/pending-workout-intent-v1.json" \
  "pending_workout_intent" || true
copy_from_container "Library/Application Support/Atria/active-workout-route.json" \
  "$runtime_state_dir/active-workout-route.json" \
  "active_workout_route" || true
copy_from_container "Library/Application Support/Atria/active-workout-route.points.ndjson" \
  "$runtime_state_dir/active-workout-route.points.ndjson" \
  "active_workout_route_points" || true
copy_from_container "Library/Application Support/Atria/pending-workout-route-transaction.json" \
  "$runtime_state_dir/pending-workout-route-transaction.json" \
  "pending_workout_route_transaction" || true
copy_from_container "Library/Application Support/atria-strap-step-ledger.json" \
  "$runtime_state_dir/atria-strap-step-ledger.json" \
  "strap_step_ledger" || true
copy_from_container "Library/Application Support/Atria/verified-step-evidence-v1/whoop4-motion-tick-days-v1.json" \
  "$runtime_state_dir/whoop4-motion-tick-days-v1.json" \
  "whoop4_motion_tick_days" || true
copy_from_container "Documents/atria-workout-routes" \
  "$runtime_state_dir/atria-workout-routes" \
  "workout_routes" || true

runtime_state_manifest="$evidence_dir/authoritative-runtime-state.sha256"
if find "$runtime_state_dir" -type f -print -quit | grep -q .; then
  find -s "$runtime_state_dir" -type f -exec shasum -a 256 {} \; > "$runtime_state_manifest"
  runtime_state_file_count=$(wc -l < "$runtime_state_manifest" | tr -d ' ')
  runtime_state_total_bytes=$(find -s "$runtime_state_dir" -type f -exec stat -f '%z' {} \; \
    | awk '{ total += $1 } END { print total + 0 }')
  printf 'authoritative_runtime_state_status=ok\n' | tee -a "$summary"
  printf 'authoritative_runtime_state_file_count=%s\n' "$runtime_state_file_count" | tee -a "$summary"
  printf 'authoritative_runtime_state_total_bytes=%s\n' "$runtime_state_total_bytes" | tee -a "$summary"
  printf 'authoritative_runtime_state_manifest=%s\n' "$runtime_state_manifest" | tee -a "$summary"
else
  rmdir "$runtime_state_dir" 2>/dev/null || true
  printf 'authoritative_runtime_state_status=missing\n' | tee -a "$summary"
  printf 'authoritative_runtime_state_file_count=0\n' | tee -a "$summary"
  printf 'authoritative_runtime_state_total_bytes=0\n' | tee -a "$summary"
fi
if [[ -f "$(dirname "$0")/tools/validate_runtime_evidence.py" ]]; then
  python3 "$(dirname "$0")/tools/validate_runtime_evidence.py" "$runtime_state_dir" \
    | tee -a "$summary" || true
else
  printf 'runtime_evidence_validation_status=validator_unavailable\n' | tee -a "$summary"
fi

python3 - "$evidence_dir" \
  "$(dirname "$0")/Atria/Atria/HistoricalArchive.swift" \
  "$(dirname "$0")/Atria/Atria/AtriaStrapCalibrationArchive.swift" \
  "$(dirname "$0")/tools/summarize_step_calibration_preflight.py" \
  "$bundle_id" <<'PY' | tee -a "$summary"
import csv
import datetime as dt
import hashlib
import importlib.util
import json
import math
import plistlib
import re
import struct
import sys
import time
from pathlib import Path

evidence = Path(sys.argv[1])
historical_archive_source = Path(sys.argv[2])
strap_calibration_archive_source = Path(sys.argv[3])
step_preflight_source = Path(sys.argv[4])
bundle_id = sys.argv[5]
try:
    step_preflight_spec = importlib.util.spec_from_file_location(
        "summarize_step_calibration_preflight", step_preflight_source
    )
    if step_preflight_spec is None or step_preflight_spec.loader is None:
        raise ImportError("missing preflight module loader")
    step_preflight = importlib.util.module_from_spec(step_preflight_spec)
    step_preflight_spec.loader.exec_module(step_preflight)
except Exception:
    step_preflight = None
apple_epoch = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
ist = dt.timezone(dt.timedelta(hours=5, minutes=30), "IST")

def emit_historical_archive_index_summary():
    path = evidence / "historical-archive.diagnostics.json"
    if not path.exists():
        print("historical_archive_index_summary_status=missing")
        return
    try:
        index = json.loads(path.read_text())
    except Exception as exc:
        print(f"historical_archive_index_summary_status=error:{type(exc).__name__}:{exc}")
        return
    print("historical_archive_index_summary_status=ok")
    print(f"historical_archive_index_rows={int(index.get('rows') or 0)}")
    print(f"historical_archive_index_file_size={int(index.get('fileSize') or 0)}")
    print(f"historical_archive_index_metric_usable_rows={int(index.get('metricUsableRows') or 0)}")
    print(f"historical_archive_index_current_session_usable_rows={int(index.get('currentSessionUsableRows') or 0)}")
    print(f"historical_archive_index_gravity_validated_rows={int(index.get('gravityValidatedRows') or 0)}")

def emit_historical_archive_identity_summary():
    path = evidence / "historical-archive.identity.jsonl"
    if not path.exists():
        print("historical_archive_identity_summary_status=missing")
        print("historical_archive_identity_entries=0")
        print("historical_archive_identity_unique_keys=0")
        print("historical_archive_identity_duplicate_keys=0")
        print("historical_archive_identity_parse_errors=0")
        return
    entries = 0
    parse_errors = 0
    keys = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except Exception:
                parse_errors += 1
                continue
            key = row.get("key") if isinstance(row, dict) else None
            if not isinstance(key, str) or not key:
                parse_errors += 1
                continue
            entries += 1
            keys.append(key)
    unique_keys = len(set(keys))
    print(f"historical_archive_identity_summary_status={'ok' if parse_errors == 0 else 'error'}")
    print(f"historical_archive_identity_entries={entries}")
    print(f"historical_archive_identity_unique_keys={unique_keys}")
    print(f"historical_archive_identity_duplicate_keys={entries - unique_keys}")
    print(f"historical_archive_identity_parse_errors={parse_errors}")

def emit_historical_archive_rotation_summary():
    manifest_path = evidence / "historical-archive.manifest.json"
    segments_path = evidence / "historical-archive-segments"
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text())
            print("historical_archive_manifest_summary_status=ok")
            print(f"historical_archive_active_segment={manifest.get('activeSegmentRelativePath') or 'missing'}")
            print(f"historical_archive_rotation_threshold_bytes={int(manifest.get('rotationThresholdBytes') or 0)}")
        except Exception as exc:
            print(f"historical_archive_manifest_summary_status=error:{type(exc).__name__}:{exc}")
    else:
        print("historical_archive_manifest_summary_status=missing")

    segment_files = sorted(segments_path.glob("*.jsonl")) if segments_path.exists() else []
    print(f"historical_archive_segment_files={len(segment_files)}")
    total_bytes = 0
    total_rows = 0
    active_rows = 0
    for path in segment_files:
        try:
            total_bytes += path.stat().st_size
            rows = sum(1 for line in path.open("r", encoding="utf-8", errors="replace") if line.strip())
            total_rows += rows
            if manifest_path.exists() and str(path.name) in (manifest_path.read_text(errors="replace")):
                active_rows = rows
        except Exception:
            continue
    print(f"historical_archive_segment_bytes={total_bytes}")
    print(f"historical_archive_segment_rows={total_rows}")
    print(f"historical_archive_active_segment_rows={active_rows}")
    base_index_rows = 0
    index_path = evidence / "historical-archive.diagnostics.json"
    if index_path.exists():
        try:
            base_index_rows = int(json.loads(index_path.read_text()).get("rows") or 0)
        except Exception:
            base_index_rows = 0
    print(f"historical_archive_aggregate_index_rows={base_index_rows + total_rows}")

def emit_step_calibration_archive_summary():
    archive_path = evidence / "atria-step-calibration"
    csv_paths = sorted(
        path for path in archive_path.rglob("*")
        if path.is_file() and path.suffix.lower() == ".csv"
    ) if archive_path.is_dir() else []
    if not csv_paths:
        print("step_calibration_archive_summary_status=missing")
        print("step_calibration_archive_file_count=0")
        print("step_calibration_archive_row_count=0")
        print("step_calibration_archive_earliest_received_at_iso_utc=missing")
        print("step_calibration_archive_latest_received_at_iso_utc=missing")
        print("step_calibration_archive_total_bytes=0")
        print("step_calibration_archive_packet_types=missing")
        print("step_calibration_archive_record_types=missing")
        emit_step_calibration_retention_forecast([], 0, 0, 0)
        return

    total_bytes = 0
    total_rows = 0
    earliest_received_at = None
    latest_received_at = None
    read_errors = 0
    invalid_timestamp_rows = 0
    retention_observations = []
    packet_type_counts = {}
    record_type_counts = {}

    class ByteCountingIterator:
        def __init__(self, handle):
            self.handle = handle
            self.bytes_read = 0

        def __iter__(self):
            return self

        def __next__(self):
            line = next(self.handle)
            self.bytes_read += len(line.encode("utf-8"))
            return line

    for path in csv_paths:
        try:
            total_bytes += path.stat().st_size
            with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
                header_line = handle.readline()
                fieldnames = next(csv.reader([header_line]), [])
                counting_lines = ByteCountingIterator(handle)
                reader = csv.DictReader(counting_lines, fieldnames=fieldnames)
                while True:
                    bytes_before_row = counting_lines.bytes_read
                    try:
                        row = next(reader)
                    except StopIteration:
                        break
                    row_bytes = counting_lines.bytes_read - bytes_before_row
                    total_rows += 1
                    packet_type = (row.get("packet_type") or "legacy").strip().lower()
                    record_type = (row.get("record_type") or "legacy").strip().lower()
                    packet_type_counts[packet_type] = packet_type_counts.get(packet_type, 0) + 1
                    record_type_counts[record_type] = record_type_counts.get(record_type, 0) + 1
                    raw_received_at = row.get("received_at_unix_ms")
                    try:
                        unix_ms = float(raw_received_at)
                        if not math.isfinite(unix_ms):
                            raise ValueError("non-finite timestamp")
                        received_at = dt.datetime.fromtimestamp(unix_ms / 1_000, tz=dt.timezone.utc)
                    except (TypeError, ValueError, OverflowError, OSError):
                        invalid_timestamp_rows += 1
                        continue
                    retention_observations.append((unix_ms, row_bytes))
                    earliest_received_at = min(earliest_received_at, received_at) if earliest_received_at else received_at
                    latest_received_at = max(latest_received_at, received_at) if latest_received_at else received_at
        except (OSError, csv.Error):
            read_errors += 1

    def iso_utc(value):
        return value.isoformat(timespec="milliseconds").replace("+00:00", "Z") if value else "missing"

    print(f"step_calibration_archive_summary_status={'partial' if read_errors else 'ok'}")
    print(f"step_calibration_archive_file_count={len(csv_paths)}")
    print(f"step_calibration_archive_row_count={total_rows}")
    print(f"step_calibration_archive_earliest_received_at_iso_utc={iso_utc(earliest_received_at)}")
    print(f"step_calibration_archive_latest_received_at_iso_utc={iso_utc(latest_received_at)}")
    print(f"step_calibration_archive_total_bytes={total_bytes}")
    print("step_calibration_archive_packet_types=" + ",".join(
        f"{key}:{packet_type_counts[key]}" for key in sorted(packet_type_counts)
    ))
    print("step_calibration_archive_record_types=" + ",".join(
        f"{key}:{record_type_counts[key]}" for key in sorted(record_type_counts)
    ))
    emit_step_calibration_retention_forecast(
        retention_observations,
        total_bytes,
        read_errors,
        invalid_timestamp_rows,
    )

def emit_step_calibration_retention_forecast(observations, total_bytes, read_errors, invalid_timestamp_rows):
    if step_preflight is None:
        forecast = {
            "step_calibration_archive_retention_capacity_status": "unknown",
            "step_calibration_archive_retention_capacity_bytes": "-1",
            "step_calibration_archive_retention_maximum_file_bytes": "-1",
            "step_calibration_archive_retention_total_bytes": str(total_bytes),
            "step_calibration_archive_retention_capacity_used_percent": "-1.000",
            "step_calibration_archive_retention_recent_window_hours": "0.000",
            "step_calibration_archive_retention_recent_rows": "0",
            "step_calibration_archive_retention_recent_bytes": "0",
            "step_calibration_archive_recent_ingress_bytes_per_hour": "-1.000",
            "step_calibration_archive_recent_ingress_basis": "peak_rolling_1h_within_latest_6h",
            "step_calibration_archive_estimated_retained_hours": "-1.000",
            "step_calibration_archive_required_delayed_pull_hours": "2.000",
            "step_calibration_archive_retention_forecast_status": "insufficient_evidence",
            "step_calibration_archive_retention_evidence_reason": "preflight_tool_unavailable",
            "step_calibration_archive_retention_risk": "retention_cannot_be_proven",
            "step_calibration_archive_retention_action": "pull_now_and_restore_preflight_tool",
        }
    else:
        try:
            archive_source = strap_calibration_archive_source.read_text(encoding="utf-8")
        except OSError:
            archive_source = ""
        forecast = step_preflight.retention_forecast(
            observations,
            total_archive_bytes=total_bytes,
            archive_source=archive_source,
            read_errors=read_errors,
            invalid_timestamp_rows=invalid_timestamp_rows,
        )
    for key, value in forecast.items():
        print(f"{key}={value}")

def emit_step_calibration_capture_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        print("step_calibration_capture_status=missing_preferences")
        print("step_calibration_capture_armed=0")
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"step_calibration_capture_status=error:{type(exc).__name__}:{exc}")
        print("step_calibration_capture_armed=0")
        return
    raw_until = pref(prefs, "strapStepCalibration.captureUntil")
    now = time.time()
    if not isinstance(raw_until, (int, float)) or not math.isfinite(float(raw_until)):
        print("step_calibration_capture_status=missing")
        print("step_calibration_capture_armed=0")
        print("step_calibration_capture_until_unix_s=-1")
        print("step_calibration_capture_remaining_s=-1")
        return
    capture_until = float(raw_until)
    remaining = capture_until - now
    capture_date = dt.datetime.fromtimestamp(capture_until, tz=dt.timezone.utc)
    print("step_calibration_capture_status=armed" if remaining > 0 else "step_calibration_capture_status=expired")
    print(f"step_calibration_capture_namespace={pref_namespace(prefs, 'strapStepCalibration.captureUntil')}")
    print(f"step_calibration_capture_armed={bool_int(remaining > 0)}")
    print(f"step_calibration_capture_until_unix_s={capture_until:.3f}")
    print("step_calibration_capture_until_iso_utc=" + capture_date.isoformat(timespec="milliseconds").replace("+00:00", "Z"))
    print(f"step_calibration_capture_remaining_s={max(0.0, remaining):.1f}")

def emit_step_calibration_sequence_preferences():
    unknown = {
        "step_calibration_sequence_state": "unknown_preferences",
        "step_calibration_sequence_completed_window_count": "-1",
        "step_calibration_sequence_total_window_count": "6",
        "step_calibration_sequence_active": "0",
        "step_calibration_sequence_finishing": "0",
        "step_calibration_sequence_complete": "0",
        "step_calibration_sequence_state_source": "preferences_unavailable",
        "step_calibration_sequence_ui_visibility_proven": "0",
        "step_calibration_sequence_interpretation": "preferences_state_only_not_ui_visibility",
    }
    prefs_path = evidence / "preferences.plist"
    raw_state = None
    if not prefs_path.exists() or step_preflight is None:
        summary = unknown
    else:
        try:
            with prefs_path.open("rb") as handle:
                prefs = plistlib.load(handle)
            raw_state = prefs.get("atria.stepCalibration.sequence.v1")
            summary = step_preflight.sequence_summary(raw_state)
        except Exception:
            summary = unknown
    for key, value in summary.items():
        print(f"{key}={value}")

    manifest_path = evidence / "step-calibration-manifest.json"
    manifest_path.unlink(missing_ok=True)
    state = summary.get("step_calibration_sequence_state")
    if state == "complete" and step_preflight is not None:
        try:
            manifest = step_preflight.completed_sequence_manifest(raw_state)
            payload = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
            manifest_path.write_bytes(payload)
            print("step_calibration_manifest_status=ok")
            print("step_calibration_manifest_source=Library/Preferences/"
                  f"{bundle_id}.plist#atria.stepCalibration.sequence.v1")
            print(f"step_calibration_manifest_file={manifest_path}")
            print(f"step_calibration_manifest_sha256={hashlib.sha256(payload).hexdigest()}")
            print(f"step_calibration_manifest_window_count={len(manifest['windows'])}")
        except Exception:
            print("step_calibration_manifest_status=corrupt")
            print("step_calibration_manifest_window_count=-1")
    elif state == "corrupt":
        print("step_calibration_manifest_status=corrupt")
        print("step_calibration_manifest_window_count=-1")
    elif state in {"not_started", "ready", "active", "finishing"}:
        print("step_calibration_manifest_status=not_complete")
        print("step_calibration_manifest_window_count=0")
    else:
        print("step_calibration_manifest_status=unavailable")
        print("step_calibration_manifest_window_count=-1")

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

def pref(prefs, suffix, default=None):
    for namespace in ("atria", "whoop"):
        key = f"{namespace}.{suffix}"
        if key in prefs:
            return prefs.get(key)
    return default

def pref_namespace(prefs, suffix):
    for namespace in ("atria", "whoop"):
        if f"{namespace}.{suffix}" in prefs:
            return namespace
    return "missing"

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
    requested_at = pref(prefs, "offlineSync.rangeLossBackfillRequestedAt")
    started_at = pref(prefs, "offlineSync.rangeLossBackfillStartedAt")
    raw_archived_at = pref(prefs, "offlineSync.rawArchivedGapAt.v1")
    requested_age = max(0.0, now - float(requested_at)) if isinstance(requested_at, (int, float)) and requested_at > 0 else -1.0
    started_age = max(0.0, now - float(started_at)) if isinstance(started_at, (int, float)) and started_at > 0 else -1.0
    raw_archived_age = max(0.0, now - float(raw_archived_at)) if isinstance(raw_archived_at, (int, float)) and raw_archived_at > 0 else -1.0
    print(f"offline_sync_namespace={pref_namespace(prefs, 'offlineSync.lastStatus')}")
    print(f"offline_sync_enabled={bool_int(pref(prefs, 'offlineSync.enabled'))}")
    print(f"offline_sync_attempts={int(pref(prefs, 'offlineSync.attempts', 0) or 0)}")
    print(f"offline_sync_last_status={pref(prefs, 'offlineSync.lastStatus', 'none') or 'none'}")
    print(f"offline_sync_last_reason={pref(prefs, 'offlineSync.lastReason', 'none') or 'none'}")
    print(f"offline_range_loss_backfill_pending={bool_int(pref(prefs, 'offlineSync.rangeLossBackfillPending'))}")
    print(f"offline_range_loss_backfill_reason={pref(prefs, 'offlineSync.rangeLossBackfillReason', 'none') or 'none'}")
    print(f"offline_range_loss_backfill_requested_age_s={requested_age:.1f}")
    print(f"offline_range_loss_backfill_started_age_s={started_age:.1f}")
    print(f"offline_raw_gap_archived={bool_int(pref(prefs, 'offlineSync.rawArchivedGapFingerprint.v1'))}")
    print(f"offline_raw_gap_archived_age_s={raw_archived_age:.1f}")
    radio_standard_only = bool(pref(prefs, "radio.standardHROnly", False))
    radio_user_selected = bool(pref(prefs, "radio.standardHROnlyUserSelected", False))
    step_full_protocol_migrated = bool(pref(prefs, "capture.strapStepFullProtocolMigrated", False))
    passive_r10_status = str(pref(prefs, "radio.passiveR10Status", "none") or "none")
    clean_owner = str(pref(prefs, "protectedR10.cleanOwner", "legacy") or "legacy")
    clean_owner_state = str(pref(prefs, "protectedR10.cleanOwnerState", "none") or "none")
    clean_owner_failure = str(pref(prefs, "protectedR10.cleanOwnerFailureReason", "none") or "none")
    passive_r10_last_valid_at = pref(prefs, "radio.passiveR10LastValidAt")
    passive_r10_age = (
        now - float(passive_r10_last_valid_at)
        if isinstance(passive_r10_last_valid_at, (int, float)) and passive_r10_last_valid_at > 0
        else -1.0
    )
    passive_r10_is_fresh = 0.0 <= passive_r10_age <= 15.0
    protected_r10_active = (
        radio_standard_only
        and not radio_user_selected
        and passive_r10_status in ("receiving_crc_valid", "receiving_crc_valid_passive")
        and passive_r10_is_fresh
    )
    # `standardHROnly` is a legacy key name. Production-safe mode now keeps
    # 2A37 HR plus the isolated stream-5 R10 motion subscription, so a true key
    # is not itself evidence that strap steps need migration repair.
    legacy_radio_repair_needed = (
        radio_standard_only
        and not radio_user_selected
        and not step_full_protocol_migrated
        and not protected_r10_active
    )
    recorded_runtime_mode = pref(prefs, "radio.mode", "none") or "none"
    if protected_r10_active:
        effective_radio_mode = "protected_hr_plus_r10"
    elif recorded_runtime_mode in ("full_protocol", "standard_hr_only"):
        effective_radio_mode = recorded_runtime_mode
    else:
        effective_radio_mode = "standard_hr_only" if radio_standard_only else "full_protocol"
    print(f"radio_namespace={pref_namespace(prefs, 'radio.standardHROnly')}")
    print(f"radio_standard_hr_only={bool_int(radio_standard_only)}")
    print(f"radio_standard_hr_only_user_selected={bool_int(radio_user_selected)}")
    print(f"radio_step_full_protocol_migrated={bool_int(step_full_protocol_migrated)}")
    print(f"radio_legacy_automatic_repair_needed={bool_int(legacy_radio_repair_needed)}")
    print(f"radio_recorded_runtime_mode={recorded_runtime_mode}")
    print(f"radio_effective_mode={effective_radio_mode}")
    print(f"radio_protected_r10_active={bool_int(protected_r10_active)}")
    print(f"radio_passive_r10_status={passive_r10_status}")
    print(f"radio_passive_r10_age_s={passive_r10_age:.1f}")
    print(f"radio_clean_owner={clean_owner}")
    print(f"radio_clean_owner_state={clean_owner_state}")
    print(f"radio_clean_owner_failure={clean_owner_failure}")
    print(f"protocol_packets={int(pref(prefs, 'protocol.packets', 0) or 0)}")
    print(f"protocol_imu_frames={int(pref(prefs, 'protocol.imuFrames', 0) or 0)}")
    print(f"protocol_last_packet_type={pref(prefs, 'protocol.lastPacketType', 'none') or 'none'}")
    print(f"protocol_last_packet_kind={pref(prefs, 'protocol.lastPacketKind', 'none') or 'none'}")
    print(f"step_source=strap_r10_imu")
    print("phone_step_fallback=0")
    print(f"link_namespace={pref_namespace(prefs, 'link.lastAutoSaveStatus')}")
    link_auto_save_status = pref(prefs, "link.lastAutoSaveStatus", "none") or "none"
    link_auto_save_samples = int(pref(prefs, "link.lastAutoSaveSamples", 0) or 0)
    link_auto_save_duration = int(pref(prefs, "link.lastAutoSaveDuration", 0) or 0)
    if link_auto_save_status == "saved":
        link_auto_save_interpretation = "saved_session"
    elif link_auto_save_status == "checkpointed_continuity":
        link_auto_save_interpretation = "active_journal_checkpoint_not_saved_session"
    elif link_auto_save_status.startswith("skipped"):
        link_auto_save_interpretation = "no_session_saved"
    else:
        link_auto_save_interpretation = "unknown"
    print(f"link_last_auto_save_status={link_auto_save_status}")
    print(f"link_last_auto_save_samples={link_auto_save_samples}")
    print(f"link_last_auto_save_duration_s={link_auto_save_duration}")
    print(f"link_last_auto_save_interpretation={link_auto_save_interpretation}")

def emit_battery_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"battery_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    level = pref(prefs, "battery.level", -1)
    source = pref(prefs, "battery.source", "none") or "none"
    at = pref(prefs, "battery.at")
    age = max(0.0, now - float(at)) if isinstance(at, (int, float)) and at > 0 else -1.0
    charge_status = pref(prefs, "battery.chargeStatus", "levelOnly") or "levelOnly"
    charge_at = pref(prefs, "battery.chargeAt")
    charge_age = max(0.0, now - float(charge_at)) if isinstance(charge_at, (int, float)) and charge_at > 0 else -1.0
    drop_delta = int(pref(prefs, "battery.dropDelta", 0) or 0)
    drop_at = pref(prefs, "battery.dropAt")
    drop_age = max(0.0, now - float(drop_at)) if isinstance(drop_at, (int, float)) and drop_at > 0 else -1.0
    # Match the app's fail-closed presentation contract. The raw level packet
    # is fresh for ten minutes. Beyond that, a mid-range value remains usable
    # only while this running connection is actively renewing its proven 2A19
    # notification lease; the lease never rescues restoration sentinels.
    requires_fresh = bool(pref(prefs, "battery.requiresFreshConfirmation", False))
    lease_at = pref(prefs, "battery.notificationLeaseAt")
    lease_age = max(0.0, now - float(lease_at)) if isinstance(lease_at, (int, float)) and lease_at > 0 else -1.0
    confirmed_at = pref(prefs, "battery.notificationConfirmedAt")
    confirmed_age = max(0.0, now - float(confirmed_at)) if isinstance(confirmed_at, (int, float)) and confirmed_at > 0 else -1.0
    raw_fresh = isinstance(level, int) and 11 <= level <= 99 and 0 <= age <= 10 * 60
    active_notification_lease = (
        isinstance(level, int)
        and 11 <= level <= 99
        and source in ("live_2A19", "live_battery_event")
        and not requires_fresh
        and 0 <= lease_age <= 10 * 60
        and 0 <= confirmed_age <= 60 * 60
    )
    usable = raw_fresh or active_notification_lease
    projection_basis = "fresh_level_packet" if raw_fresh else (
        "active_notification_lease" if active_notification_lease else "none"
    )
    recent_drop = drop_delta > 0 and 0 <= drop_age <= 6 * 60 * 60
    charging = charge_status in ("charging", "full")
    print(f"battery_namespace={pref_namespace(prefs, 'battery.level')}")
    print(f"battery_level={int(level) if isinstance(level, int) else -1}")
    print(f"battery_source={source}")
    print(f"battery_age_s={age:.1f}")
    print(f"battery_charge_status={charge_status}")
    print(f"battery_charge_age_s={charge_age:.1f}")
    print(f"battery_is_charging={bool_int(charging)}")
    print(f"battery_usable={bool_int(usable)}")
    print(f"battery_projection_basis={projection_basis}")
    print(f"battery_notification_lease_age_s={lease_age:.1f}")
    print(f"battery_effective_level={int(level) if usable else -1}")
    print(f"battery_effective_status={'live' if usable else 'pending'}")
    print(f"battery_drop_recent={bool_int(recent_drop)}")
    print(f"battery_drop_delta={drop_delta}")
    print(f"battery_drop_age_s={drop_age:.1f}")

def emit_motion_context_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        print("motion_context_summary_status=missing_preferences")
        print("motion_context_effective_gate_decision=abstain")
        print("motion_context_effective_gate_reason=missing_preferences")
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"motion_context_summary_status=error:{type(exc).__name__}:{exc}")
        return

    payload = pref(prefs, "motionContext.diagnostics")
    if not isinstance(payload, dict):
        print("motion_context_summary_status=missing")
        print("motion_context_effective_gate_decision=abstain")
        print("motion_context_effective_gate_reason=no_snapshot")
        return

    now = time.time()
    def age(key):
        value = payload.get(key)
        if not isinstance(value, (int, float)) or not math.isfinite(float(value)) or value <= 0:
            return -1.0
        return max(0.0, now - float(value))

    authorization = str(payload.get("authorization") or "missing")
    monitor_state = str(payload.get("monitorState") or "missing")
    kind = str(payload.get("kind") or "missing")
    confidence = str(payload.get("confidence") or "missing")
    recorded_decision = str(payload.get("decision") or "missing")
    observed_value = payload.get("observedAt")
    observed_age = age("observedAt")
    observed_future_skew = (
        float(observed_value) - now
        if isinstance(observed_value, (int, float)) and math.isfinite(float(observed_value))
        else -1.0
    )
    evidence_fresh = (
        authorization == "authorized"
        and monitor_state == "running"
        and observed_age >= 0
        and observed_age <= 45
        and observed_future_skew <= 5
    )
    if evidence_fresh:
        effective_decision = recorded_decision
        stale_reason = "none"
    else:
        effective_decision = "abstain"
        if authorization != "authorized": stale_reason = "authorization"
        elif monitor_state != "running": stale_reason = "monitor_not_running"
        elif observed_age < 0: stale_reason = "observation_missing_or_future"
        else: stale_reason = "observation_stale"

    print("motion_context_summary_status=ok")
    print(f"motion_context_namespace={pref_namespace(prefs, 'motionContext.diagnostics')}")
    print(f"motion_context_schema_version={int(payload.get('schemaVersion') or 0)}")
    print(f"motion_context_authorization={authorization}")
    print(f"motion_context_monitor_state={monitor_state}")
    print(f"motion_context_latest_kind={kind}")
    print(f"motion_context_latest_confidence={confidence}")
    print(f"motion_context_started_age_s={age('startedAt'):.1f}")
    print(f"motion_context_observed_age_s={observed_age:.1f}")
    print(f"motion_context_evidence_fresh={bool_int(evidence_fresh)}")
    print(f"motion_context_recorded_gate_decision={recorded_decision}")
    print(f"motion_context_effective_gate_decision={effective_decision}")
    print(f"motion_context_effective_gate_reason={stale_reason}")
    print(f"motion_context_decision_age_s={age('decisionAt'):.1f}")
    print(f"motion_context_persisted_age_s={age('persistedAt'):.1f}")

def emit_hr_broadcast_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"hr_broadcast_summary_error={type(exc).__name__}:{exc}")
        return
    print(f"hr_broadcast_debug_status={pref(prefs, 'debug.hrBroadcast.status', 'missing') or 'missing'}")
    print(f"hr_broadcast_debug_sent_count={int(pref(prefs, 'debug.hrBroadcast.sentCount', 0) or 0)}")
    print(f"hr_broadcast_debug_last_bpm={int(pref(prefs, 'debug.hrBroadcast.lastBPM', 0) or 0)}")
    print(f"hr_broadcast_debug_reason={pref(prefs, 'debug.hrBroadcast.reason', 'missing') or 'missing'}")
    print("hr_broadcast_debug_interpretation=phone_ble_peripheral_broadcast_not_strap_connection")

def emit_ble_link_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"ble_link_summary_error={type(exc).__name__}:{exc}")
        return
    print(f"ble_link_namespace={pref_namespace(prefs, 'link.lastStatus')}")
    print(f"ble_link_attempts={int(pref(prefs, 'link.attempts', 0) or 0)}")
    print(f"ble_link_disconnects={int(pref(prefs, 'link.disconnects', 0) or 0)}")
    print(f"ble_link_successes={int(pref(prefs, 'link.successes', 0) or 0)}")
    print(f"ble_link_failures={int(pref(prefs, 'link.failures', 0) or 0)}")
    print(f"ble_link_last_status={pref(prefs, 'link.lastStatus', 'missing') or 'missing'}")
    print(f"ble_link_last_reason={pref(prefs, 'link.lastReason', 'missing') or 'missing'}")
    print(f"ble_link_last_error={pref(prefs, 'link.lastError', 'missing') or 'missing'}")
    saved_uuid = pref(prefs, "link.savedPeripheralUUID", "missing") or "missing"
    print(f"ble_link_saved_peripheral_present={bool_int(saved_uuid != 'missing')}")
    print(f"ble_link_saved_peripheral_uuid={saved_uuid}")

def emit_duty_cycle_and_compaction_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"duty_cycle_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    last_run_at = pref(prefs, "archiveCompaction.lastRunAt")
    last_run_age = max(0.0, now - float(last_run_at)) if isinstance(last_run_at, (int, float)) and last_run_at > 0 else -1.0
    sleep_window_start = pref(prefs, "dutycycle.sleepWindowStartMin", -1)
    sleep_window_end = pref(prefs, "dutycycle.sleepWindowEndMin", -1)
    print(f"duty_cycle_enabled={bool_int(pref(prefs, 'dutycycle.enabled'))}")
    print(f"duty_cycle_sleep_window_start_min={int(sleep_window_start) if isinstance(sleep_window_start, (int, float)) else -1}")
    print(f"duty_cycle_sleep_window_end_min={int(sleep_window_end) if isinstance(sleep_window_end, (int, float)) else -1}")
    print(f"archive_compaction_last_run_at={last_run_at if isinstance(last_run_at, (int, float)) and last_run_at > 0 else 'none'}")
    print(f"archive_compaction_last_run_age_s={last_run_age:.1f}")

def emit_watchdog_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"watchdog_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    hr_at = pref(prefs, "hrContinuity.at")
    rr_at = pref(prefs, "rrPresence.at")
    watchdog_at = pref(prefs, "watchdog.lastAt")
    hr_age = max(0.0, now - float(hr_at)) if isinstance(hr_at, (int, float)) and hr_at > 0 else -1.0
    rr_age = max(0.0, now - float(rr_at)) if isinstance(rr_at, (int, float)) and rr_at > 0 else -1.0
    watchdog_age = max(0.0, now - float(watchdog_at)) if isinstance(watchdog_at, (int, float)) and watchdog_at > 0 else -1.0
    print(f"hr_continuity_status={pref(prefs, 'hrContinuity.status', 'missing') or 'missing'}")
    print(f"hr_continuity_action={pref(prefs, 'hrContinuity.action', 'missing') or 'missing'}")
    print(f"hr_continuity_raw_gap_s={float(pref(prefs, 'hrContinuity.rawGap', -1) or -1):.1f}")
    print(f"hr_continuity_accepted_gap_s={float(pref(prefs, 'hrContinuity.acceptedGap', -1) or -1):.1f}")
    print(f"hr_continuity_timeout_s={float(pref(prefs, 'hrContinuity.timeout', -1) or -1):.1f}")
    print(f"hr_continuity_samples={int(pref(prefs, 'hrContinuity.samples', 0) or 0)}")
    print(f"hr_continuity_notifying={pref(prefs, 'hrContinuity.notifying', 'missing')}")
    print(f"hr_continuity_age_s={hr_age:.1f}")
    print(f"rr_presence_status={pref(prefs, 'rrPresence.status', 'missing') or 'missing'}")
    print(f"rr_presence_action={pref(prefs, 'rrPresence.action', 'missing') or 'missing'}")
    print(f"rr_presence_rr_gap_s={float(pref(prefs, 'rrPresence.rrGap', -1) or -1):.1f}")
    print(f"rr_presence_accepted_gap_s={float(pref(prefs, 'rrPresence.acceptedGap', -1) or -1):.1f}")
    print(f"rr_presence_timeout_s={float(pref(prefs, 'rrPresence.timeout', -1) or -1):.1f}")
    print(f"rr_presence_samples={int(pref(prefs, 'rrPresence.samples', 0) or 0)}")
    print(f"rr_presence_rr_values={int(pref(prefs, 'rrPresence.rrValues', 0) or 0)}")
    print(f"rr_presence_consecutive={int(pref(prefs, 'rrPresence.consecutive', 0) or 0)}")
    print(f"rr_presence_age_s={rr_age:.1f}")
    print(f"watchdog_no_data_count={int(pref(prefs, 'watchdog.noDataCount', 0) or 0)}")
    print(f"watchdog_hr_continuity_count={int(pref(prefs, 'watchdog.hrContinuityCount', 0) or 0)}")
    print(f"watchdog_accepted_hr_count={int(pref(prefs, 'watchdog.acceptedHRCount', 0) or 0)}")
    print(f"watchdog_rr_presence_count={int(pref(prefs, 'watchdog.rrPresenceCount', 0) or 0)}")
    print(f"watchdog_last_status={pref(prefs, 'watchdog.lastStatus', 'missing') or 'missing'}")
    print(f"watchdog_last_source={pref(prefs, 'watchdog.lastSource', 'missing') or 'missing'}")
    print(f"watchdog_last_action={pref(prefs, 'watchdog.lastAction', 'missing') or 'missing'}")
    print(f"watchdog_last_raw_gap_s={float(pref(prefs, 'watchdog.lastRawGap', -1) or -1):.1f}")
    print(f"watchdog_last_accepted_gap_s={float(pref(prefs, 'watchdog.lastAcceptedGap', -1) or -1):.1f}")
    print(f"watchdog_last_samples={int(pref(prefs, 'watchdog.lastSamples', 0) or 0)}")
    print(f"watchdog_last_checkpoint={pref(prefs, 'watchdog.lastCheckpoint', 'missing') or 'missing'}")
    print(f"watchdog_last_age_s={watchdog_age:.1f}")

def emit_sample_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"sample_summary_error={type(exc).__name__}:{exc}")
        return
    print(f"sample_raw_notifications={int(pref(prefs, 'sample.rawNotifications', 0) or 0)}")
    print(f"sample_accepted_samples={int(pref(prefs, 'sample.acceptedSamples', 0) or 0)}")
    print(f"sample_zero_samples={int(pref(prefs, 'sample.zeroSamples', 0) or 0)}")
    print(f"sample_held_artifacts={int(pref(prefs, 'sample.heldArtifacts', 0) or 0)}")
    print(f"sample_dropped_artifacts={int(pref(prefs, 'sample.droppedArtifacts', 0) or 0)}")
    print(f"sample_raw_gaps={int(pref(prefs, 'sample.rawGaps', 0) or 0)}")
    print(f"sample_accepted_gaps={int(pref(prefs, 'sample.acceptedGaps', 0) or 0)}")
    print(f"sample_max_raw_gap_s={float(pref(prefs, 'sample.maxRawGap', 0) or 0):.1f}")
    print(f"sample_max_accepted_gap_s={float(pref(prefs, 'sample.maxAcceptedGap', 0) or 0):.1f}")
    print(f"sample_last_status={pref(prefs, 'sample.lastStatus', 'missing') or 'missing'}")
    print(f"sample_last_reason={pref(prefs, 'sample.lastReason', 'missing') or 'missing'}")
    last_raw_at = pref(prefs, "sample.lastRawNotificationAt")
    last_raw_age = max(0.0, time.time() - float(last_raw_at)) if isinstance(last_raw_at, (int, float)) and last_raw_at > 0 else -1.0
    print(f"sample_last_raw_notification_age_s={last_raw_age:.1f}")

def emit_keepalive_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"keepalive_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    armed_at = pref(prefs, "keepalive.armedAt")
    tick_started_at = pref(prefs, "keepalive.tickStartedAt")
    tick_at = pref(prefs, "keepalive.lastTickAt")
    timer_started_at = pref(prefs, "keepalive.timerStartedAt")
    timer_fired_at = pref(prefs, "keepalive.timerFiredAt")
    dispatch_timer_started_at = pref(prefs, "keepalive.dispatchTimerStartedAt")
    dispatch_timer_fired_at = pref(prefs, "keepalive.dispatchTimerFiredAt")
    sample_check_at = pref(prefs, "keepalive.lastSampleCheckAt")
    armed_age = max(0.0, now - float(armed_at)) if isinstance(armed_at, (int, float)) and armed_at > 0 else -1.0
    tick_started_age = max(0.0, now - float(tick_started_at)) if isinstance(tick_started_at, (int, float)) and tick_started_at > 0 else -1.0
    tick_age = max(0.0, now - float(tick_at)) if isinstance(tick_at, (int, float)) and tick_at > 0 else -1.0
    timer_started_age = max(0.0, now - float(timer_started_at)) if isinstance(timer_started_at, (int, float)) and timer_started_at > 0 else -1.0
    timer_fired_age = max(0.0, now - float(timer_fired_at)) if isinstance(timer_fired_at, (int, float)) and timer_fired_at > 0 else -1.0
    dispatch_timer_started_age = max(0.0, now - float(dispatch_timer_started_at)) if isinstance(dispatch_timer_started_at, (int, float)) and dispatch_timer_started_at > 0 else -1.0
    dispatch_timer_fired_age = max(0.0, now - float(dispatch_timer_fired_at)) if isinstance(dispatch_timer_fired_at, (int, float)) and dispatch_timer_fired_at > 0 else -1.0
    sample_check_age = max(0.0, now - float(sample_check_at)) if isinstance(sample_check_at, (int, float)) and sample_check_at > 0 else -1.0
    print(f"keepalive_namespace={pref_namespace(prefs, 'keepalive.lastStatus')}")
    print(f"keepalive_armed={bool_int(pref(prefs, 'keepalive.armed'))}")
    print(f"keepalive_last_status={pref(prefs, 'keepalive.lastStatus', 'missing') or 'missing'}")
    print(f"keepalive_last_reason={pref(prefs, 'keepalive.lastReason', 'missing') or 'missing'}")
    print(f"keepalive_last_action={pref(prefs, 'keepalive.lastAction', 'missing') or 'missing'}")
    print(f"keepalive_last_silence_s={float(pref(prefs, 'keepalive.lastSilence', -1) or -1):.1f}")
    print(f"keepalive_last_peripheral_state={int(pref(prefs, 'keepalive.lastPeripheralState', -1) or -1)}")
    print(f"keepalive_ticks={int(pref(prefs, 'keepalive.ticks', 0) or 0)}")
    print(f"keepalive_armed_age_s={armed_age:.1f}")
    print(f"keepalive_tick_started_age_s={tick_started_age:.1f}")
    print(f"keepalive_last_tick_age_s={tick_age:.1f}")
    print(f"keepalive_timer_started_age_s={timer_started_age:.1f}")
    print(f"keepalive_timer_fired_age_s={timer_fired_age:.1f}")
    print(f"keepalive_dispatch_timer_started_age_s={dispatch_timer_started_age:.1f}")
    print(f"keepalive_dispatch_timer_fired_age_s={dispatch_timer_fired_age:.1f}")
    print(f"keepalive_last_raw_notifications={int(pref(prefs, 'keepalive.lastRawNotifications', -1) or -1)}")
    print(f"keepalive_last_raw_notification_delta={int(pref(prefs, 'keepalive.lastRawNotificationDelta', -1) or -1)}")
    print(f"keepalive_last_sample_check_age_s={sample_check_age:.1f}")
    print(f"keepalive_stall_reconnects={int(pref(prefs, 'keepalive.stallReconnects', 0) or 0)}")
    stall_at = pref(prefs, "keepalive.lastStallReconnectAt")
    stall_age = max(0.0, now - float(stall_at)) if isinstance(stall_at, (int, float)) and stall_at > 0 else -1.0
    print(f"keepalive_last_stall_reconnect_age_s={stall_age:.1f}")
    read_poll_at = pref(prefs, "keepalive.lastReadPollAt")
    read_poll_age = max(0.0, now - float(read_poll_at)) if isinstance(read_poll_at, (int, float)) and read_poll_at > 0 else -1.0
    print(f"keepalive_last_read_poll_age_s={read_poll_age:.1f}")
    read_poll_result_at = pref(prefs, "keepalive.lastReadPollResultAt")
    read_poll_result_age = max(0.0, now - float(read_poll_result_at)) if isinstance(read_poll_result_at, (int, float)) and read_poll_result_at > 0 else -1.0
    print(f"keepalive_last_read_poll_result_age_s={read_poll_result_age:.1f}")
    print(f"keepalive_last_read_poll_result_status={pref(prefs, 'keepalive.lastReadPollResultStatus', 'missing') or 'missing'}")
    print(f"keepalive_last_read_poll_result_bpm={int(pref(prefs, 'keepalive.lastReadPollResultBPM', -1) or -1)}")
    print(f"keepalive_last_read_poll_result_rr_values={int(pref(prefs, 'keepalive.lastReadPollResultRRValues', -1) or -1)}")

def emit_strap_stream_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"strap_stream_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    updated_at = pref(prefs, "strapStream.updatedAt")
    suppressed_at = pref(prefs, "strapStream.lowBatteryReconnectSuppressedAt")
    rearmed_at = pref(prefs, "strapStream.lowBatteryReconnectRearmedAt")
    updated_age = max(0.0, now - float(updated_at)) if isinstance(updated_at, (int, float)) and updated_at > 0 else -1.0
    suppressed_age = max(0.0, now - float(suppressed_at)) if isinstance(suppressed_at, (int, float)) and suppressed_at > 0 else -1.0
    rearmed_age = max(0.0, now - float(rearmed_at)) if isinstance(rearmed_at, (int, float)) and rearmed_at > 0 else -1.0
    print(f"strap_stream_namespace={pref_namespace(prefs, 'strapStream.state')}")
    print(f"strap_stream_state={pref(prefs, 'strapStream.state', 'missing') or 'missing'}")
    print(f"strap_stream_reason={pref(prefs, 'strapStream.reason', 'missing') or 'missing'}")
    print(f"strap_stream_packet_age_s={float(pref(prefs, 'strapStream.packetAge', -1) or -1):.1f}")
    print(f"strap_stream_battery_level={int(pref(prefs, 'strapStream.batteryLevel', -1) or -1)}")
    print(f"strap_stream_notifying={bool_int(pref(prefs, 'strapStream.notifying'))}")
    print(f"strap_stream_gatt_reads_ok={bool_int(pref(prefs, 'strapStream.gattReadsOK'))}")
    print(f"strap_stream_updated_age_s={updated_age:.1f}")
    print(f"strap_stream_low_battery_reconnect_suppressed={bool_int(pref(prefs, 'strapStream.lowBatteryReconnectSuppressed'))}")
    print(f"strap_stream_low_battery_reconnect_suppressed_age_s={suppressed_age:.1f}")
    print(f"strap_stream_low_battery_reconnect_suppression_reason={pref(prefs, 'strapStream.lowBatteryReconnectSuppressionReason', 'missing') or 'missing'}")
    print(f"strap_stream_low_battery_reconnect_suppression_count={int(pref(prefs, 'strapStream.lowBatteryReconnectSuppressionCount', 0) or 0)}")
    print(f"strap_stream_low_battery_reconnect_rearmed_age_s={rearmed_age:.1f}")
    print(f"strap_stream_accessibility_label={pref(prefs, 'strapStream.accessibilityLabel', 'missing') or 'missing'}")

def emit_notification_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"notification_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    cleared_at = pref(prefs, "notification.battery.drainCycleClearedAt")
    cleared_age = max(0.0, now - float(cleared_at)) if isinstance(cleared_at, (int, float)) and cleared_at > 0 else -1.0
    print(f"notification_namespace={pref_namespace(prefs, 'notification.battery.warningDrainCycleScheduled')}")
    print(f"notification_battery_warning_drain_cycle_scheduled={bool_int(pref(prefs, 'notification.battery.warningDrainCycleScheduled'))}")
    print(f"notification_battery_shutoff_drain_cycle_scheduled={bool_int(pref(prefs, 'notification.battery.shutoffDrainCycleScheduled'))}")
    print(f"notification_battery_drain_cycle_cleared_age_s={cleared_age:.1f}")

def emit_scene_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"scene_summary_error={type(exc).__name__}:{exc}")
        return
    now = time.time()
    updated_at = pref(prefs, "scene.updatedAt")
    active_at = pref(prefs, "scene.lastActiveAt")
    inactive_at = pref(prefs, "scene.lastInactiveAt")
    background_at = pref(prefs, "scene.lastBackgroundAt")
    fast_launch_at = pref(prefs, "scene.fastLaunchAt")
    did_become_active_at = pref(prefs, "scene.lastDidBecomeActiveAt")
    will_enter_foreground_at = pref(prefs, "scene.lastWillEnterForegroundAt")
    updated_age = max(0.0, now - float(updated_at)) if isinstance(updated_at, (int, float)) and updated_at > 0 else -1.0
    active_age = max(0.0, now - float(active_at)) if isinstance(active_at, (int, float)) and active_at > 0 else -1.0
    inactive_age = max(0.0, now - float(inactive_at)) if isinstance(inactive_at, (int, float)) and inactive_at > 0 else -1.0
    background_age = max(0.0, now - float(background_at)) if isinstance(background_at, (int, float)) and background_at > 0 else -1.0
    fast_launch_age = max(0.0, now - float(fast_launch_at)) if isinstance(fast_launch_at, (int, float)) and fast_launch_at > 0 else -1.0
    did_become_active_age = max(0.0, now - float(did_become_active_at)) if isinstance(did_become_active_at, (int, float)) and did_become_active_at > 0 else -1.0
    will_enter_foreground_age = max(0.0, now - float(will_enter_foreground_at)) if isinstance(will_enter_foreground_at, (int, float)) and will_enter_foreground_at > 0 else -1.0
    print(f"scene_namespace={pref_namespace(prefs, 'scene.phase')}")
    print(f"scene_phase={pref(prefs, 'scene.phase', 'missing') or 'missing'}")
    print(f"scene_reason={pref(prefs, 'scene.reason', 'missing') or 'missing'}")
    print(f"scene_application_state={pref(prefs, 'scene.applicationState', 'missing') or 'missing'}")
    print(f"scene_updated_age_s={updated_age:.1f}")
    print(f"scene_last_active_age_s={active_age:.1f}")
    print(f"scene_last_inactive_age_s={inactive_age:.1f}")
    print(f"scene_last_background_age_s={background_age:.1f}")
    print(f"scene_fast_launch_age_s={fast_launch_age:.1f}")
    print(f"scene_last_did_become_active_age_s={did_become_active_age:.1f}")
    print(f"scene_last_will_enter_foreground_age_s={will_enter_foreground_age:.1f}")

def emit_strain_target_haptic_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"strain_target_haptic_summary_error={type(exc).__name__}:{exc}")
        return
    print(f"strain_target_haptic_debug_status={pref(prefs, 'debug.strainTargetHaptic.status', 'missing') or 'missing'}")
    print(f"strain_target_haptic_debug_count={int(pref(prefs, 'debug.strainTargetHaptic.count', 0) or 0)}")
    print(f"strain_target_haptic_debug_strain={float(pref(prefs, 'debug.strainTargetHaptic.strain', 0) or 0):.1f}")
    print(f"strain_target_haptic_debug_target={float(pref(prefs, 'debug.strainTargetHaptic.target', 0) or 0):.1f}")

def emit_session_backup_restore_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"session_backup_restore_summary_error={type(exc).__name__}:{exc}")
        return
    summary = {}
    summary_text = pref(prefs, 'debug.sessionBackup.restore.summary')
    if isinstance(summary_text, dict):
        summary = summary_text
    elif isinstance(summary_text, str):
        try:
            parsed = json.loads(summary_text)
            if isinstance(parsed, dict):
                summary = parsed
        except Exception as exc:
            print(f"session_backup_restore_summary_parse_error={type(exc).__name__}:{exc}")
    def restore_value(name, suffix, default=None):
        return summary.get(name, pref(prefs, f"debug.sessionBackup.restore.{suffix}", default))
    print(f"session_backup_restore_debug_status={restore_value('status', 'status', 'missing') or 'missing'}")
    print(f"session_backup_restore_debug_path={restore_value('path', 'path', 'missing') or 'missing'}")
    print(f"session_backup_restore_debug_safety_path={restore_value('safetyPath', 'safetyPath', 'missing') or 'missing'}")
    print(f"session_backup_restore_debug_schema={int(restore_value('schema', 'schema', 0) or 0)}")
    print(f"session_backup_restore_debug_sessions={int(restore_value('sessions', 'sessions', 0) or 0)}")
    print(f"session_backup_restore_debug_rollups={int(restore_value('rollups', 'rollups', 0) or 0)}")
    print(f"session_backup_restore_debug_confirmed_sleeps={int(restore_value('confirmedSleeps', 'confirmedSleeps', 0) or 0)}")
    print(f"session_backup_restore_debug_digest={restore_value('digest', 'digest', 'missing') or 'missing'}")
    print(f"session_backup_restore_debug_reason={restore_value('reason', 'reason', 'missing') or 'missing'}")

def emit_confirmed_workout_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"confirmed_workout_summary_error={type(exc).__name__}:{exc}")
        return
    raw = pref(prefs, "confirmedWorkouts.v1")
    workouts = []
    if isinstance(raw, bytes):
        try:
            decoded = json.loads(raw.decode("utf-8"))
            workouts = decoded if isinstance(decoded, list) else []
        except Exception as exc:
            print(f"confirmed_workout_summary_status=error:{type(exc).__name__}:{exc}")
    elif isinstance(raw, str):
        try:
            decoded = json.loads(raw)
            workouts = decoded if isinstance(decoded, list) else []
        except Exception as exc:
            print(f"confirmed_workout_summary_status=error:{type(exc).__name__}:{exc}")

    def workout_time(row, key):
        value = row.get(key) if isinstance(row, dict) else None
        if isinstance(value, (int, float)) and value > 0:
            return app_time(value)
        return "missing"

    latest = max(
        (row for row in workouts if isinstance(row, dict)),
        key=lambda row: row.get("createdAt") or row.get("end") or row.get("start") or 0,
        default=None,
    )
    print("confirmed_workout_summary_status=ok")
    print(f"confirmed_workouts_count={len(workouts)}")
    coverage_rows = [
        row for row in workouts
        if isinstance(row, dict) and isinstance(row.get("streamCoveragePercent"), (int, float))
    ]
    incomplete = [row for row in coverage_rows if float(row.get("streamCoveragePercent", 0)) < 75]
    lowest_coverage = min(
        coverage_rows,
        key=lambda row: float(row.get("streamCoveragePercent", 0)),
        default=None,
    )
    print(f"confirmed_workouts_incomplete_coverage_count={len(incomplete)}")
    if lowest_coverage:
        print(f"lowest_coverage_workout_id={lowest_coverage.get('id', 'missing') or 'missing'}")
        print(f"lowest_coverage_workout_label={lowest_coverage.get('label', 'missing') or 'missing'}")
        print(f"lowest_coverage_workout_start={workout_time(lowest_coverage, 'start')}")
        print(f"lowest_coverage_workout_end={workout_time(lowest_coverage, 'end')}")
        print(f"lowest_coverage_workout_percent={int(lowest_coverage.get('streamCoveragePercent', 0) or 0)}")
        print(f"lowest_coverage_workout_samples={int(lowest_coverage.get('samples', 0) or 0)}")
        print(f"lowest_coverage_workout_observed_s={float(lowest_coverage.get('observedDuration', 0) or 0):.1f}")
        print(f"lowest_coverage_workout_strain={float(lowest_coverage.get('strain', 0) or 0):.3f}")
    else:
        print("lowest_coverage_workout_id=none")
    if latest:
        print(f"latest_confirmed_workout_id={latest.get('id', 'missing') or 'missing'}")
        print(f"latest_confirmed_workout_label={latest.get('label', 'missing') or 'missing'}")
        print(f"latest_confirmed_workout_source={latest.get('source', 'missing') or 'missing'}")
        print(f"latest_confirmed_workout_review_source={latest.get('reviewSource', 'missing') or 'missing'}")
        print(f"latest_confirmed_workout_start={workout_time(latest, 'start')}")
        print(f"latest_confirmed_workout_end={workout_time(latest, 'end')}")
        print(f"latest_confirmed_workout_created={workout_time(latest, 'createdAt')}")
        print(f"latest_confirmed_workout_peak={int(latest.get('peakHR', latest.get('peak', 0)) or 0)}")
        print(f"latest_confirmed_workout_samples={int(latest.get('samples', 0) or 0)}")
    else:
        print("latest_confirmed_workout_id=none")
        print("latest_confirmed_workout_label=none")
        print("latest_confirmed_workout_source=none")
        print("latest_confirmed_workout_review_source=none")
        print("latest_confirmed_workout_start=none")
        print("latest_confirmed_workout_end=none")
        print("latest_confirmed_workout_created=none")
        print("latest_confirmed_workout_peak=0")
        print("latest_confirmed_workout_samples=0")

def emit_daily_rollups_summary():
    rollups_path = evidence / "daily-rollups.json"
    if not rollups_path.exists():
        print("daily_rollups_summary_status=missing")
        return
    try:
        rollups = json.loads(rollups_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"daily_rollups_summary_status=error:{type(exc).__name__}:{exc}")
        return
    if not isinstance(rollups, list):
        print("daily_rollups_summary_status=error:not_array")
        return

    def has_value(row, key):
        return isinstance(row, dict) and row.get(key) is not None

    def has_vital(row, key):
        if not isinstance(row, dict):
            return False
        vitals = row.get("vitals")
        return isinstance(vitals, dict) and isinstance(vitals.get(key), dict) and vitals[key].get("n", 0)

    today = dt.datetime.now().astimezone().date().isoformat()
    days = [row.get("day") for row in rollups if isinstance(row, dict) and isinstance(row.get("day"), str)]
    newest_day = max(days) if days else "none"
    today_rows = sum(1 for row in rollups if isinstance(row, dict) and row.get("day") == today)
    today_row = next((row for row in rollups if isinstance(row, dict) and row.get("day") == today), {})

    def collection_count(row, key):
        value = row.get(key) if isinstance(row, dict) else None
        return len(value) if isinstance(value, list) else 0

    print("daily_rollups_summary_status=ok")
    print(f"daily_rollups_count={len(rollups)}")
    print(f"daily_rollups_newest_day={newest_day}")
    print(f"daily_rollups_today={today}")
    print(f"daily_rollups_today_rows={today_rows}")
    print(f"daily_rollups_today_activity_candidates={collection_count(today_row, 'activityCandidates')}")
    print(f"daily_rollups_today_workouts={collection_count(today_row, 'workouts')}")
    print(f"daily_rollups_today_confirmed_workouts={collection_count(today_row, 'confirmedWorkouts')}")
    print(f"daily_rollups_activity_candidate_days={sum(1 for row in rollups if collection_count(row, 'activityCandidates') > 0)}")
    print(f"daily_rollups_workout_days={sum(1 for row in rollups if collection_count(row, 'workouts') > 0)}")
    print(f"daily_rollups_confirmed_workout_days={sum(1 for row in rollups if collection_count(row, 'confirmedWorkouts') > 0)}")
    for key in ["recovery", "lnRMSSD", "rhr", "sleepSeconds", "sleepPerformance", "strain", "respiratoryRate", "bedtimeMinutes"]:
        print(f"daily_rollups_{key}_count={sum(1 for row in rollups if has_value(row, key))}")
    for key in ["rhr", "hrv", "resp"]:
        print(f"daily_rollups_vitals_{key}_count={sum(1 for row in rollups if has_vital(row, key))}")

emit_offline_sync_preferences()
emit_battery_preferences()
emit_motion_context_preferences()
emit_hr_broadcast_preferences()
emit_ble_link_preferences()
emit_duty_cycle_and_compaction_preferences()
emit_watchdog_preferences()
emit_sample_preferences()
emit_keepalive_preferences()
emit_strap_stream_preferences()
emit_notification_preferences()
emit_scene_preferences()
emit_strain_target_haptic_preferences()
emit_session_backup_restore_preferences()
emit_confirmed_workout_preferences()
emit_daily_rollups_summary()
emit_historical_archive_index_summary()
emit_historical_archive_rotation_summary()
emit_step_calibration_capture_preferences()
emit_step_calibration_sequence_preferences()
emit_step_calibration_archive_summary()

def decode_historical_gravity(payload_hex):
    try:
        payload = bytes.fromhex(payload_hex)
    except Exception:
        return None
    if len(payload) < 2:
        return None
    version = payload[1]
    try:
        if version == 25:
            if len(payload) < 75:
                return None
            x_raw, y_raw, z_raw = struct.unpack_from("<hhh", payload, 69)
            x, y, z = x_raw / 16384.0, y_raw / 16384.0, z_raw / 16384.0
        else:
            if len(payload) < 48:
                return None
            x, y, z = struct.unpack_from("<fff", payload, 36)
    except Exception:
        return None
    magnitude = math.sqrt(x * x + y * y + z * z)
    return magnitude, 0.8 <= magnitude <= 1.2, version

def historical_current_session_usable(row):
    unix = row.get("clockCorrectedUnix7") or row.get("unix7") or 0
    if not isinstance(unix, int) or unix <= 0:
        return False
    payload_hex = row.get("rawPayloadHex")
    if not isinstance(payload_hex, str) or not payload_hex:
        return False
    gravity = decode_historical_gravity(payload_hex)
    if gravity is None or gravity[1] is not True:
        return False
    direct_rr_count = len(row.get("whoofRR19") or []) + len(row.get("kRR64") or [])
    candidate_rr_count = len(row.get("candidateRR") or [])
    return direct_rr_count > 0 or candidate_rr_count >= 2

def emit_historical_archive_summary():
    archive_path = evidence / "historical-archive.jsonl"
    segments_path = evidence / "historical-archive-segments"
    archive_paths = []
    if archive_path.is_file():
        archive_paths.append(archive_path)
    if segments_path.is_dir():
        archive_paths.extend(sorted(
            path for path in segments_path.rglob("*.jsonl")
            if path.is_file()
        ))
    partial_copy = (evidence / "historical-archive.jsonl.partial").exists()
    if not archive_paths:
        print("historical_archive_summary_status=missing")
        print("historical_archive_metric_ready=0")
        print("historical_archive_metric_promotion_blocker=missing_archive")
        print("historical_archive_interpretation=missing_archive")
        return
    rows = 0
    parse_errors = 0
    schemas = set()
    layouts = set()
    payload_lengths = set()
    raw_payload_rows = 0
    undecodable_rows = 0
    metric_usable_rows = 0
    current_usable_rows = 0
    whoof_rr_values = 0
    k_rr_values = 0
    candidate_rr_values = 0
    unix_values = []
    corrected_values = []
    clock_rows = 0
    clock_statuses = set()
    clock_offsets = []
    gravity_rows = 0
    gravity_validated_rows = 0
    gravity_min = None
    gravity_max = None
    hist_versions = set()
    validated_layout_versions = set()
    try:
        source_text = historical_archive_source.read_text(encoding="utf-8")
        declaration = re.search(
            r"validatedMetricLayoutVersions:\s*Set<String>\s*=\s*\[([^\]]*)\]",
            source_text,
            re.S,
        )
        if declaration:
            validated_layout_versions = set(re.findall(r'"([^"]+)"', declaration.group(1)))
            if "layoutVersion" in declaration.group(1):
                prefix = re.search(r'decodedLayoutPrefix\s*=\s*"([^"]+)"', source_text)
                version = re.search(r'static let layoutVersion\s*=\s*layoutVersion\(for:\s*(\d+)\)', source_text)
                if prefix and version:
                    validated_layout_versions.add(f"{prefix.group(1)}_v{version.group(1)}")
    except Exception:
        validated_layout_versions = set()
    for archive_file in archive_paths:
        with archive_file.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    parse_errors += 1
                    continue
                rows += 1
                schemas.add(str(row.get("schema", "missing")))
                layouts.add(str(row.get("layoutVersion", "undecodable")))
                if isinstance(row.get("payloadLength"), int):
                    payload_lengths.add(int(row["payloadLength"]))
                if row.get("metricUsable") is True:
                    metric_usable_rows += 1
                if row.get("currentSessionUsable") is True or historical_current_session_usable(row):
                    current_usable_rows += 1
                if row.get("source") == "0x2f" and "layoutVersion" not in row:
                    undecodable_rows += 1
                if isinstance(row.get("unix7"), int) and int(row["unix7"]) > 0:
                    unix_values.append(int(row["unix7"]))
                if isinstance(row.get("clockCorrectedUnix7"), int) and int(row["clockCorrectedUnix7"]) > 0:
                    corrected_values.append(int(row["clockCorrectedUnix7"]))
                if row.get("clockCorrectionStatus"):
                    clock_rows += 1
                    clock_statuses.add(str(row.get("clockCorrectionStatus")))
                if isinstance(row.get("clockDriftSeconds"), int):
                    clock_offsets.append(int(row["clockDriftSeconds"]))
                whoof_rr_values += len(row.get("whoofRR19") or [])
                k_rr_values += len(row.get("kRR64") or [])
                candidate_rr_values += len(row.get("candidateRR") or [])
                payload_hex = row.get("rawPayloadHex")
                if isinstance(payload_hex, str) and payload_hex:
                    raw_payload_rows += 1
                    gravity = decode_historical_gravity(payload_hex)
                    if gravity is not None:
                        magnitude, valid, version = gravity
                        gravity_rows += 1
                        hist_versions.add(version)
                        gravity_min = magnitude if gravity_min is None else min(gravity_min, magnitude)
                        gravity_max = magnitude if gravity_max is None else max(gravity_max, magnitude)
                        if valid:
                            gravity_validated_rows += 1
    validated_layout_rows_present = bool(layouts.intersection(validated_layout_versions))
    metric_ready = (not partial_copy and parse_errors == 0 and rows > 0
                    and metric_usable_rows > 0 and current_usable_rows > 0
                    and validated_layout_rows_present)
    if partial_copy:
        interpretation = "partial_local_copy"
        metric_gate = "copy_incomplete"
        user_action = "rerun_pull_or_use_bounded_archive_export"
    elif parse_errors:
        interpretation = "parse_errors"
        metric_gate = "repair_needed"
        user_action = "archive_needs_repair"
    elif not validated_layout_versions:
        interpretation = "archive_persisted_decoder_validation_required"
        metric_gate = "layout_not_reference_validated"
        user_action = "capture_synchronized_live_hr_rr_reference_before_metric_use"
    elif not validated_layout_rows_present:
        interpretation = "archive_layout_not_whitelisted"
        metric_gate = "archive_layout_not_validated"
        user_action = "validate_exact_archived_layout_before_metric_use"
    elif metric_ready:
        interpretation = "metric_ready"
        metric_gate = "metric_ready"
        user_action = "historical_rows_can_feed_metrics"
    elif current_usable_rows > 0:
        interpretation = "archive_persisted_continuity_repair_only"
        metric_gate = "continuity_repair_only"
        user_action = "safe_for_gap_repair_but_metrics_wait_for_rr_validation"
    elif rows > 0:
        interpretation = "archive_persisted_fail_closed_rows"
        metric_gate = "metrics_gated"
        user_action = "validate_historical_rr_layout_before_metric_use"
    else:
        interpretation = "empty_archive"
        metric_gate = "waiting"
        user_action = "wait_for_missed_data_after_reconnect"
    print(f"historical_archive_summary_status={'partial_copy' if partial_copy else 'ok'}")
    print(f"historical_archive_files_scanned={len(archive_paths)}")
    print(f"historical_archive_rows={rows}")
    print(f"historical_archive_parse_errors={parse_errors}")
    print(f"historical_archive_schemas={','.join(sorted(schemas)) if schemas else 'none'}")
    print(f"historical_archive_layouts={','.join(sorted(layouts)) if layouts else 'none'}")
    print(f"historical_archive_validated_metric_layouts={','.join(sorted(validated_layout_versions)) if validated_layout_versions else 'none'}")
    print(f"historical_archive_payload_lengths={','.join(map(str, sorted(payload_lengths))) if payload_lengths else 'none'}")
    print(f"historical_archive_raw_payload_rows={raw_payload_rows}")
    print(f"historical_archive_undecodable_rows={undecodable_rows}")
    print(f"historical_archive_metric_usable_rows={metric_usable_rows}")
    print(f"historical_archive_current_session_usable_rows={current_usable_rows}")
    print(f"historical_archive_whoof_rr_values={whoof_rr_values}")
    print(f"historical_archive_k_rr_values={k_rr_values}")
    print(f"historical_archive_candidate_rr_values={candidate_rr_values}")
    print(f"historical_archive_hist_versions={','.join(map(str, sorted(hist_versions))) if hist_versions else 'none'}")
    print(f"historical_archive_gravity_rows={gravity_rows}")
    print(f"historical_archive_gravity_validated_rows={gravity_validated_rows}")
    if gravity_rows:
        print(f"historical_archive_gravity_validated_percent={round((gravity_validated_rows / gravity_rows) * 100)}")
        print(f"historical_archive_gravity_mag_min={gravity_min:.3f}")
        print(f"historical_archive_gravity_mag_max={gravity_max:.3f}")
    if unix_values:
        print(f"historical_archive_unix_first={min(unix_values)}")
        print(f"historical_archive_unix_last={max(unix_values)}")
    print(f"historical_archive_clock_correlation_rows={clock_rows}")
    print(f"historical_archive_clock_correlation_statuses={','.join(sorted(clock_statuses)) if clock_statuses else 'none'}")
    if clock_offsets:
        print(f"historical_archive_clock_offset_s={clock_offsets[-1]}")
    if corrected_values:
        print(f"historical_archive_clock_corrected_unix_first={min(corrected_values)}")
        print(f"historical_archive_clock_corrected_unix_last={max(corrected_values)}")
    print(f"historical_archive_metric_ready={1 if metric_ready else 0}")
    print(f"historical_archive_metric_gate={metric_gate}")
    print(f"historical_archive_metric_promotion_blocker={metric_gate if not metric_ready else 'none'}")
    print(f"historical_archive_user_action={user_action}")
    print(f"historical_archive_interpretation={interpretation}")

emit_historical_archive_identity_summary()
emit_historical_archive_summary()

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
    def local_median_rr(values, index, radius=2):
        lower = max(0, index - radius)
        upper = min(len(values), index + radius + 1)
        local = sorted(v for v in values[lower:upper] if 300 <= v <= 2000)
        if len(local) < 3:
            return None
        middle = len(local) // 2
        if len(local) % 2 == 0:
            return (local[middle - 1] + local[middle]) / 2
        return local[middle]

    corrected_rr = []
    dropped_delta = 0
    for index, value in enumerate(rr_values):
        if not (300 <= value <= 2000):
            continue
        local_median = local_median_rr(rr_values, index)
        if local_median is not None and local_median > 0 and abs(value - local_median) / local_median > 0.20:
            dropped_delta += 1
            continue
        corrected_rr.append(value)
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

def format_duration(seconds):
    seconds = max(0, float(seconds or 0))
    minutes = int(round(seconds / 60))
    hours = minutes // 60
    remainder = minutes % 60
    return f"{hours}h{remainder:02d}m" if hours else f"{remainder}m"

def read_confirmed_sleeps_from_preferences():
    prefs_path = evidence / "preferences.plist"
    if not prefs_path.exists():
        return []
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception as exc:
        print(f"confirmed_sleep_preferences_error={type(exc).__name__}:{exc}")
        return []
    raw = pref(prefs, "confirmedSleeps.v1")
    if raw is None:
        return []
    if isinstance(raw, str):
        raw = raw.encode("utf-8")
    if not isinstance(raw, (bytes, bytearray)):
        print(f"confirmed_sleep_preferences_error=unexpected_type:{type(raw).__name__}")
        return []
    try:
        decoded = json.loads(bytes(raw).decode("utf-8"))
    except Exception as exc:
        print(f"confirmed_sleep_decode_error={type(exc).__name__}:{exc}")
        return []
    return decoded if isinstance(decoded, list) else []

def stage_breakdown(segments):
    totals = {"awake": 0.0, "light": 0.0, "rem": 0.0, "sws": 0.0, "deep": 0.0}
    for segment in segments or []:
        stage = str(segment.get("stage", "")).lower()
        if stage not in totals:
            continue
        start = app_time(segment.get("start"))
        end = app_time(segment.get("end"))
        if start is None or end is None:
            continue
        totals[stage] += max(0.0, (end - start).total_seconds())
    return totals

def confirmed_sleep_is_nap(record):
    source = str(record.get("source", ""))
    duration = float(record.get("duration") or 0)
    if source in ("manual_nap", "auto_nap", "nap_candidate", "hr_only_nap", "user_adjusted_nap"):
        return True
    if source in ("manual_sleep", "auto_sleep", "auto_confirmed_sleep", "auto_confirmed_sleep_hr_only",
                  "aggregate_sleep", "sleep_window", "validated_sleep_window", "overnight_sleep",
                  "sleep_candidate", "single_session_sleep_candidate", "incomplete_fragmented_sleep",
                  "user_adjusted_sleep"):
        return False
    return duration <= 3 * 60 * 60

def emit_confirmed_sleep_summary():
    sleeps = read_confirmed_sleeps_from_preferences()
    print(f"confirmed_sleep_records={len(sleeps)}")
    if not sleeps:
        print("confirmed_sleep_status=missing")
        return
    sleeps.sort(key=lambda row: float(row.get("start", 0) or 0), reverse=True)
    nap_count = sum(1 for row in sleeps if confirmed_sleep_is_nap(row))
    stage_ready_count = sum(1 for row in sleeps if row.get("stageSegments"))
    print("confirmed_sleep_status=ok")
    print(f"confirmed_sleep_naps={nap_count}")
    print(f"confirmed_sleep_overnights={len(sleeps) - nap_count}")
    print(f"confirmed_sleep_stage_records={stage_ready_count}")
    latest_sleep = sleeps[0]
    start = app_time(latest_sleep.get("start"))
    end = app_time(latest_sleep.get("end"))
    segments = latest_sleep.get("stageSegments") or []
    totals = stage_breakdown(segments)
    stage_total = sum(totals.values())
    print(f"latest_confirmed_sleep_kind={'nap' if confirmed_sleep_is_nap(latest_sleep) else 'sleep'}")
    print(f"latest_confirmed_sleep_source={latest_sleep.get('source', 'missing')}")
    print(f"latest_confirmed_sleep_confidence={latest_sleep.get('confidence', 'missing')}")
    print(f"latest_confirmed_sleep_start={start.astimezone(ist).isoformat() if start else 'none'}")
    print(f"latest_confirmed_sleep_end={end.astimezone(ist).isoformat() if end else 'none'}")
    print(f"latest_confirmed_sleep_duration_s={int(float(latest_sleep.get('duration') or 0))}")
    print(f"latest_confirmed_sleep_span_s={int(float(latest_sleep.get('span') or 0))}")
    print(f"latest_confirmed_sleep_duration_text={format_duration(float(latest_sleep.get('duration') or 0))}")
    print(f"latest_confirmed_sleep_samples={int(latest_sleep.get('samples') or 0)}")
    print(f"latest_confirmed_sleep_sessions={int(latest_sleep.get('sessions') or 0)}")
    print(f"latest_confirmed_sleep_motion_source={latest_sleep.get('motionSource', 'missing')}")
    print(f"latest_confirmed_sleep_motion_validated={bool_int(latest_sleep.get('motionValidated'))}")
    print(f"latest_confirmed_sleep_stage_segments={len(segments)}")
    print(f"latest_confirmed_sleep_stage_total_s={int(stage_total)}")
    print(f"latest_confirmed_sleep_stage_awake_s={int(totals['awake'])}")
    print(f"latest_confirmed_sleep_stage_light_s={int(totals['light'])}")
    print(f"latest_confirmed_sleep_stage_rem_s={int(totals['rem'])}")
    print(f"latest_confirmed_sleep_stage_sws_s={int(totals['sws'])}")
    print(f"latest_confirmed_sleep_stage_deep_s={int(totals['deep'])}")

emit_confirmed_sleep_summary()

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
        confirmed_sleeps_for_overlap = read_confirmed_sleeps_from_preferences()
        def sleep_windows_overlap(record, candidate):
            record_start = app_time(record.get("start"))
            record_end = app_time(record.get("end"))
            candidate_start = app_time(candidate.get("start"))
            candidate_end = app_time(candidate.get("end"))
            if not record_start or not record_end or not candidate_start or not candidate_end:
                return False
            overlap = min(record_end, candidate_end) - max(record_start, candidate_start)
            return overlap.total_seconds() > 15 * 60
        print(f"sessions_count={len(sessions)}")
        print(f"phone_motion_sessions={len(phone_sessions)}")
        print(f"phone_motion_nonzero_sessions={len(phone_nonzero_sessions)}")
        sleep_reasons = {}
        sleep_like_windows = []
        nap_like_windows = []
        for session in sessions:
            reason = session.get("sleepWakeResearchReason")
            if reason:
                sleep_reasons[str(reason)] = sleep_reasons.get(str(reason), 0) + 1
            start_value = session.get("start", 0)
            end_value = session.get("end", start_value)
            try:
                duration = max(0.0, float(end_value) - float(start_value))
            except Exception:
                duration = 0.0
            points = session.get("points") or []
            bpms = [int(point.get("bpm", 0)) for point in points if point.get("bpm") is not None and int(point.get("bpm", 0)) > 0]
            average_bpm = sum(bpms) / len(bpms) if bpms else 0
            candidate = {
                "label": session.get("label", ""),
                "start": start_value,
                "end": end_value,
                "duration": duration,
                "points": len(points),
                "rr": len(session.get("rrPoints") or []),
                "average_bpm": average_bpm,
                "reason": reason or "missing",
            }
            if duration >= 3 * 60 * 60 and 0 < average_bpm <= 78:
                sleep_like_windows.append(candidate)
            elif 20 * 60 <= duration <= 3 * 60 * 60 and 0 < average_bpm <= 82:
                nap_like_windows.append(candidate)
        sleep_like_windows.sort(key=lambda row: (row["duration"], row["points"]), reverse=True)
        nap_like_windows.sort(key=lambda row: (row["duration"], row["points"]), reverse=True)
        print(f"sleep_research_reason_counts={','.join(f'{key}:{sleep_reasons[key]}' for key in sorted(sleep_reasons)) if sleep_reasons else 'none'}")
        print(f"sleep_like_raw_windows={len(sleep_like_windows)}")
        print(f"nap_like_raw_windows={len(nap_like_windows)}")
        best_sleep_like = sleep_like_windows[0] if sleep_like_windows else None
        best_nap_like = nap_like_windows[0] if nap_like_windows else None
        latest_sleep_like = max(sleep_like_windows, key=lambda row: float(row["end"])) if sleep_like_windows else None
        if latest_sleep_like:
            latest_sleep_start = app_time(latest_sleep_like["start"]).astimezone(ist)
            latest_sleep_end = app_time(latest_sleep_like["end"]).astimezone(ist)
            print(f"latest_sleep_like_raw_start={latest_sleep_start.isoformat()}")
            print(f"latest_sleep_like_raw_end={latest_sleep_end.isoformat()}")
            print(f"latest_sleep_like_raw_duration_s={int(latest_sleep_like['duration'])}")
            print(f"latest_sleep_like_raw_avg_hr={int(round(latest_sleep_like['average_bpm']))}")
            print(f"latest_sleep_like_raw_samples={latest_sleep_like['points']}")
            print(f"latest_sleep_like_raw_rr_values={latest_sleep_like['rr']}")
            print(f"latest_sleep_like_raw_reason={latest_sleep_like['reason']}")
        else:
            print("latest_sleep_like_raw_status=missing")
        if best_sleep_like:
            start_sleep_like = app_time(best_sleep_like["start"]).astimezone(ist)
            end_sleep_like = app_time(best_sleep_like["end"]).astimezone(ist)
            pending_review = not any(sleep_windows_overlap(record, best_sleep_like) for record in confirmed_sleeps_for_overlap)
            print(f"best_sleep_like_raw_start={start_sleep_like.isoformat()}")
            print(f"best_sleep_like_raw_end={end_sleep_like.isoformat()}")
            print(f"best_sleep_like_raw_duration_s={int(best_sleep_like['duration'])}")
            print(f"best_sleep_like_raw_avg_hr={int(round(best_sleep_like['average_bpm']))}")
            print(f"best_sleep_like_raw_samples={best_sleep_like['points']}")
            print(f"best_sleep_like_raw_rr_values={best_sleep_like['rr']}")
            print(f"best_sleep_like_raw_reason={best_sleep_like['reason']}")
            print(f"pending_sleep_review_status={'pending_user_confirmation' if pending_review else 'already_confirmed_overlap'}")
            print("pending_sleep_review_kind=sleep")
            print("pending_sleep_review_source=sleep_window")
            print(f"pending_sleep_review_start={start_sleep_like.isoformat()}")
            print(f"pending_sleep_review_end={end_sleep_like.isoformat()}")
            print(f"pending_sleep_review_duration_s={int(best_sleep_like['duration'])}")
            print(f"pending_sleep_review_samples={best_sleep_like['points']}")
            print("pending_sleep_review_motion_policy=strap_hr_review_without_stage_fabrication")
        else:
            print("best_sleep_like_raw_status=missing")
            print("pending_sleep_review_status=missing")
        if best_nap_like:
            start_nap_like = app_time(best_nap_like["start"]).astimezone(ist)
            end_nap_like = app_time(best_nap_like["end"]).astimezone(ist)
            print(f"best_nap_like_raw_start={start_nap_like.isoformat()}")
            print(f"best_nap_like_raw_end={end_nap_like.isoformat()}")
            print(f"best_nap_like_raw_duration_s={int(best_nap_like['duration'])}")
            print(f"best_nap_like_raw_avg_hr={int(round(best_nap_like['average_bpm']))}")
            print(f"best_nap_like_raw_samples={best_nap_like['points']}")
            print(f"best_nap_like_raw_rr_values={best_nap_like['rr']}")
            print(f"best_nap_like_raw_reason={best_nap_like['reason']}")
        else:
            print("best_nap_like_raw_status=missing")
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

def active_journal_freshness(updated_at):
    try:
        updated = app_time(updated_at)
    except Exception:
        updated = None
    if updated is None:
        return "unknown"
    age = (dt.datetime.now(dt.timezone.utc) - updated.astimezone(dt.timezone.utc)).total_seconds()
    if age < -300:
        return "future_clock_skew"
    return "fresh" if age <= 90 else "stale"

def valid_nonnegative_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0

def valid_journal_time(value):
    try:
        parsed = app_time(value)
        return parsed is not None and math.isfinite(parsed.timestamp())
    except Exception:
        return False

def valid_journal_samples(values, rr=False):
    if not isinstance(values, list):
        return False
    required_value = "ms" if rr else "bpm"
    return all(
        isinstance(value, dict)
        and valid_journal_time(value.get("t"))
        and isinstance(value.get(required_value), int)
        and not isinstance(value.get(required_value), bool)
        for value in values
    )

def journal_metadata_structure_errors(value):
    errors = []
    for key in (
        "rawHRNotifications", "acceptedHRSamples", "zeroHRSamples",
        "heldArtifacts", "droppedArtifacts", "rawHRGaps", "acceptedHRGaps",
    ):
        if not valid_nonnegative_integer(value.get(key)):
            errors.append(f"invalid_{key}")
    for key in ("maxRawHRGap", "maxAcceptedHRGap"):
        field = value.get(key)
        if not isinstance(field, (int, float)) or isinstance(field, bool) or not math.isfinite(float(field)) or field < 0:
            errors.append(f"invalid_{key}")
    optional_types = {
        "batteryLevel": int,
        "thermalState": str,
        "lowPowerMode": bool,
        "powerMode": str,
        "cadenceMultiplier": (int, float),
    }
    for key, expected_type in optional_types.items():
        field = value.get(key)
        if field is not None and (not isinstance(field, expected_type) or (key != "lowPowerMode" and isinstance(field, bool))):
            errors.append(f"invalid_{key}")
    cadence = value.get("cadenceMultiplier")
    if cadence is not None and isinstance(cadence, (int, float)) and not isinstance(cadence, bool) and not math.isfinite(float(cadence)):
        errors.append("invalid_cadenceMultiplier")
    return errors

def reconstructed_segmented_journal(evidence):
    directory = evidence / "atria-active-session.segments"
    if not directory.exists():
        print("active_journal_segment_reconstruction_status=missing")
        return None, "missing"
    if (evidence / "atria-active-session.segments.partial").exists():
        print("active_journal_segment_reconstruction_status=invalid")
        print("active_journal_segment_integrity_status=partial_directory_copy")
        print("active_journal_torn_copy_status=detected")
        print("active_journal_torn_copy_reason=partial_directory_copy")
        print("active_journal_torn_copy_freshness=unknown")
        return None, "invalid"
    paths = sorted(directory.glob("*.json"))
    print(f"active_journal_segment_files={len(paths)}")
    if not paths:
        print("active_journal_segment_reconstruction_status=missing")
        return None, "missing"
    rows = []
    parse_error_files = []
    integrity_errors = []
    freshest_parsed_update = None
    segment_name = re.compile(r"segment-(\d{8})\.json$")
    for path in paths:
        try:
            segment = json.loads(path.read_text())
        except Exception as exc:
            parse_error_files.append(f"{path.name}:{type(exc).__name__}")
            continue
        if not isinstance(segment, dict):
            integrity_errors.append(f"{path.name}:not_object")
            continue
        if segment.get("updatedAt") is not None:
            candidate = segment.get("updatedAt")
            try:
                candidate_date = app_time(candidate)
                current_date = app_time(freshest_parsed_update) if freshest_parsed_update is not None else None
                if candidate_date is not None and (current_date is None or candidate_date > current_date):
                    freshest_parsed_update = candidate
            except Exception:
                pass
        match = segment_name.fullmatch(path.name)
        sequence = segment.get("sequence")
        if match is None:
            integrity_errors.append(f"{path.name}:unexpected_filename")
        elif not valid_nonnegative_integer(sequence) or sequence != int(match.group(1)):
            integrity_errors.append(f"{path.name}:filename_sequence_mismatch")
        if segment.get("schema") != 2:
            integrity_errors.append(f"{path.name}:schema_{segment.get('schema')}")
        if not isinstance(segment.get("id"), str) or not segment.get("id"):
            integrity_errors.append(f"{path.name}:missing_id")
        if not isinstance(segment.get("label"), str):
            integrity_errors.append(f"{path.name}:invalid_label")
        for key in ("startedAt", "updatedAt"):
            if not valid_journal_time(segment.get(key)):
                integrity_errors.append(f"{path.name}:invalid_{key}")
        for key in ("sampleStartIndex", "rrSampleStartIndex"):
            if not valid_nonnegative_integer(segment.get(key)):
                integrity_errors.append(f"{path.name}:invalid_{key}")
        if not valid_journal_samples(segment.get("samples")):
            integrity_errors.append(f"{path.name}:invalid_samples")
        if not valid_journal_samples(segment.get("rrSamples"), rr=True):
            integrity_errors.append(f"{path.name}:invalid_rrSamples")
        integrity_errors.extend(
            f"{path.name}:{error}" for error in journal_metadata_structure_errors(segment)
        )
        rows.append(segment)
    print(f"active_journal_segment_parse_errors={len(parse_error_files)}")
    print(f"active_journal_segment_parse_status={'ok' if not parse_error_files else 'error'}")
    if parse_error_files:
        print(f"active_journal_segment_parse_error_files={','.join(parse_error_files)}")
    print(f"active_journal_segment_structure_errors={len(integrity_errors)}")
    if integrity_errors:
        print(f"active_journal_segment_structure_error_details={','.join(integrity_errors)}")
    if parse_error_files or integrity_errors or len(rows) != len(paths):
        print("active_journal_segment_reconstruction_status=invalid")
        print("active_journal_segment_integrity_status=malformed_segments")
        print("active_journal_torn_copy_status=detected")
        print("active_journal_torn_copy_reason=malformed_segments")
        print(f"active_journal_torn_copy_freshness={active_journal_freshness(freshest_parsed_update)}")
        return None, "invalid"
    rows.sort(key=lambda row: row["sequence"])
    ids = {row["id"] for row in rows}
    mixed_ids = len(ids) != 1
    print(f"active_journal_segment_id_status={'mixed' if mixed_ids else 'ok'}")
    if mixed_ids:
        print(f"active_journal_segment_ids={','.join(sorted(ids))}")
    duplicate_sequences = len({row["sequence"] for row in rows}) != len(rows)
    sequence_gap = duplicate_sequences or any(
        current["sequence"] != previous["sequence"] + 1
        for previous, current in zip(rows, rows[1:])
    )
    print(f"active_journal_segment_sequence_status={'noncontiguous' if sequence_gap else 'ok'}")
    if sequence_gap:
        print("active_journal_segment_sequences=" + ",".join(str(row["sequence"]) for row in rows))
    if mixed_ids or sequence_gap:
        reasons = []
        if mixed_ids:
            reasons.append("mixed_journal_ids")
        if sequence_gap:
            reasons.append("noncontiguous_sequence")
        print("active_journal_segment_reconstruction_status=invalid")
        print("active_journal_segment_integrity_status=continuity_failure")
        print("active_journal_torn_copy_status=detected")
        print(f"active_journal_torn_copy_reason={'+'.join(reasons)}")
        print(f"active_journal_torn_copy_freshness={active_journal_freshness(freshest_parsed_update)}")
        return None, "invalid"
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
    sample_gap = False
    rr_gap = False
    for index, segment in enumerate(rows):
        sample_start = segment["sampleStartIndex"]
        rr_start = segment["rrSampleStartIndex"]
        is_replacement_base = sample_start == 0 and rr_start == 0
        if index == 0 and not is_replacement_base:
            sample_gap = sample_start != 0
            rr_gap = rr_start != 0
            break
        if index > 0 and is_replacement_base:
            journal["samples"] = []
            journal["rrSamples"] = []
        if sample_start != len(journal["samples"]):
            sample_gap = True
        if rr_start != len(journal["rrSamples"]):
            rr_gap = True
        if sample_gap or rr_gap:
            break
        journal["samples"].extend(segment["samples"])
        journal["rrSamples"].extend(segment["rrSamples"])
        for key in ("label", "updatedAt", "rawHRNotifications", "acceptedHRSamples", "zeroHRSamples",
                    "heldArtifacts", "droppedArtifacts", "rawHRGaps", "acceptedHRGaps",
                    "maxRawHRGap", "maxAcceptedHRGap", "batteryLevel", "thermalState",
                    "lowPowerMode", "powerMode", "cadenceMultiplier"):
            journal[key] = segment.get(key, journal.get(key))
    print(f"active_journal_segment_sample_continuity_status={'noncontiguous' if sample_gap else 'ok'}")
    print(f"active_journal_segment_rr_continuity_status={'noncontiguous' if rr_gap else 'ok'}")
    if sample_gap or rr_gap:
        reasons = []
        if sample_gap:
            reasons.append("sample_cursor_gap")
        if rr_gap:
            reasons.append("rr_cursor_gap")
        print("active_journal_segment_reconstruction_status=invalid")
        print("active_journal_segment_integrity_status=continuity_failure")
        print("active_journal_torn_copy_status=detected")
        print(f"active_journal_torn_copy_reason={'+'.join(reasons)}")
        print(f"active_journal_torn_copy_freshness={active_journal_freshness(freshest_parsed_update)}")
        return None, "invalid"
    print("active_journal_segment_reconstruction_status=ok")
    print("active_journal_segment_integrity_status=ok")
    print("active_journal_torn_copy_status=none")
    print(f"active_journal_segment_snapshot_freshness={active_journal_freshness(journal.get('updatedAt'))}")
    return journal, "ok"

def validated_flat_journal(path):
    if not path.exists():
        print("active_journal_snapshot_integrity_status=missing")
        return None, "missing"
    if path.with_name(path.name + ".partial").exists():
        print("active_journal_snapshot_integrity_status=partial_copy")
        print("active_journal_torn_copy_status=detected")
        print("active_journal_torn_copy_reason=partial_flat_snapshot")
        print("active_journal_torn_copy_freshness=unknown")
        return None, "invalid"
    try:
        value = json.loads(path.read_text())
    except Exception as exc:
        print(f"active_journal_file_summary_error={type(exc).__name__}:{exc}")
        print("active_journal_snapshot_integrity_status=parse_error")
        print("active_journal_torn_copy_status=detected")
        print("active_journal_torn_copy_reason=malformed_flat_snapshot")
        print("active_journal_torn_copy_freshness=unknown")
        return None, "invalid"
    valid = (
        isinstance(value, dict)
        and value.get("schema") == 1
        and isinstance(value.get("id"), str)
        and bool(value.get("id"))
        and isinstance(value.get("label"), str)
        and valid_journal_time(value.get("startedAt"))
        and valid_journal_time(value.get("updatedAt"))
        and valid_journal_samples(value.get("samples"))
        and (value.get("rrSamples") is None or valid_journal_samples(value.get("rrSamples"), rr=True))
        and not journal_metadata_structure_errors(value)
    )
    if not valid:
        print("active_journal_snapshot_integrity_status=invalid_structure")
        print("active_journal_torn_copy_status=detected")
        print("active_journal_torn_copy_reason=invalid_flat_snapshot_structure")
        print(f"active_journal_torn_copy_freshness={active_journal_freshness(value.get('updatedAt') if isinstance(value, dict) else None)}")
        return None, "invalid"
    print("active_journal_snapshot_integrity_status=ok")
    print(f"active_journal_snapshot_freshness={active_journal_freshness(value.get('updatedAt'))}")
    return value, "ok"

journal_path = evidence / "atria-active-session.json"
segmented_journal, segmented_status = reconstructed_segmented_journal(evidence)
flat_journal, flat_status = validated_flat_journal(journal_path)
journal = None
journal_integrity_status = "missing"
if segmented_status == "ok":
    journal = segmented_journal
    journal_integrity_status = "ok"
    print("active_journal_final_source=segmented_canonical")
elif segmented_status == "invalid":
    journal_integrity_status = "invalid"
    print("active_journal_final_source=invalid_segmented_canonical")
elif flat_status == "ok":
    journal = flat_journal
    journal_integrity_status = "ok"
    print("active_journal_final_source=flat_snapshot")
elif flat_status == "invalid":
    journal_integrity_status = "invalid"
    print("active_journal_final_source=invalid_flat_snapshot")
if journal is segmented_journal and journal is not None:
    if flat_status == "invalid":
        print("active_journal_redundant_flat_snapshot_status=invalid_ignored_segmented_authority_valid")
    try:
        journal_path.write_text(json.dumps(journal, indent=2, sort_keys=True))
        print("active_journal_reconstructed_from_segments=1")
    except Exception as exc:
        print(f"active_journal_reconstruct_write_error={type(exc).__name__}:{exc}")
if journal is not None and journal_integrity_status == "ok":
    print("active_journal_final_status=ok")
    try:
        prefs = {}
        prefs_path = evidence / "preferences.plist"
        if prefs_path.exists():
            try:
                with prefs_path.open("rb") as handle:
                    prefs = plistlib.load(handle)
            except Exception as exc:
                print(f"active_journal_preferences_error={type(exc).__name__}:{exc}")
        samples = journal.get("samples") or []
        rr = journal.get("rrSamples") or []
        started = app_time(journal.get("startedAt", samples[0].get("t") if samples else 0))
        updated = app_time(journal.get("updatedAt", samples[-1].get("t") if samples else 0))
        bpms = [int(sample.get("bpm", 0)) for sample in samples if sample.get("bpm") is not None]
        now = dt.datetime.now(dt.timezone.utc)
        link_connected = (pref(prefs, "link.lastStatus", "") == "connected")
        print(f"active_journal_schema={journal.get('schema')}")
        print(f"active_journal_label={journal.get('label', '')}")
        print(f"active_journal_samples={len(samples)}")
        print(f"active_journal_rr_values={len(rr)}")
        print(f"active_journal_rr_status={'rr_present' if rr else 'hr_only'}")
        print(f"active_journal_thermal_state={journal.get('thermalState') or 'missing'}")
        print(f"active_journal_low_power_mode={bool_int(journal.get('lowPowerMode'))}")
        print(f"active_journal_power_mode={journal.get('powerMode') or 'missing'}")
        print(f"active_journal_cadence_multiplier={float(journal.get('cadenceMultiplier') or -1):.2f}")
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
            if link_connected:
                continuity = "warming"
                continuity_reason = "fresh_connected_warming"
            else:
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
            backfill_reason = pref(prefs, "offlineSync.rangeLossBackfillReason", "") or ""
            stream_state = pref(prefs, "strapStream.state", "") or ""
            battery_level = int(pref(prefs, "strapStream.batteryLevel", -1) or -1)
            if backfill_reason == "strap_low_battery_broadcast_off" or (
                stream_state == "low_battery_shutoff" and battery_level >= 0 and battery_level <= 15
            ):
                interruption_class = "strap_low_battery_broadcast_off"
            else:
                interruption_class = "live_stream_interrupted_saved_sessions_present"
            print(f"active_journal_interruption_class={interruption_class}")
            print("file_durability_status=saved_sessions_preserved")
            print("live_stream_consistency_status=interrupted_not_file_loss")
        print(f"active_journal_duration_s={max(0, int((updated - started).total_seconds())) if started and updated else 0}")
        print(f"active_journal_peak_hr={max(bpms) if bpms else 0}")
        rr_window_audit("active_journal", rr, relative_times=False)
    except Exception as exc:
        print(f"active_journal_summary_error={type(exc).__name__}:{exc}")
else:
    print(f"active_journal_final_status={journal_integrity_status}")

def revision_hash(value):
    if value is None:
        return "missing"
    if isinstance(value, bytes):
        payload = value
    elif isinstance(value, str):
        payload = value.encode("utf-8")
    else:
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()

def emit_projection_artifact_revisions():
    prefs = {}
    prefs_path = evidence / "preferences.plist"
    if prefs_path.exists():
        try:
            with prefs_path.open("rb") as handle:
                prefs = plistlib.load(handle)
        except Exception as exc:
            print(f"analytics_preferences_revision_error={type(exc).__name__}:{exc}")

    identity_keys = []
    identity_path = evidence / "historical-archive.identity.jsonl"
    if identity_path.exists():
        try:
            with identity_path.open("r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    row = json.loads(line)
                    key = row.get("key") if isinstance(row, dict) else None
                    if isinstance(key, str) and key:
                        identity_keys.append(key)
        except Exception as exc:
            print(f"recovered_projection_revision_error={type(exc).__name__}:{exc}")
    unique_identity_keys = sorted(set(identity_keys))
    print(f"recovered_projection_evidence_revision={len(unique_identity_keys)}")
    print(f"recovered_projection_evidence_fingerprint={revision_hash(unique_identity_keys)}")

    sleeps = pref(prefs, "confirmedSleeps.v1") if prefs else None
    workouts = pref(prefs, "confirmedWorkouts.v1") if prefs else None
    print(f"sleep_projection_artifact_revision={revision_hash(sleeps)}")
    print(f"workout_projection_artifact_revision={revision_hash(workouts)}")

    rollups_path = evidence / "daily-rollups.json"
    strain_rows = None
    if rollups_path.exists():
        try:
            rollups = json.loads(rollups_path.read_text(encoding="utf-8"))
            if isinstance(rollups, list):
                strain_rows = [
                    {"day": row.get("day"), "strain": row.get("strain")}
                    for row in rollups
                    if isinstance(row, dict) and row.get("strain") is not None
                ]
        except Exception as exc:
            print(f"strain_projection_revision_error={type(exc).__name__}:{exc}")
    print(f"strain_projection_artifact_revision={revision_hash(strain_rows)}")
    print(f"strain_projection_artifact_days={len(strain_rows) if isinstance(strain_rows, list) else 0}")

    widget = None
    group_path = evidence / "app-group-preferences.plist"
    if group_path.exists():
        try:
            with group_path.open("rb") as handle:
                group_prefs = plistlib.load(handle)
            raw_widget = group_prefs.get("atria.widgetSnapshot.v1")
            if isinstance(raw_widget, bytes):
                widget = json.loads(raw_widget)
            elif isinstance(raw_widget, str):
                widget = json.loads(raw_widget)
        except Exception as exc:
            print(f"widget_projection_revision_error={type(exc).__name__}:{exc}")
    print(f"widget_projection_artifact_revision={revision_hash(widget)}")
    if isinstance(widget, dict):
        print("widget_projection_status=ok")
        print(f"widget_projection_created_at={widget.get('createdAt', 'missing')}")
        print(f"widget_projection_strain={widget.get('strain', 'missing')}")
        print(f"widget_projection_sleep_hours={widget.get('sleepHours', 'missing')}")
        print(f"widget_projection_storage={widget.get('storage', 'missing')}")
        print(f"widget_projection_app_group_enabled={bool_int(widget.get('appGroupEnabled'))}")
        print(f"widget_projection_target_present={bool_int(widget.get('widgetTargetPresent'))}")
    else:
        print("widget_projection_status=missing")

emit_projection_artifact_revisions()
PY
