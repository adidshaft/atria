#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
helper="$repo_root/tools/v4_morning_acceptance.py"
pull_script=${ATRIA_PULL_SCRIPT:-"$repo_root/pull_atria_state.sh"}
python_cmd=${ATRIA_PYTHON:-python3}
codesign_cmd=${ATRIA_CODESIGN:-codesign}
phase=""
device_id=""
bundle_id=""
candidate_app=""
candidate_sha256=""
candidate_binary_relative="Atria.debug.dylib"
evidence_root=""
dry_run=0
monitor_seconds=1800
poll_seconds=10
minimum_compactions=2

usage() {
  cat <<'EOF'
Usage:
  tools/run_v4_morning_acceptance.sh PHASE --device ID --bundle-id ID \
    --app /absolute/Atria.app --candidate-sha256 SHA256 \
    --evidence-root /absolute/new-evidence-root [options]

Phases:
  prepare   Verify candidate; runtime-only + full pulls; fail-closed gates; pre metadata.
  install   Install in place; prove data/app-group continuity and bundle rotation.
  launch    Refuse a running app; detached launch with step-calibration argument.
  monitor   Require >=2 clean journal compactions and take a post-runtime pull.
  all       Run all four phases in order.

Options:
  --candidate-binary-relative PATH  Hashed file inside .app (default Atria.debug.dylib).
  --monitor-seconds N               Monitor deadline (default 1800).
  --poll-seconds N                  Console scan interval (default 10).
  --minimum-compactions N           Must be >=2 (default 2).
  --dry-run                         Validate local inputs and print actions only.
EOF
}

if [[ $# -gt 0 ]]; then phase=$1; shift; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device_id=${2:?--device requires a value}; shift 2 ;;
    --bundle-id) bundle_id=${2:?--bundle-id requires a value}; shift 2 ;;
    --app) candidate_app=${2:?--app requires a value}; shift 2 ;;
    --candidate-sha256) candidate_sha256=${2:?--candidate-sha256 requires a value}; shift 2 ;;
    --candidate-binary-relative) candidate_binary_relative=${2:?requires a value}; shift 2 ;;
    --evidence-root) evidence_root=${2:?--evidence-root requires a value}; shift 2 ;;
    --monitor-seconds) monitor_seconds=${2:?requires a value}; shift 2 ;;
    --poll-seconds) poll_seconds=${2:?requires a value}; shift 2 ;;
    --minimum-compactions) minimum_compactions=${2:?requires a value}; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$phase" in prepare|install|launch|monitor|all) ;; *) usage >&2; exit 2 ;; esac
for required in "$device_id" "$bundle_id" "$candidate_app" "$candidate_sha256" "$evidence_root"; do
  if [[ -z "$required" ]]; then usage >&2; exit 2; fi
