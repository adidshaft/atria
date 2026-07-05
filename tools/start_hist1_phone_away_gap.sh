#!/usr/bin/env bash
set -euo pipefail

device_id=${ATRIA_DEVICE_ID:-}
bundle_id=${ATRIA_BUNDLE_ID:-com.adidshaft.atria}
label="hist1-phone-away-gap"
preflight_pull=0

usage() {
  cat <<'EOF'
Usage:
  tools/start_hist1_phone_away_gap.sh [--label NAME] [--device ID] [--bundle-id ID] [--preflight-pull]

Records the timestamp for the deliberate HIST-1 phone-away gap.

Options:
  --preflight-pull  Capture pull_atria_state.sh into the marker folder before the gap.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      label=${2:?--label requires a value}
      shift 2
      ;;
    --device)
      device_id=${2:?--device requires a value}
      shift 2
      ;;
    --bundle-id)
      bundle_id=${2:?--bundle-id requires a value}
      shift 2
      ;;
    --preflight-pull)
      preflight_pull=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$label" == "hist1-phone-away-gap" ]]; then
        label=$1
        shift
      else
        printf 'Unknown argument: %s\n\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

evidence_dir="docs/evidence/24-product-audit/$label"
marker="$evidence_dir/gap-start.txt"
start_pull_dir="$evidence_dir/start-state-pull"

mkdir -p "$evidence_dir"
gap_start=$(date -Iseconds)

if (( preflight_pull == 1 )); then
  ./pull_atria_state.sh \
    --device "$device_id" \
    --bundle-id "$bundle_id" \
    --evidence-dir "$start_pull_dir"
fi

cat > "$marker" <<EOF
gap_start=$gap_start
device_id=$device_id
bundle_id=$bundle_id
preflight_pull=$preflight_pull
start_pull_dir=$start_pull_dir
instruction=Keep phone away from the strap for at least 60 minutes, then reconnect and run tools/run_hist1_acceptance_after_reconnect.sh --from-marker $marker
EOF

printf 'hist1_gap_marker=%s\n' "$marker"
printf 'gap_start=%s\n' "$gap_start"
printf 'device_id=%s\n' "$device_id"
printf 'bundle_id=%s\n' "$bundle_id"
printf 'preflight_pull=%s\n' "$preflight_pull"
if (( preflight_pull == 1 )); then
  printf 'start_pull_dir=%s\n' "$start_pull_dir"
fi
