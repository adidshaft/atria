#!/bin/zsh
# One long-lived Bluetooth-capable runner for the Claude terminal panel.
# CoreBluetooth scripts are SIGKILLed by TCC unless launched from an app that declares
# Bluetooth usage (Claude.app panel, Cursor). This runs queued lines one at a time so a
# single panel tab serves every experiment. Queue: one shell command per line.
QUEUE=${1:-/tmp/atria-ble/runner.queue}
cd "${0:A:h}/../.." || exit 1
touch "$QUEUE"
echo "runner: watching $QUEUE (cwd $PWD)"
while true; do
  if [[ -s "$QUEUE" ]]; then
    cmd=$(head -n 1 "$QUEUE")
    tail -n +2 "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    echo "runner: $(date +%H:%M:%S) start: $cmd"
    eval "$cmd"
    echo "runner: $(date +%H:%M:%S) done (exit $?)"
  fi
  sleep 1
done