done
case "$candidate_sha256" in *[!0-9a-fA-F]*|'') printf 'Candidate SHA-256 must be exactly 64 hex digits.\n' >&2; exit 2 ;; esac
if [[ ${#candidate_sha256} -ne 64 ]]; then
  printf 'Candidate SHA-256 must be exactly 64 hex digits.\n' >&2
  exit 2
fi
candidate_sha256=$(printf '%s' "$candidate_sha256" | tr '[:upper:]' '[:lower:]')
if [[ "$candidate_app" != /* || "$evidence_root" != /* ]]; then
  printf -- '--app and --evidence-root must be absolute paths.\n' >&2
  exit 2
fi
if [[ ! -d "$candidate_app" || ! -f "$candidate_app/Info.plist" ]]; then
  printf 'Candidate app is missing or malformed: %s\n' "$candidate_app" >&2
  exit 66
fi
candidate_binary="$candidate_app/$candidate_binary_relative"
if [[ ! -f "$candidate_binary" ]]; then
  printf 'Candidate binary is missing: %s\n' "$candidate_binary" >&2
  exit 66
fi
for integer in "$monitor_seconds" "$poll_seconds" "$minimum_compactions"; do
  case "$integer" in *[!0-9]*|'') printf 'Monitor options must be nonnegative integers.\n' >&2; exit 2 ;; esac
done
if (( minimum_compactions < 2 || poll_seconds < 1 )); then
  printf 'minimum-compactions must be >=2 and poll-seconds must be >=1.\n' >&2
  exit 2
fi
actual_sha=$(shasum -a 256 "$candidate_binary" | awk '{print $1}')
if [[ "$actual_sha" != "$candidate_sha256" ]]; then
  printf 'Candidate SHA mismatch: expected %s, found %s\n' "$candidate_sha256" "$actual_sha" >&2
  exit 1
fi
"$python_cmd" - "$candidate_app/Info.plist" "$bundle_id" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    actual = plistlib.load(handle).get("CFBundleIdentifier")
if actual != sys.argv[2]:
    raise SystemExit(f"candidate bundle id mismatch: {actual!r} != {sys.argv[2]!r}")
PY

group_id="group.$bundle_id"
context="$evidence_root/context.json"
print_plan() {
  printf 'dry_run=1\nphase=%s\ndevice_id=%s\nbundle_id=%s\napp=%s\n' "$phase" "$device_id" "$bundle_id" "$candidate_app"
  printf 'candidate_binary=%s\ncandidate_sha256=%s\nevidence_root=%s\n' "$candidate_binary" "$candidate_sha256" "$evidence_root"
  case "$phase" in
    prepare) printf 'planned=local_codesign,runtime_pull,full_pull,summary_gates,pre_metadata\n' ;;
    install) printf 'planned=require_prepare,in_place_install,post_metadata,container_continuity_gate\n' ;;
    launch) printf 'planned=require_install,refuse_running,detached_console_launch,process_gate\n' ;;
    monitor) printf 'planned=require_launch,console_compaction_gate,post_runtime_pull,manifest\n' ;;
    all) printf 'planned=prepare,install,launch,monitor\n' ;;
  esac
}
if (( dry_run == 1 )); then
  if [[ "$phase" == "prepare" || "$phase" == "all" ]]; then
    if [[ -e "$evidence_root" ]]; then
      printf 'Dry-run refusal: prepare evidence root already exists: %s\n' "$evidence_root" >&2
      exit 73
    fi
  fi
  print_plan
  exit 0
fi
if [[ ! -x "$pull_script" && ! -f "$pull_script" ]]; then
  printf 'Missing pull script: %s\n' "$pull_script" >&2
  exit 69
fi
if [[ -n "${ATRIA_DEVICETCL:-}" ]]; then
  devicectl_cmd=("$ATRIA_DEVICETCL")
  detached_prefix="$ATRIA_DEVICETCL"
  detached_mode="direct"
elif xcrun --find devicectl >/dev/null 2>&1; then
  devicectl_cmd=(xcrun devicectl)
  detached_prefix="/usr/bin/xcrun"
  detached_mode="xcrun"
else
  printf 'Unable to find devicectl.\n' >&2
  exit 69
fi

write_context() {
  "$python_cmd" - "$context" "$device_id" "$bundle_id" "$group_id" "$candidate_app" "$candidate_binary_relative" "$candidate_sha256" <<'PY'
import json, sys
from pathlib import Path
value = {"schema":"atria.v4-morning-acceptance.v1", "device_id":sys.argv[2], "bundle_id":sys.argv[3],
         "app_group_id":sys.argv[4], "candidate_app":sys.argv[5],
         "candidate_binary_relative":sys.argv[6], "candidate_sha256":sys.argv[7]}
Path(sys.argv[1]).write_text(json.dumps(value, indent=2, sort_keys=True)+"\n", encoding="utf-8")
PY
}
check_context() {
  if [[ ! -f "$context" ]]; then printf 'Missing acceptance context: %s\n' "$context" >&2; exit 1; fi
  "$python_cmd" - "$context" "$device_id" "$bundle_id" "$group_id" "$candidate_app" "$candidate_binary_relative" "$candidate_sha256" <<'PY'
import json, sys
value=json.load(open(sys.argv[1], encoding="utf-8"))
expected={"schema":"atria.v4-morning-acceptance.v1", "device_id":sys.argv[2], "bundle_id":sys.argv[3],
          "app_group_id":sys.argv[4], "candidate_app":sys.argv[5],
          "candidate_binary_relative":sys.argv[6], "candidate_sha256":sys.argv[7]}
if value != expected: raise SystemExit(f"acceptance context mismatch: {value!r} != {expected!r}")
PY
}
phase_done() {
  local receipt="$evidence_root/$1/phase-complete.json"
  local expected=${1#*-}
  [[ -f "$receipt" ]] || return 1
  "$python_cmd" - "$receipt" "$expected" <<'PY' >/dev/null 2>&1
import json, sys
try:
    value=json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if value.get("phase") != sys.argv[2] or value.get("status") != "pass":
    raise SystemExit(1)
PY
}
complete_phase() {
  "$python_cmd" - "$1/phase-complete.json" "$2" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path
path=Path(sys.argv[1])
temporary=path.with_name(path.name+".partial")
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump({"phase":sys.argv[2], "status":"pass", "completed_at":datetime.now(timezone.utc).isoformat()}, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
directory_fd=os.open(path.parent, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}
require_clean_phase_dir() {
  local directory=$1 name=$2
  if phase_done "$name"; then return 1; fi
  if [[ -e "$directory" ]]; then
    printf 'Incomplete phase evidence exists; preserving it and refusing overwrite: %s\n' "$directory" >&2
    exit 73
  fi
  mkdir -p "$directory"
  return 0
}
capture_metadata() {
  "${devicectl_cmd[@]}" device info apps --device "$device_id" --bundle-id "$bundle_id" \
    --require-container-access --include-container-paths --include-app-group-identifiers \
    --json-output "$1" > "$2" 2>&1
}

run_prepare() {
  if [[ ! -e "$evidence_root" ]]; then mkdir -p "$evidence_root"; write_context; else check_context; fi
  local directory="$evidence_root/01-prepare"
  if ! require_clean_phase_dir "$directory" "01-prepare"; then printf 'phase=prepare status=already_complete\n'; return; fi
  "$codesign_cmd" --verify --deep --strict "$candidate_app" > "$directory/codesign-verification.txt" 2>&1
  printf '%s  %s\n' "$candidate_sha256" "$candidate_binary_relative" > "$directory/candidate-binary.sha256"
  "$pull_script" --device "$device_id" --bundle-id "$bundle_id" --runtime-only --installed-provenance-only \
    --evidence-dir "$directory/runtime-only"
  "$python_cmd" "$helper" check-summary --summary "$directory/runtime-only/pull-summary.txt" --profile runtime \
    > "$directory/runtime-only-acceptance.txt"
  "$pull_script" --device "$device_id" --bundle-id "$bundle_id" --installed-provenance-only \
    --evidence-dir "$directory/full"
  "$python_cmd" "$helper" check-summary --summary "$directory/full/pull-summary.txt" --profile full \
    > "$directory/full-acceptance.txt"
  "$python_cmd" "$helper" manifest --root "$directory/full" --output "$directory/full/evidence.sha256" \
    > "$directory/full-manifest.txt"
  capture_metadata "$directory/pre-installed-app-metadata.json" "$directory/pre-installed-app-metadata.log"
  "$python_cmd" "$helper" extract-metadata --source "$directory/pre-installed-app-metadata.json" \
    --bundle-id "$bundle_id" --group-id "$group_id" --output "$directory/pre-container-identity.json" \
    > "$directory/pre-container-identity.txt"
  awk -F= '$1 == "active_journal_samples" { value=$2 } END { print value }' \
    "$directory/runtime-only/pull-summary.txt" > "$directory/pre-install-journal-samples.txt"
  complete_phase "$directory" "prepare"
  printf 'phase=prepare status=pass evidence=%s\n' "$directory"
}

run_install() {
  check_context
  if ! phase_done "01-prepare"; then printf 'Install requires a completed prepare phase.\n' >&2; exit 1; fi
  local directory="$evidence_root/02-install"
  if ! require_clean_phase_dir "$directory" "02-install"; then printf 'phase=install status=already_complete\n'; return; fi
  "$codesign_cmd" --verify --deep --strict "$candidate_app" > "$directory/codesign-verification.txt" 2>&1
  local rechecked_sha
  rechecked_sha=$(shasum -a 256 "$candidate_binary" | awk '{print $1}')
  if [[ "$rechecked_sha" != "$candidate_sha256" ]]; then printf 'Candidate changed after prepare.\n' >&2; exit 1; fi
  # This is the only install operation. There is no uninstall/delete command.
  "${devicectl_cmd[@]}" device install app --device "$device_id" --json-output "$directory/install-result.json" \
    "$candidate_app" > "$directory/install.log" 2>&1
  capture_metadata "$directory/post-installed-app-metadata.json" "$directory/post-installed-app-metadata.log"
  "$python_cmd" "$helper" extract-metadata --source "$directory/post-installed-app-metadata.json" \
    --bundle-id "$bundle_id" --group-id "$group_id" --output "$directory/post-container-identity.json" \
    > "$directory/post-container-identity.txt"
  "$python_cmd" "$helper" compare-metadata --before "$evidence_root/01-prepare/pre-container-identity.json" \
    --after "$directory/post-container-identity.json" > "$directory/container-continuity.txt"
  complete_phase "$directory" "install"
  printf 'phase=install status=pass evidence=%s\n' "$directory"
}

run_launch() {
  check_context
  if ! phase_done "02-install"; then printf 'Launch requires a completed install phase.\n' >&2; exit 1; fi
  local directory="$evidence_root/03-launch"
  if ! require_clean_phase_dir "$directory" "03-launch"; then printf 'phase=launch status=already_complete\n'; return; fi
  "${devicectl_cmd[@]}" device info processes --device "$device_id" > "$directory/processes-before.txt" 2>&1
  if grep -E -q "${bundle_id//./\\.}|/Atria\\.app/Atria([[:space:]]|$)" "$directory/processes-before.txt"; then
    printf 'Refusing launch: Atria is already running after install. No process was terminated.\n' >&2
    exit 1
  fi
  local console_log="$directory/device-console.log" console_pid
  console_pid=$("$python_cmd" - "$detached_prefix" "$detached_mode" "$device_id" "$bundle_id" "$console_log" <<'PY'
import subprocess, sys
prefix, mode, device, bundle, log_path = sys.argv[1:]
command = ([prefix] if mode == "direct" else [prefix, "devicectl"])
command += ["device", "process", "launch", "--device", device, "--console", "--timeout", "21600",
            bundle, "--atria-enable-step-calibration"]
with open(log_path, "xb", buffering=0) as log:
    process=subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                             start_new_session=True, close_fds=True)
print(process.pid)
PY
  )
  printf '%s\n' "$console_pid" > "$directory/console.pid"
  printf 'console_capture_lifecycle=detached_new_posix_session_natural_devicectl_timeout\n' > "$directory/console-lifecycle.txt"
  printf 'console_signal_policy=never_signal_never_wait\n' >> "$directory/console-lifecycle.txt"
  sleep "${ATRIA_LAUNCH_SETTLE_SECONDS:-10}"
  "${devicectl_cmd[@]}" device info processes --device "$device_id" > "$directory/processes-after.txt" 2>&1
  if ! grep -E -q "${bundle_id//./\\.}|/Atria\\.app/Atria([[:space:]]|$)" "$directory/processes-after.txt"; then
    printf 'Detached launch did not produce a running Atria process; console remains untouched.\n' >&2
    exit 1
  fi
  complete_phase "$directory" "launch"
  printf 'phase=launch status=pass console_pid=%s evidence=%s\n' "$console_pid" "$directory"
}

run_monitor() {
  check_context
  if ! phase_done "03-launch"; then printf 'Monitor requires a completed launch phase.\n' >&2; exit 1; fi
  local directory="$evidence_root/04-monitor"
  if ! require_clean_phase_dir "$directory" "04-monitor"; then printf 'phase=monitor status=already_complete\n'; return; fi
  local console="$evidence_root/03-launch/device-console.log" minimum_restored
  minimum_restored=$(tr -d '[:space:]' < "$evidence_root/01-prepare/pre-install-journal-samples.txt")
  case "$minimum_restored" in *[!0-9]*|'') printf 'Invalid pre-install sample count.\n' >&2; exit 1 ;; esac
  local deadline=$((SECONDS + monitor_seconds))
  while true; do
    set +e
    "$python_cmd" "$helper" scan-console --console "$console" --minimum-compactions "$minimum_compactions" \
      --minimum-restored "$minimum_restored" > "$directory/journal-monitor.latest.txt" \
      2> "$directory/journal-monitor.latest.err"
    local scan_status=$?
    set -e
    if (( scan_status == 0 )); then
      mv "$directory/journal-monitor.latest.txt" "$directory/journal-monitor.txt"
      mv "$directory/journal-monitor.latest.err" "$directory/journal-monitor.err"
      break
    fi
    if grep -E -q 'journal failure marker|sample-count regression' "$directory/journal-monitor.latest.err"; then
      cat "$directory/journal-monitor.latest.err" >&2
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      printf 'Journal monitor deadline expired without two accepted compactions.\n' >&2
      cat "$directory/journal-monitor.latest.err" >&2
      exit 1
    fi
    sleep "$poll_seconds"
  done
  "$pull_script" --device "$device_id" --bundle-id "$bundle_id" --runtime-only --installed-provenance-only \
    --evidence-dir "$directory/post-monitor-runtime"
  "$python_cmd" "$helper" check-summary --summary "$directory/post-monitor-runtime/pull-summary.txt" \
    --profile runtime > "$directory/post-monitor-runtime-acceptance.txt"
  # Hash the completed checks before publishing success. The detached console
  # log is outside this directory and remains intentionally open/growing. The
  # atomic pass receipt below is the phase's final durable action and is omitted
  # from its own prerequisite evidence manifest by design.
  "$python_cmd" "$helper" manifest --root "$directory" --output "$directory/evidence.sha256"
  complete_phase "$directory" "monitor"
  printf 'phase=monitor status=pass evidence=%s\n' "$directory"
}

case "$phase" in
  prepare) run_prepare ;;
  install) run_install ;;
  launch) run_launch ;;
  monitor) run_monitor ;;
  all) run_prepare; run_install; run_launch; run_monitor ;;
esac
