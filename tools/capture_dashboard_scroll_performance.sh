#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/capture_dashboard_scroll_performance.sh --device DEVICE_ID [--pid PID] [--attach-name NAME] [--app-commit COMMIT] [--duration 12] [--countdown 5] [--xctrace-stop-grace 45] [--auto-scroll] [--bundle-id ID] [--measured-fps FPS] [--measured-fps-source PATH] [--verified-accessibility-check CHECK]... [--final]

Captures physical-device dashboard scroll evidence without installing Atria. By default
it attaches to the already-running process; --auto-scroll launches the DEBUG fixture:
  - Combined SwiftUI/Core Animation FPS/Hitches/Time Profiler trace attached to
    the already-running Atria process.
  - Device screen recording covering the scroll window.

During the countdown, put Atria's Today dashboard on screen. During the capture
window, manually scroll the dashboard continuously. Pass --auto-scroll to launch the
DEBUG dashboard-autoscroll fixture and generate a repeatable on-device scroll workload.
This script exports the Core Animation FPS table and uses the measured max FPS.
--measured-fps remains available only as an explicit override after reading trace/video
evidence; final override runs must also pass --measured-fps-source PATH.
Final mode requires measured FPS from the trace or override and writes summary.json through
prepare_accessibility_performance_evidence.py. This performance helper never infers
accessibility success. Repeat --verified-accessibility-check only for checks already
observed on the physical Release build: light_mode, dark_mode, increase_contrast,
reduce_transparency, and reduce_motion.
EOF
}

device_id=""
pid=""
app_commit=""
duration="12"
countdown="5"
measured_fps=""
measured_fps_source=""
verified_accessibility_checks=()
final=0
xctrace_stop_grace="45"
attach_name="Atria"
bundle_id=${ATRIA_BUNDLE_ID:-com.adidshaft.atria}
auto_scroll=0

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
    --attach-name)
      attach_name=${2:?--attach-name requires a value}
      shift 2
      ;;
    --bundle-id)
      bundle_id=${2:?--bundle-id requires a value}
      shift 2
      ;;
    --auto-scroll)
      auto_scroll=1
      shift
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
    --measured-fps-source)
      measured_fps_source=${2:?--measured-fps-source requires a value}
      shift 2
      ;;
    --verified-accessibility-check)
      check=${2:?--verified-accessibility-check requires a value}
      case "$check" in
        light_mode|dark_mode|increase_contrast|reduce_transparency|reduce_motion)
          verified_accessibility_checks+=("$check")
          ;;
        *)
          printf 'Unknown accessibility check: %s\n' "$check" >&2
          exit 64
          ;;
      esac
      shift 2
      ;;
    --final)
      final=1
      shift
      ;;
    --xctrace-stop-grace)
      xctrace_stop_grace=${2:?--xctrace-stop-grace requires a value}
      shift 2
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
if [[ "$final" -eq 1 && -n "$measured_fps" ]]; then
  if [[ -z "$measured_fps_source" ]]; then
    printf 'Final measured FPS override requires --measured-fps-source PATH.\n' >&2
    exit 64
  fi
  if [[ ! -e "$measured_fps_source" ]]; then
    printf 'Final measured FPS source does not exist: %s\n' "$measured_fps_source" >&2
    exit 64
  fi
fi
if [[ "$final" -eq 1 ]]; then
  missing_accessibility_checks=()
  for required_check in light_mode dark_mode increase_contrast reduce_transparency reduce_motion; do
    check_is_verified=0
    if [[ "${#verified_accessibility_checks[@]}" -gt 0 ]]; then
      for verified_check in "${verified_accessibility_checks[@]}"; do
        if [[ "$verified_check" == "$required_check" ]]; then
          check_is_verified=1
          break
        fi
      done
    fi
    if [[ "$check_is_verified" -ne 1 ]]; then
      missing_accessibility_checks+=("$required_check")
    fi
  done
  if [[ "${#missing_accessibility_checks[@]}" -gt 0 ]]; then
    printf 'Final mode requires explicitly verified physical accessibility checks; missing=%s\n' \
      "$(IFS=,; printf '%s' "${missing_accessibility_checks[*]}")" >&2
    exit 64
  fi
