#!/usr/bin/env bash
# Pull the paired iPhone's crash/resource reports for Atria, then symbolicate
# them with the archived dSYM whose UUID matches each report.
#
#   ATRIA_DEVICE_ID=<devicectl id> bash pull_crashlogs.sh [label]
#
# Output (private, never committed — reports carry device identifiers):
#   ~/atria-validation/crashlogs/<date>-<label>/            raw .ips/.tailspin
#   ~/atria-validation/crashlogs/<date>-<label>/symbolicated/<report>.sym.txt
#   ~/atria-validation/crashlogs/<date>-<label>/SUMMARY.txt  counts by type/build
#
# dSYMs live at ~/atria-validation/dsyms/<UUID>/Atria.app.dSYM. For an Xcode
# Cloud build: Xcode > Report navigator > Cloud > Build N > Archive - iOS >
# Artifacts > "Archive for Atria on iOS", then copy its dSYMs/ there.
set -euo pipefail
DEVICE="${ATRIA_DEVICE_ID:?set ATRIA_DEVICE_ID to the paired iPhone (xcrun devicectl list devices)}"
LABEL="${1:-pull}"
OUT="$HOME/atria-validation/crashlogs/$(date +%Y-%m-%d)-$LABEL"
STAGE="$(mktemp -d)"
DSYMS="$HOME/atria-validation/dsyms"
SYMBOLICATE="$(cd "$(dirname "$0")" && pwd)/symbolicate_atria_reports.py"
mkdir -p "$OUT"

xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs \
  --source / --destination "$STAGE" >/dev/null
find "$STAGE" -type f \( -name 'Atria*' -o -name '*-Atria-*' \) -exec cp -n {} "$OUT"/ \;
rm -rf "$STAGE"

summary="$OUT/SUMMARY.txt"
: > "$summary"
for f in "$OUT"/*.ips; do
  [ -e "$f" ] || continue
  head -1 "$f" | python3 -I -c '
import json, sys, os
h = json.loads(sys.stdin.readline())
print(os.path.basename(sys.argv[1]), h.get("bug_type"), h.get("build_version"), h.get("slice_uuid", "").upper())
' "$f" >> "$summary" || true
done
echo "reports by build/bug_type:"; awk '{print "build " $3 " bug_type " $2}' "$summary" | sort | uniq -c

for uuid in $(awk '{print $4}' "$summary" | sort -u); do
  dwarf="$DSYMS/$uuid/Atria.app.dSYM/Contents/Resources/DWARF/Atria"
  reports=$(awk -v u="$uuid" '$4 == u {print $1}' "$summary")
  if [ -f "$dwarf" ] && [ -f "$SYMBOLICATE" ]; then
    (cd "$OUT" && python3 -I "$SYMBOLICATE" "$dwarf" symbolicated $reports)
  else
    echo "no dSYM archived for $uuid — download it before ranking fixes" >&2
  fi
done
echo "saved to $OUT"
