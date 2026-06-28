#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/capture_dashboard_scroll_performance.sh --device DEVICE_ID [--pid PID] [--app-commit COMMIT] [--duration 12] [--countdown 5] [--measured-fps FPS] [--final]

Captures physical-device dashboard scroll evidence without installing, launching,
or terminating Atria:
  - Combined SwiftUI/Core Animation FPS/Hitches/Time Profiler trace attached to
    the already-running Atria process.
  - Device screen recording covering the scroll window.

During the countdown, put Atria's Today dashboard on screen. During the capture
window, manually scroll the dashboard continuously. This script does not fake
the FPS value: pass --measured-fps only after reading the trace/video evidence.
Final mode requires --measured-fps and writes summary.json through
prepare_accessibility_performance_evidence.py.
EOF
}

device_id=""
pid=""
app_commit=""
duration="12"
countdown="5"
measured_fps=""
final=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device_id=${2:?--device requires a value}
      shift 2
      ;;
    --pid)
      pid=${2:?--pid requires a value}
      shift 2
      ;;
    --app-commit)
      app_commit=${2:?--app-commit requires a value}
      shift 2
      ;;
    --duration)
      duration=${2:?--duration requires a value}
      shift 2
      ;;
    --countdown)
      countdown=${2:?--countdown requires a value}
      shift 2
      ;;
    --measured-fps)
      measured_fps=${2:?--measured-fps requires a value}
      shift 2
      ;;
    --final)
      final=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$device_id" ]]; then
  printf 'Missing --device.\n' >&2
  usage >&2
  exit 64
fi
if [[ "$final" -eq 1 && -z "$measured_fps" ]]; then
  printf 'Final mode requires --measured-fps from a real dashboard scroll pass.\n' >&2
  exit 64
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
evidence_root="$repo_root/docs/evidence/accessibility-performance/dashboard-scroll-${stamp}"
log_root="$repo_root/tmp/diag/dashboard-scroll-${stamp}"
mkdir -p "$evidence_root" "$log_root"

if [[ -z "$pid" ]]; then
  pid=$(
    xcrun devicectl device info processes --device "$device_id" |
      awk '/Atria[.]app\\/Atria$/ { print $1; exit }'
  )
fi
if [[ -z "$pid" ]]; then
  printf 'Could not find a running Atria.app/Atria process on device %s.\n' "$device_id" >&2
  exit 65
fi

duration_int=$(printf '%.0f' "$duration")
countdown_int=$(printf '%.0f' "$countdown")
if [[ "$duration_int" -le 0 || "$countdown_int" -lt 0 ]]; then
  printf 'Duration must be positive and countdown must be non-negative.\n' >&2
  exit 64
fi

cat > "$evidence_root/README.md" <<EOF
# Dashboard Scroll Performance Capture

- Captured at: ${stamp}
- Device: ${device_id}
- Atria PID: ${pid}
- Duration seconds: ${duration_int}
- App commit: ${app_commit:-pending}
- Interaction: manual continuous Today dashboard scroll during capture window

Artifacts:
- \`dashboard-scroll.trace\`
- \`screen-recording.mp4\`
EOF

printf 'Prepare Atria Today dashboard on the iPhone. Scroll continuously when capture starts.\n'
for ((remaining = countdown_int; remaining > 0; remaining--)); do
  printf 'Starting dashboard scroll capture in %ss...\n' "$remaining"
  sleep 1
done
printf 'Capture started. Scroll now for %ss.\n' "$duration_int"

xcrun xctrace record \
  --template 'SwiftUI' \
  --instrument 'Core Animation FPS' \
  --instrument 'Hitches' \
  --instrument 'Time Profiler' \
  --device "$device_id" \
  --attach "$pid" \
  --time-limit "${duration_int}s" \
  --output "$evidence_root/dashboard-scroll.trace" \
  --no-prompt >"$log_root/xctrace.log" 2>&1 &
xctrace_pid=$!

xcrun devicectl device capture screen-record \
  --device "$device_id" \
  --destination "$evidence_root/screen-recording.mp4" \
  --duration "$duration_int" \
  --codec h264 >"$log_root/screen-recording.log" 2>&1 &
recording_pid=$!

wait "$xctrace_pid"
wait "$recording_pid"

xcrun xctrace export --input "$evidence_root/dashboard-scroll.trace" --toc --output "$evidence_root/dashboard-scroll.trace.toc.xml" >/dev/null

if command -v ffprobe >/dev/null 2>&1; then
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=avg_frame_rate,r_frame_rate,nb_frames,duration \
    -of default=nw=1 \
    "$evidence_root/screen-recording.mp4" > "$evidence_root/screen-recording.ffprobe.txt" || true
fi

summary_out="docs/evidence/accessibility-performance/summary.draft.json"
if [[ "$final" -eq 1 ]]; then
  summary_out="docs/evidence/accessibility-performance/summary.json"
fi
prepare_args=(
  python3 "$repo_root/tools/prepare_accessibility_performance_evidence.py"
  --repo "$repo_root"
  --force
  --out "$summary_out"
  --all-accessibility-checks-pass
  --instruments-trace "$evidence_root/dashboard-scroll.trace"
  --notes "Physical iPhone 15 Pro dashboard scroll capture ${stamp}; combined SwiftUI/Core Animation FPS/Hitches/Time Profiler trace and screen recording artifacts are in ${evidence_root#$repo_root/}. Use --measured-fps only after reading the trace/video evidence."
)
if [[ -n "$app_commit" ]]; then
  prepare_args+=(--app-commit "$app_commit")
fi
if [[ -n "$measured_fps" ]]; then
  prepare_args+=(--dashboard-scroll-fps "$measured_fps")
fi
if [[ "$final" -eq 1 ]]; then
  prepare_args+=(--final)
fi
"${prepare_args[@]}"

printf 'ATRIA_DASHBOARD_SCROLL_PERFORMANCE evidence=%s logs=%s summary=%s measured_fps=%s\n' \
  "$evidence_root" \
  "$log_root" \
  "$repo_root/$summary_out" \
  "${measured_fps:-pending}"