fi
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
evidence_root="$repo_root/docs/evidence/accessibility-performance/dashboard-scroll-${stamp}"
log_root="$repo_root/tmp/diag/dashboard-scroll-${stamp}"
mkdir -p "$evidence_root" "$log_root"

device_details=$(xcrun devicectl device info details --device "$device_id")
xctrace_device_name=$(
  awk -F': ' '/Device Name:/ { print $2; exit }' <<<"$device_details"
)
xctrace_device_id=$(
  awk -F': ' '/UDID:/ { print $2; exit }' <<<"$device_details"
)
if [[ -n "$xctrace_device_name" ]]; then
  xctrace_device_id="$xctrace_device_name"
elif [[ -z "$xctrace_device_id" ]]; then
  xctrace_device_id="$device_id"
fi

if [[ "$auto_scroll" -eq 1 ]]; then
  xcrun devicectl device process launch \
    --device "$device_id" \
    --terminate-existing \
    --environment-variables '{"ATRIA_UI_SCREEN":"today","ATRIA_UI_FIXTURE":"dashboard-autoscroll","ATRIA_DASHBOARD_AUTOSCROLL":"1"}' \
    "$bundle_id" \
    --atria-ui-screen today \
    --atria-ui-fixture dashboard-autoscroll >"$log_root/autoscroll-launch.log" 2>&1 || {
      printf 'Failed to launch dashboard-autoscroll fixture. See %s\n' "$log_root/autoscroll-launch.log" >&2
      exit 65
    }
  sleep 3
fi

