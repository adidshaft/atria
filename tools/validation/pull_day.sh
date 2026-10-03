#!/usr/bin/env bash
# Pull what Atria stores on the phone into ~/atria-validation/<stamp>/ (never
# into the repo: it is personal health data). Metric validation plan, §2.
# Usage: ATRIA_DEVICE_ID=<CoreDevice id> tools/validation/pull_day.sh [label]
set -euo pipefail
device=${ATRIA_DEVICE_ID:?Set ATRIA_DEVICE_ID to your iPhone CoreDevice identifier (xcrun devicectl list devices)}
label=${1:-$(date +%Y%m%dT%H%M%S)}
out="${ATRIA_VALIDATION_DIR:-$HOME/atria-validation}/$label"
mkdir -p "$out"
bundle=com.adidshaft.atria
pull() { xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
  --domain-identifier "$bundle" --source "$1" --destination "$out/$2" >/dev/null && echo "pulled $2"; }
backup=$(xcrun devicectl device info files --device "$device" --domain-type appDataContainer \
  --domain-identifier "$bundle" 2>/dev/null | grep -o 'Documents/atria-backups/atria-sessions-[^ ]*\.json\.gz' | sort | tail -1)
[ -n "$backup" ] || { echo "no session backup found on the phone" >&2; exit 1; }
pull "$backup" sessions-backup.deflate
pull "Library/Application Support/atria-strap-step-ledger.json" step-ledger.json || true
pull "Library/Preferences/$bundle.plist" prefs.plist || true
python3 "$(dirname "$0")/atria_export.py" "$out/sessions-backup.deflate" "$out"
echo "$out"
