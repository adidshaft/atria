#!/bin/bash
# Build → verify → install → launch Atria on the physical iPhone with HARD
# STOPS. Exists because xcodebuild piped through grep returns grep's exit
# code, which shipped a stale binary twice on 2026-08-05 (handoff §15.18,
# §15.28) — the build "succeeded" only in the pipe's imagination.
#
# Usage: scripts/ship-device.sh [--no-launch]
set -euo pipefail

DEVICE="${ATRIA_DEVICE_ID:-}"
if [[ -z "$DEVICE" ]]; then
  echo "Set ATRIA_DEVICE_ID to the devicectl identifier of the target iPhone." >&2
  exit 2
fi
BUNDLE="com.adidshaft.atria"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/Atria/build-device"
APP="$DERIVED/Build/Products/Release-iphoneos/Atria.app"
LOG="$(mktemp "${TMPDIR:-/tmp}/atria-ship.XXXXXX")"

cd "$ROOT/Atria"
echo "building…"
if ! xcodebuild -project Atria.xcodeproj -scheme Atria \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates build \
    > "$LOG" 2>&1; then
  echo "BUILD FAILED — errors:" >&2
  grep -E "error:" "$LOG" | head -12 >&2
  exit 1
fi
grep -q "\*\* BUILD SUCCEEDED \*\*" "$LOG" || {
  echo "BUILD did not report SUCCEEDED — refusing to install" >&2
  exit 1
}
echo "installing…"
xcrun devicectl device install app --device "$DEVICE" "$APP"
if [[ "${1:-}" != "--no-launch" ]]; then
  echo "launching…"
  xcrun devicectl device process launch --terminate-existing \
    --device "$DEVICE" "$BUNDLE"
fi
echo "shipped $(git -C "$ROOT" rev-parse --short HEAD)"
