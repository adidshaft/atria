#!/usr/bin/env bash
set -euo pipefail

device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
bundle_id=${ATRIA_BUNDLE_ID:-${WHOOP_BUNDLE_ID:-com.adidshaft.atria}}
process_search=${ATRIA_APP_PROCESS_SEARCH:-${WHOOP_APP_PROCESS_SEARCH:-Atria}}
kill_mode=0

if [[ -z "$device_id" ]]; then
  printf 'Set ATRIA_DEVICE_ID to your physical iPhone CoreDevice identifier.\n' >&2
  exit 64
fi

usage() {
  cat <<'EOF'
Usage:
  ./force_quit_ios_app.sh [--device DEVICE_ID] [--bundle-id BUNDLE_ID] [--search TEXT] [--kill]

Finds a running app process on the physical iPhone with devicectl JSON output,
then terminates it by PID. This is the safe prep step before Mac-side BLE probes,
because the iOS app must not be holding the WHOOP strap.

Options:
  --device DEVICE_ID     Physical iPhone device identifier.
  --bundle-id BUNDLE_ID  App bundle identifier. Default: com.adidshaft.atria.
  --search TEXT          devicectl process search text. Default: Atria.
  --kill                 Use SIGKILL instead of normal termination.
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
    --search)
      process_search=${2:?--search requires a value}
      shift 2
      ;;
    --kill)
      kill_mode=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if ! xcrun devicectl list devices | grep -F "$device_id" | grep -Fq "physical"; then
  printf 'Physical iPhone not available to devicectl: %s\n' "$device_id" >&2
  exit 69
fi

json_path=$(mktemp -t whoop-processes.XXXXXX.json)
trap 'rm -f "$json_path"' EXIT

xcrun devicectl device info processes \
  --device "$device_id" \
  --search "$process_search" \
  --json-output "$json_path" >/dev/null

pid=$(
  python3 - "$json_path" "$bundle_id" <<'PY'
import json
import sys

path, bundle_id = sys.argv[1:3]
data = json.load(open(path, encoding="utf-8"))
processes = data.get("result", {}).get("runningProcesses", [])
for process in processes:
    text = json.dumps(process, sort_keys=True)
    if bundle_id in text or "Atria" in text or "WhoopApp" in text:
        for key in ("processIdentifier", "pid", "processID"):
            value = process.get(key)
            if isinstance(value, int):
                print(value)
                raise SystemExit
        for key, value in process.items():
            if key.lower() in {"pid", "processidentifier", "processid"} and isinstance(value, int):
                print(value)
                raise SystemExit
raise SystemExit(1)
PY
  true
)

if [[ -z "$pid" ]]; then
  printf 'App not running on device: %s\n' "$bundle_id"
  exit 0
fi

cmd=(xcrun devicectl device process terminate --device "$device_id" --pid "$pid")
if [[ "$kill_mode" -eq 1 ]]; then
  cmd+=(--kill)
fi
"${cmd[@]}"
printf 'Terminated %s on %s with pid %s\n' "$bundle_id" "$device_id" "$pid"
