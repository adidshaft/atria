#!/usr/bin/env bash
set -euo pipefail

device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
bundle_id=${ATRIA_BUNDLE_ID:-com.adidshaft.atria}
label="hist1-acceptance-$(date +%Y%m%d-%H%M%S)"
gap_start=""
reconnect=""
pull_time=""
marker=""
marker_start_pull_dir=""
pre_pull_summary=""

usage() {
  cat <<'EOF'
Usage:
  tools/run_hist1_acceptance_after_reconnect.sh --gap-start ISO --reconnect ISO [options]
  tools/run_hist1_acceptance_after_reconnect.sh --from-marker PATH [options]

Run this after the deliberate HIST-1 phone-away gap and reconnect.

Required:
  --gap-start ISO    Timestamp when the phone-away gap started, with timezone offset.
  --reconnect ISO    Timestamp when phone/strap reconnected, with timezone offset.
  --from-marker PATH Read gap_start from tools/start_hist1_phone_away_gap.sh output.

Options:
  --device ID        Physical iPhone CoreDevice id. Defaults to ATRIA_DEVICE_ID.
  --bundle-id ID     Bundle id. Defaults to com.adidshaft.atria.
  --label NAME       Evidence label. Defaults to hist1-acceptance-<local timestamp>.
  --pull-time ISO    Timestamp for the post-reconnect pull. Defaults to current local time.
  --pre-pull-summary PATH
                     Required pre-gap pull summary when not using --from-marker.

Outputs:
  logs/live-device/<label>/pull-summary.txt
  artifacts/visual-checks/physical/<label>/heart-rate-timeline.png
  logs/live-device/<label>/hist1-acceptance-verifier.txt
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
    --gap-start)
      gap_start=${2:?--gap-start requires a value}
      shift 2
      ;;
    --reconnect)
      reconnect=${2:?--reconnect requires a value}
      shift 2
      ;;
    --pull-time)
      pull_time=${2:?--pull-time requires a value}
      shift 2
      ;;
    --from-marker)
      marker=${2:?--from-marker requires a value}
      shift 2
      ;;
    --pre-pull-summary)
      pre_pull_summary=${2:?--pre-pull-summary requires a value}
      shift 2
      ;;
    --label)
      label=${2:?--label requires a value}
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

if [[ -n "$marker" ]]; then
  if [[ ! -f "$marker" ]]; then
    printf 'Missing marker: %s\n' "$marker" >&2
    exit 2
  fi
  gap_start=$(awk -F= '$1 == "gap_start" { print $2; exit }' "$marker")
  marker_device_id=$(awk -F= '$1 == "device_id" { print $2; exit }' "$marker")
  marker_bundle_id=$(awk -F= '$1 == "bundle_id" { print $2; exit }' "$marker")
  marker_start_pull_dir=$(awk -F= '$1 == "start_pull_dir" { print $2; exit }' "$marker")
  if [[ -n "$marker_device_id" ]]; then
    device_id=$marker_device_id
  fi
  if [[ -n "$marker_bundle_id" ]]; then
    bundle_id=$marker_bundle_id
  fi
  if [[ -n "$marker_start_pull_dir" ]]; then
    pre_pull_summary="$marker_start_pull_dir/pull-summary.txt"
  fi
fi

if [[ -z "$gap_start" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "$pre_pull_summary" || ! -f "$pre_pull_summary" ]]; then
  printf 'Missing required pre-gap pull summary: %s\n' "${pre_pull_summary:-not_provided}" >&2
  printf 'Start the gap with tools/start_hist1_phone_away_gap.sh, or pass --pre-pull-summary.\n' >&2
  exit 2
fi

evidence_dir="logs/live-device/$label"
screenshot_dir="artifacts/visual-checks/physical/$label"
screenshot="$screenshot_dir/heart-rate-timeline.png"
verifier="$evidence_dir/hist1-acceptance-verifier.txt"
metadata="$evidence_dir/hist1-acceptance-metadata.txt"
recovery_log="$evidence_dir/post-reconnect-recovery.log"
# Keep the live console file beside (not inside) the still-empty pull target.
# Once the state pull has claimed `evidence_dir`, renaming this open file into
# it is safe: the detached writer continues through its existing file
# descriptor, and an interrupted harness leaves the partial console evidence
# at this deterministic sibling path rather than deleting it.
recovery_log_capture="${evidence_dir}-post-reconnect-recovery.log"
# Keep the small pre-launch runtime checkpoint as a sibling.
# `pull_atria_state.sh` deliberately refuses a nonempty destination, and the
# final acceptance pull owns `evidence_dir` itself.
pre_relaunch_dir="${evidence_dir}-pre-relaunch"

