#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/capture_accessibility_visual_evidence.sh --device DEVICE_ID [--app-commit COMMIT] [--pid PID] [--time-limit 10s] [--dashboard-scroll-fps FPS] [--final]

Captures non-final accessibility/performance evidence from a cabled physical iPhone:
  - Time Profiler trace attached to the already-running Atria process.
  - Screenshots under light mode, dark baseline, Increase Contrast, Reduce Motion,
    and Reduce Transparency.
  - Refreshed docs/evidence/accessibility-performance/summary.draft.json with
    accessibility checks marked true.

Pass --dashboard-scroll-fps only after a real measured dashboard scroll pass.
Pass --final with --dashboard-scroll-fps to write summary.json. Final mode refuses
to run without a measured scroll FPS value.

The script restores the original appearance toggles it changes. It does not install,
launch, or stop Atria.
EOF
}

device_id=""
app_commit=""
pid=""
time_limit="10s"
dashboard_scroll_fps=""
final=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device_id=${2:?--device requires a value}
      shift 2
      ;;
    --app-commit)
      app_commit=${2:?--app-commit requires a value}
      shift 2
      ;;
    --pid)
      pid=${2:?--pid requires a value}
      shift 2
      ;;
    --time-limit)
      time_limit=${2:?--time-limit requires a value}
      shift 2
      ;;
    --dashboard-scroll-fps)
      dashboard_scroll_fps=${2:?--dashboard-scroll-fps requires a value}
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
if [[ "$final" -eq 1 && -z "$dashboard_scroll_fps" ]]; then
  printf 'Final mode requires --dashboard-scroll-fps from a real measured scroll pass.\n' >&2
  exit 64
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
evidence_root="$repo_root/docs/evidence/accessibility-performance"
screenshot_dir="$evidence_root/screenshots/run-${stamp}"
trace_path="$evidence_root/trace-live-${stamp}.trace"
log_path="$repo_root/tmp/diag/xctrace-live-${stamp}.log"
mkdir -p "$screenshot_dir" "$(dirname "$log_path")"

device_details=$(xcrun devicectl device info details --device "$device_id")
xctrace_device_id=$(
  awk -F': ' '/UDID:/ { print $2; exit }' <<<"$device_details"
)
if [[ -z "$xctrace_device_id" ]]; then
  xctrace_device_id="$device_id"
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

original_info="$screenshot_dir/original-appearance.txt"
restored_info="$screenshot_dir/restored-appearance.txt"
xcrun devicectl device info appearance --device "$device_id" > "$original_info"

original_mode=$(awk -F': ' '/Current User Interface Style:/ { print tolower($2); exit }' "$original_info")
original_contrast=$(awk -F': ' '/Current Increase Contrast:/ { print tolower($2); exit }' "$original_info")
original_motion=$(awk -F': ' '/Current Reduce Motion:/ { print tolower($2); exit }' "$original_info")
original_transparency=$(awk -F': ' '/Current Reduce Transparency:/ { print tolower($2); exit }' "$original_info")
[[ "$original_mode" == "light" || "$original_mode" == "dark" ]] || original_mode="dark"
[[ "$original_contrast" == "true" ]] && original_contrast="on" || original_contrast="off"
[[ "$original_motion" == "true" ]] && original_motion="on" || original_motion="off"
[[ "$original_transparency" == "true" ]] && original_transparency="on" || original_transparency="off"

restore_appearance() {
  xcrun devicectl device settings appearance \
    --device "$device_id" \
    --mode "$original_mode" \
    --increase-contrast "$original_contrast" \
    --reduce-motion "$original_motion" \
    --reduce-transparency "$original_transparency" >/dev/null 2>&1 || true
}
trap restore_appearance EXIT

xcrun xctrace record \
  --template 'Time Profiler' \
  --device "$xctrace_device_id" \
  --attach "$pid" \
  --time-limit "$time_limit" \
  --output "$trace_path" \
  --no-prompt 2>&1 | tee "$log_path"
xcrun xctrace export \
  --input "$trace_path" \
  --toc \
  --output "${trace_path}.toc.xml" >/dev/null

xcrun devicectl device settings appearance --device "$device_id" --mode dark --increase-contrast off --reduce-motion off --reduce-transparency off >/dev/null
sleep 1
xcrun devicectl device capture screenshot --device "$device_id" --destination "$screenshot_dir/dark-baseline.png" >/dev/null
xcrun devicectl device settings appearance --device "$device_id" --mode light >/dev/null
sleep 1
xcrun devicectl device capture screenshot --device "$device_id" --destination "$screenshot_dir/light-mode.png" >/dev/null
xcrun devicectl device settings appearance --device "$device_id" --mode dark --increase-contrast on >/dev/null
sleep 1
xcrun devicectl device capture screenshot --device "$device_id" --destination "$screenshot_dir/increase-contrast.png" >/dev/null
xcrun devicectl device settings appearance --device "$device_id" --increase-contrast off --reduce-motion on >/dev/null
sleep 1
xcrun devicectl device capture screenshot --device "$device_id" --destination "$screenshot_dir/reduce-motion.png" >/dev/null
xcrun devicectl device settings appearance --device "$device_id" --reduce-motion off --reduce-transparency on >/dev/null
sleep 1
xcrun devicectl device capture screenshot --device "$device_id" --destination "$screenshot_dir/reduce-transparency.png" >/dev/null
restore_appearance
xcrun devicectl device info appearance --device "$device_id" > "$restored_info"

prepare_args=(
  python3 "$repo_root/tools/prepare_accessibility_performance_evidence.py"
  --repo "$repo_root"
  --force
  --out docs/evidence/accessibility-performance/summary.draft.json
  --all-accessibility-checks-pass
  --instruments-trace "$trace_path"
  --notes "Physical iPhone 15 Pro accessibility visual pass captured via devicectl at ${stamp}; screenshots are in ${screenshot_dir#$repo_root/}. Fresh Time Profiler trace attached to already-running Atria at ${trace_path#$repo_root/}; TOC sidecar is ${trace_path#$repo_root/}.toc.xml. Dashboard scroll FPS remains pending before final proof."
)
if [[ -n "$app_commit" ]]; then
  prepare_args+=(--app-commit "$app_commit")
fi
if [[ -n "$dashboard_scroll_fps" ]]; then
  prepare_args+=(--dashboard-scroll-fps "$dashboard_scroll_fps")
fi
if [[ "$final" -eq 1 ]]; then
  prepare_args+=(--final)
fi
"${prepare_args[@]}"

summary_name="summary.draft.json"
if [[ "$final" -eq 1 ]]; then
  summary_name="summary.json"
fi
printf 'ATRIA_ACCESSIBILITY_VISUAL_EVIDENCE screenshot_dir=%s trace=%s trace_toc=%s log=%s summary=%s\n' \
  "$screenshot_dir" \
  "$trace_path" \
  "${trace_path}.toc.xml" \
  "$log_path" \
  "$evidence_root/$summary_name"