if [[ -z "$pid" ]]; then
  pid=$(
    xcrun devicectl device info processes --device "$device_id" |
      awk 'index($0, "/Atria.app/Atria") && !index($0, "/PlugIns/") { print $1; exit }'
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
xctrace_stop_grace_int=$(printf '%.0f' "$xctrace_stop_grace")
if [[ "$xctrace_stop_grace_int" -lt 5 ]]; then
  printf 'xctrace stop grace must be at least 5 seconds.\n' >&2
  exit 64
fi
existing_xctrace=$(
  ps -axo pid=,command= |
    awk '/xctrace record/ && $1 != "'"$$"'" && $0 !~ /awk .*xctrace record/ { print $1 ":" substr($0, index($0,$2)); exit }'
)
if [[ -n "$existing_xctrace" ]]; then
  printf 'Another xctrace record process is already running: %s\n' "$existing_xctrace" >&2
  printf 'Stop stale Instruments captures before starting dashboard scroll proof.\n' >&2
  exit 67
fi

if [[ "$auto_scroll" -eq 1 ]]; then
  interaction_text="DEBUG dashboard-autoscroll fixture; manual scrolling not required."
else
  interaction_text="manual continuous Today dashboard scroll during capture window"
fi

wait_with_timeout() {
  local pid_to_wait=$1
  local timeout_s=$2
  local label=$3
  local elapsed=0
  while kill -0 "$pid_to_wait" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$timeout_s" ]]; then
      printf '%s did not finish after %ss; terminating pid %s.\n' "$label" "$timeout_s" "$pid_to_wait"
      kill "$pid_to_wait" >/dev/null 2>&1 || true
      sleep 2
      if kill -0 "$pid_to_wait" >/dev/null 2>&1; then
        kill -9 "$pid_to_wait" >/dev/null 2>&1 || true
      fi
      wait "$pid_to_wait" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid_to_wait"
}

cat > "$evidence_root/README.md" <<EOF
# Dashboard Scroll Performance Capture

- Captured at: ${stamp}
- Device: ${device_id}
- Atria PID: ${pid}
- xctrace fallback attach name: ${attach_name:-disabled}
- Duration seconds: ${duration_int}
- xctrace stop grace seconds: ${xctrace_stop_grace_int}
- Auto-scroll fixture: ${auto_scroll}
- App commit: ${app_commit:-pending}
- Interaction: ${interaction_text}

Artifacts:
- \`dashboard-scroll.trace\`
- \`screen-recording.mp4\` when CoreDevice screen recording is available
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
  --device "$xctrace_device_id" \
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

if ! wait_with_timeout "$xctrace_pid" "$((duration_int + xctrace_stop_grace_int))" "xctrace"; then
  if [[ -e "$evidence_root/dashboard-scroll.trace" ]]; then
    printf 'xctrace reported run issues but saved the trace; continuing. See %s\n' "$log_root/xctrace.log"
    printf '\nxctrace reported run issues while stopping, but dashboard-scroll.trace was saved.\n' >> "$evidence_root/README.md"
  elif [[ -n "$attach_name" ]] && grep -q "Cannot find process for provided pid" "$log_root/xctrace.log"; then
    printf 'xctrace could not resolve CoreDevice pid %s; retrying attach by process name %s.\n' "$pid" "$attach_name"
    printf '\nPID attach failed; retried xctrace with --attach %s. See xctrace-name-attach.log.\n' "$attach_name" >> "$evidence_root/README.md"
    xcrun xctrace record \
      --template 'SwiftUI' \
      --instrument 'Core Animation FPS' \
      --instrument 'Hitches' \
      --instrument 'Time Profiler' \
      --device "$xctrace_device_id" \
      --attach "$attach_name" \
      --time-limit "${duration_int}s" \
      --output "$evidence_root/dashboard-scroll.trace" \
      --no-prompt >"$log_root/xctrace-name-attach.log" 2>&1 &
    xctrace_name_pid=$!
    if ! wait_with_timeout "$xctrace_name_pid" "$((duration_int + xctrace_stop_grace_int))" "xctrace name attach"; then
      if [[ -e "$evidence_root/dashboard-scroll.trace" ]]; then
        printf 'xctrace name attach reported run issues but saved the trace; continuing. See %s\n' "$log_root/xctrace-name-attach.log"
        printf '\nxctrace name attach reported run issues while stopping, but dashboard-scroll.trace was saved.\n' >> "$evidence_root/README.md"
      else
        printf 'xctrace failed by pid and by name without saving dashboard-scroll.trace. See %s and %s\n' "$log_root/xctrace.log" "$log_root/xctrace-name-attach.log" >&2
        exit 66
      fi
    fi
  else
    printf 'xctrace failed and did not save dashboard-scroll.trace. See %s\n' "$log_root/xctrace.log" >&2
    exit 66
  fi
fi
if ! wait "$recording_pid"; then
  printf 'Screen recording unavailable; continuing with Instruments trace only. See %s\n' "$log_root/screen-recording.log"
  printf '\nScreen recording unavailable on this CoreDevice path; Instruments trace remains the required artifact.\n' >> "$evidence_root/README.md"
fi

xcrun xctrace export \
  --input "$evidence_root/dashboard-scroll.trace" \
  --toc \
  --output "$evidence_root/dashboard-scroll.trace.toc.xml" \
  >"$log_root/xctrace-export-toc.log" 2>&1 || true
xcrun xctrace export \
  --input "$evidence_root/dashboard-scroll.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="core-animation-fps-estimate"]' \
  --output "$evidence_root/dashboard-scroll.fps.xml" \
  >"$log_root/xctrace-export-fps.log" 2>&1 || true

extracted_fps=""
if [[ -s "$evidence_root/dashboard-scroll.fps.xml" ]]; then
  extracted_fps=$(
    python3 - "$evidence_root/dashboard-scroll.fps.xml" "$evidence_root/dashboard-scroll.fps.txt" <<'PY'
import re
import statistics
import sys
from pathlib import Path

xml_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
xml = xml_path.read_text(encoding="utf-8", errors="replace")
values: list[float] = []
by_id: dict[str, float] = {}
for row in re.findall(r"<row>(.*?)</row>", xml, flags=re.S):
    direct = re.search(r'<fps id="(\d+)"[^>]*>([0-9.]+)</fps>', row)
    if direct:
        value = float(direct.group(2))
        by_id[direct.group(1)] = value
        values.append(value)
        continue
    ref = re.search(r'<fps ref="(\d+)"\s*/>', row)
    if ref and ref.group(1) in by_id:
        values.append(by_id[ref.group(1)])

if not values:
    out_path.write_text("fps_status=missing\n", encoding="utf-8")
    print("")
else:
    fps_max = max(values)
    fps_mean = statistics.mean(values)
    status = "zero" if fps_max <= 0 else "ok"
    out_path.write_text(
        f"fps_status={status}\n"
        + "fps_values=" + ",".join(f"{value:g}" for value in values) + "\n"
        + f"fps_max={fps_max:g}\n"
        + f"fps_mean={fps_mean:.2f}\n",
        encoding="utf-8",
    )
    print(f"{fps_max:g}")
PY
  )
fi
if [[ -n "$extracted_fps" ]]; then
  printf '\nExtracted Core Animation FPS max: %s\n' "$extracted_fps" >> "$evidence_root/README.md"
  if [[ "$extracted_fps" == "0" || "$extracted_fps" == "0.0" || "$extracted_fps" == "0.00" ]]; then
    printf 'FPS table exported, but all rows were zero; this is not accepted VIS-1 scroll evidence.\n' >> "$evidence_root/README.md"
  fi
fi

if [[ -s "$evidence_root/screen-recording.mp4" ]] && command -v ffprobe >/dev/null 2>&1; then
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
  --instruments-trace "$evidence_root/dashboard-scroll.trace"
  --notes "Physical iPhone 15 Pro dashboard scroll capture ${stamp}; combined SwiftUI/Core Animation FPS/Hitches/Time Profiler trace artifacts are in ${evidence_root#$repo_root/}. Screen recording is optional and may be unavailable on this CoreDevice path. Accessibility checks are included only when explicitly supplied as already verified physical observations. Use --measured-fps only after reading the trace evidence."
)
if [[ "${#verified_accessibility_checks[@]}" -gt 0 ]]; then
  for check in "${verified_accessibility_checks[@]}"; do
    prepare_args+=(--pass-check "$check")
  done
fi
if [[ -n "$app_commit" ]]; then
  prepare_args+=(--app-commit "$app_commit")
fi
fps_for_summary="${measured_fps:-$extracted_fps}"
if [[ -n "$fps_for_summary" ]]; then
  prepare_args+=(--dashboard-scroll-fps "$fps_for_summary")
fi
if [[ "$final" -eq 1 && -n "$measured_fps" ]]; then
  measured_fps_source_copy="$evidence_root/measured-fps-source$(basename "$measured_fps_source" | sed 's/^[^.]*//')"
  cp "$measured_fps_source" "$measured_fps_source_copy"
  printf '\nMeasured FPS override source: %s\n' "$measured_fps_source" >> "$evidence_root/README.md"
  printf 'Measured FPS override source copy: %s\n' "$measured_fps_source_copy" >> "$evidence_root/README.md"
fi
if [[ "$final" -eq 1 && -z "$fps_for_summary" ]]; then
  printf 'Final mode requires measured FPS from the xctrace FPS table or --measured-fps override.\n' >&2
  exit 64
fi
if [[ "$final" -eq 1 && -n "$fps_for_summary" ]]; then
  if ! python3 - "$fps_for_summary" <<'PY'
import sys
value = float(sys.argv[1])
if value < 58:
    raise SystemExit(1)
PY
  then
    printf 'Final mode requires measured FPS >= 58; got %s.\n' "$fps_for_summary" >&2
    exit 64
  fi
fi
if [[ "$final" -eq 1 ]]; then
  prepare_args+=(--final)
fi
"${prepare_args[@]}"

printf 'ATRIA_DASHBOARD_SCROLL_PERFORMANCE evidence=%s logs=%s summary=%s measured_fps=%s\n' \
  "$evidence_root" \
  "$log_root" \
  "$repo_root/$summary_out" \
  "${fps_for_summary:-pending}"