for reserved_path in \
  "$evidence_dir" \
  "$screenshot_dir" \
  "$recovery_log_capture" \
  "$pre_relaunch_dir"; do
  if [[ -e "$reserved_path" ]]; then
    printf 'Acceptance evidence path already exists: %s\n' "$reserved_path" >&2
    exit 73
  fi
done
mkdir -p "$evidence_dir" "$screenshot_dir"

# Preserve the exact resident state before the acceptance launch terminates the
# app. A directory copy can overlap an atomic segment rotation, so take another
# non-disruptive snapshot when the pull detects a torn chain. Never relaunch the
# resident app until one checkpoint is structurally coherent and provenance-
# bound; otherwise the very act of testing could destroy tonight's best proof.
if [[ -e "$pre_relaunch_dir" ]]; then
  printf 'Pre-relaunch evidence path already exists: %s\n' "$pre_relaunch_dir" >&2
  exit 73
fi
pre_relaunch_ready=0
for checkpoint_attempt in 1 2 3; do
  checkpoint_dir="${pre_relaunch_dir}.attempt-${checkpoint_attempt}"
  if [[ -e "$checkpoint_dir" ]]; then
    printf 'Checkpoint evidence path already exists: %s\n' "$checkpoint_dir" >&2
    exit 73
  fi
  ./pull_atria_state.sh \
    --device "$device_id" \
    --bundle-id "$bundle_id" \
    --runtime-only \
    --installed-provenance-only \
    --evidence-dir "$checkpoint_dir"
  checkpoint_summary="$checkpoint_dir/pull-summary.txt"
  checkpoint_journal=$(awk -F= '$1 == "active_journal_final_status" { value=$2 } END { print value }' "$checkpoint_summary")
  checkpoint_process=$(awk -F= '$1 == "process_status" { value=$2 } END { print value }' "$checkpoint_summary")
  checkpoint_provenance=$(awk -F= '$1 == "app_provenance_status" { value=$2 } END { print value }' "$checkpoint_summary")
  if [[ "$checkpoint_journal" == "ok" && \
        "$checkpoint_process" == "running" && \
        "$checkpoint_provenance" == "pass" ]]; then
    mv "$checkpoint_dir" "$pre_relaunch_dir"
    pre_relaunch_ready=1
    break
  fi
  if (( checkpoint_attempt < 3 )); then
    # Preserve an incoherent attempt for forensic diagnosis. The next attempt
    # uses a distinct path, so no cleanup is needed and no evidence is erased.
    sleep 1
  else
    mv "$checkpoint_dir" "$pre_relaunch_dir"
  fi
done
if (( pre_relaunch_ready == 0 )); then
  printf 'Refusing to relaunch: no lossless resident checkpoint after 3 attempts.\n' >&2
  printf 'Inspect: %s/pull-summary.txt\n' "$pre_relaunch_dir" >&2
  exit 1
fi

# When the caller did not observe and pass an exact reconnect timestamp, bind
# the recovery interval to the last instant before this script itself
# terminates/relaunches the resident app. Taking this timestamp before the
# runtime checkpoint would silently omit the final checkpoint minutes from the
# coverage proof.
if [[ -z "$reconnect" ]]; then
  reconnect=$(date -Iseconds)
fi

