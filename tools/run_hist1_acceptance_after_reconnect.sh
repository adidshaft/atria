#!/usr/bin/env bash
set -euo pipefail

device_id=${ATRIA_DEVICE_ID:-}
bundle_id=${ATRIA_BUNDLE_ID:-com.adidshaft.atria}
label="hist1-acceptance-$(date +%Y%m%d-%H%M%S)"
gap_start=""
reconnect=""
pull_time=""
timeline_points=180
marker=""
marker_start_pull_dir=""

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
  --timeline-points N
                     Visible point count from the proof card. Defaults to 180.

Outputs:
  docs/evidence/24-product-audit/<label>/pull-summary.txt
  artifacts/visual-checks/physical/<label>/heart-rate-timeline.png
  docs/evidence/24-product-audit/<label>/hist1-acceptance-verifier.txt
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
    --timeline-points)
      timeline_points=${2:?--timeline-points requires a value}
      shift 2
      ;;
    --from-marker)
      marker=${2:?--from-marker requires a value}
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
fi

if [[ -z "$reconnect" ]]; then
  reconnect=$(date -Iseconds)
fi

if [[ -z "$gap_start" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "$pull_time" ]]; then
  pull_time=$(date -Iseconds)
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

evidence_dir="docs/evidence/24-product-audit/$label"
screenshot_dir="artifacts/visual-checks/physical/$label"
screenshot="$screenshot_dir/heart-rate-timeline.png"
verifier="$evidence_dir/hist1-acceptance-verifier.txt"
metadata="$evidence_dir/hist1-acceptance-metadata.txt"

mkdir -p "$evidence_dir" "$screenshot_dir"

cat > "$metadata" <<EOF
label=$label
device_id=$device_id
bundle_id=$bundle_id
marker=$marker
start_pull_dir=$marker_start_pull_dir
gap_start=$gap_start
reconnect=$reconnect
pull_time=$pull_time
gap_seconds=$gap_seconds
timeline_points=$timeline_points
timeline_screenshot=$screenshot
verifier=$verifier
EOF

./pull_atria_state.sh \
  --device "$device_id" \
  --bundle-id "$bundle_id" \
  --evidence-dir "$evidence_dir"

xcrun devicectl device process launch \
  --device "$device_id" \
  --terminate-existing \
  --environment-variables '{"ATRIA_UI_SCREEN":"vitals","ATRIA_UI_FIXTURE":"heart-rate-timeline"}' \
  "$bundle_id" \
  --atria-ui-fixture heart-rate-timeline >/tmp/atria-hist1-acceptance-launch.log 2>&1

sleep 12

xcrun devicectl device capture screenshot \
  --device "$device_id" \
  --destination "$screenshot"

python3 tools/verify_hist1_acceptance.py \
  --pull-summary "$evidence_dir/pull-summary.txt" \
  --timeline-screenshot "$screenshot" \
  --timeline-points "$timeline_points" \
  --gap-start "$gap_start" \
  --reconnect "$reconnect" \
  --pull-time "$pull_time" | tee "$verifier"

printf 'hist1_acceptance_evidence_dir=%s\n' "$evidence_dir"
printf 'hist1_acceptance_screenshot=%s\n' "$screenshot"
printf 'hist1_acceptance_verifier=%s\n' "$verifier"
printf 'hist1_acceptance_metadata=%s\n' "$metadata"
