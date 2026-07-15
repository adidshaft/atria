#!/bin/zsh
# Copy-only pull + strict R10 coverage verdict for the newest saved workout
# route window. Usage: tools/check_latest_workout_coverage.sh [label]
set -e
cd "$(dirname "$0")/.."
label="${1:-postgym}"
pull_dir="logs/live-device/${label}-$(date -u +%Y%m%dT%H%M%SZ)"
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  ./pull_atria_state.sh --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --evidence-dir "$pull_dir" | tail -2
route=$(ls "$pull_dir/authoritative-runtime-state/atria-workout-routes" | sort | tail -1)
start_ms="$(echo "$route" | cut -d- -f1)000"
end_ms="$(echo "$route" | cut -d- -f2)000"
echo "pull: $pull_dir"
echo "route: $route  window: ${start_ms}..${end_ms}"
if [ ! -x /tmp/replay_step_calibration ]; then
  swiftc -O tools/replay_step_calibration.swift Atria/Atria/AtriaR10Motion.swift \
    Atria/Atria/FrameParser.swift -o /tmp/replay_step_calibration
fi
/tmp/replay_step_calibration "$pull_dir/atria-step-calibration" \
  "$start_ms" "$end_ms" | grep -E "coverage|continuity|scoreable|raw_steps" | head -4
/usr/libexec/PlistBuddy -c print /dev/null 2>/dev/null || true
python3 - "$pull_dir" <<'PY'
import plistlib, sys, datetime
p = plistlib.load(open(sys.argv[1] + "/preferences.plist", "rb"))
for k in sorted(p):
    if "workoutMotion" in k:
        v = p[k]
        if isinstance(v, float) and v > 1e9:
            v = f"{v:.0f} ({datetime.datetime.fromtimestamp(v).strftime('%H:%M:%S')} IST)"
        print(k, "=", v)
PY