gap_seconds=$(python3 - "$gap_start" "$reconnect" <<'PY'
import sys
from datetime import datetime, timezone

def parse(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise SystemExit(f"{value!r} must include a timezone offset")
    return parsed.astimezone(timezone.utc)

gap_start = parse(sys.argv[1])
reconnect = parse(sys.argv[2])
print(int((reconnect - gap_start).total_seconds()))
PY
)
if (( gap_seconds < 3600 )); then
  printf 'HIST-1 gap is too short: %ss; need at least 3600s.\n' "$gap_seconds" >&2
  exit 2
fi

if [[ -e "$recovery_log_capture" ]]; then
  printf 'Detached console evidence path already exists: %s\n' "$recovery_log_capture" >&2
  exit 73
fi

# `devicectl process launch --console` forwards every catchable signal it
# receives to the device application. Do not make it a shell background child:
# an EXIT trap, terminal hangup, or process-group interrupt could otherwise
# become an app signal and invalidate the recovery transaction. The tiny
# launcher below creates a new POSIX session, disconnects stdin, and writes
# to the deterministic sibling capture file. `devicectl` owns the bounded
# 240-second console lifetime and abandons the command at its own timeout; the
# acceptance harness never signals, waits on, or otherwise controls the remote
# app through the console process.
console_pid=$(python3 - \
  "$device_id" "$bundle_id" "$recovery_log_capture" <<'PY'
import subprocess
import sys

device_id, bundle_id, recovery_log = sys.argv[1:]
with open(recovery_log, "wb", buffering=0) as log:
    process = subprocess.Popen(
        [
            "/usr/bin/xcrun", "devicectl", "device", "process", "launch",
            "--device", device_id,
            "--terminate-existing",
            "--console",
            "--timeout", "240",
            "--environment-variables",
            '{"ATRIA_UI_SCREEN":"vitals","ATRIA_UI_FIXTURE":"heart-rate-timeline"}',
            bundle_id,
            "--atria-ui-fixture", "heart-rate-timeline",
        ],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
print(process.pid)
PY
)

cleanup_console() {
  # Intentionally empty. In particular, never kill/wait here: devicectl's
  # --console contract forwards catchable signals to the iPhone application.
  # The detached capture exits on its own --timeout and owns no temp files.
  :
}
trap cleanup_console EXIT

# The device-side recovery transaction has a 180-second bound. Wait for its
# explicit completion marker, rather than assuming a large strap backlog drains
# within a fixed 35 seconds. Always allow a short stabilization window even if
# this reconnect has no pending offline range.
for attempt in $(seq 1 42); do
  sleep 5
  if (( attempt >= 7 )) && grep -q 'ATRIADBG offline_sync status=complete ' "$recovery_log_capture"; then
    break
  fi
done

./pull_atria_state.sh \
  --device "$device_id" \
  --bundle-id "$bundle_id" \
  --full-archive \
  --installed-provenance-only \
  --evidence-dir "$evidence_dir"

# This is a same-filesystem rename of an open regular file. It neither signals
# nor waits for devicectl; subsequent console bytes continue into the evidence
# file until devicectl reaches its own timeout.
mv "$recovery_log_capture" "$recovery_log"

# Freshness is measured at completion of the full state snapshot. Recording it
# before a slow archive copy could make a stale/torn acceptance pull appear to
# have completed within the recovery deadline.
if [[ -z "$pull_time" ]]; then
  pull_time=$(date -Iseconds)
fi

cat > "$metadata" <<EOF
label=$label
device_id=$device_id
bundle_id=$bundle_id
marker=$marker
start_pull_dir=$marker_start_pull_dir
pre_pull_summary=$pre_pull_summary
pre_relaunch_pull_summary=$pre_relaunch_dir/pull-summary.txt
gap_start=$gap_start
reconnect=$reconnect
pull_time=$pull_time
gap_seconds=$gap_seconds
recovery_log=$recovery_log
console_capture_pid=$console_pid
console_capture_lifecycle=detached_new_session_natural_devicectl_timeout
timeline_screenshot=$screenshot
verifier=$verifier
EOF

xcrun devicectl device capture screenshot \
  --device "$device_id" \
  --destination "$screenshot"

python3 tools/verify_hist1_acceptance.py \
  --pull-summary "$evidence_dir/pull-summary.txt" \
  --pre-pull-summary "$pre_pull_summary" \
  --pre-relaunch-pull-summary "$pre_relaunch_dir/pull-summary.txt" \
  --recovery-log "$recovery_log" \
  --timeline-screenshot "$screenshot" \
  --gap-start "$gap_start" \
  --reconnect "$reconnect" \
  --pull-time "$pull_time" | tee "$verifier"

cleanup_console
trap - EXIT

printf 'hist1_acceptance_evidence_dir=%s\n' "$evidence_dir"
printf 'hist1_acceptance_screenshot=%s\n' "$screenshot"
printf 'hist1_acceptance_verifier=%s\n' "$verifier"
printf 'hist1_acceptance_metadata=%s\n' "$metadata"
