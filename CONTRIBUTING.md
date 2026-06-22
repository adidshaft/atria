# Contributing to Atria

Contributions are welcome when they preserve the project contract: local-only data, honest confidence states, and no fabricated health metrics.

## Ground Rules

- Test BLE changes on a physical iPhone when behavior depends on the strap.
- Keep HRV sourced only from real RR/IBI intervals.
- Keep metrics fail-closed when data is insufficient, aborted, or unvalidated.
- Document protocol claims with logs, captures, or deterministic fixtures.
- Avoid adding cloud services, account dependencies, or subscription assumptions.

## Development Setup

1. Open `WhoopApp/WhoopApp.xcodeproj` in Xcode.
2. Configure signing for the app and widget targets.
3. Run on a physical iPhone.
4. Use `./live_device_debug.sh` for repeatable device verification when changing BLE, metrics, HealthKit, or app-state behavior.

## Local Checks

Run the fast monitor/tooling regression before touching physical-device evidence:

```sh
./test_monitor_long_wear.sh
./test_handoff_static_checks.sh
```

This py-compiles the long-wear monitor, runs its acceptance parsing tests, and
checks static handoff invariants such as production strap-write blocking,
validated HRV export gating, restored-peripheral reuse, and iOS 26-only UI
cleanup.
It does not replace physical iPhone validation for BLE, background collection,
thermal, or battery behavior.

For long-wear proof after Atria is already running on a plugged-in physical
iPhone with the strap connected:

```sh
ATRIA_DEVICE_ID=<physical-device-id> \
  python3 tools/monitor_long_wear.py \
  --preset overnight \
  --label overnight-$(date -u +%Y%m%dT%H%M%SZ)
```

Only treat the run as accepted when the monitor summary says
`acceptance_status=pass` and `acceptance_blockers=none`.

## Pull Request Checklist

- The change is scoped to one logical behavior.
- Build passes for the iOS app.
- Physical-device evidence is included for BLE or runtime behavior changes.
- New metrics expose source and confidence.
- Docs are updated when behavior, gates, or setup changes.

## Areas That Need Help

- Cleaner onboarding for users who only have a strap and iPhone.
- Workout auto-detection from inconsistent BLE coverage.
- Historical payload decoding with reproducible fixtures.
- Tests for artifact correction and gate readiness logic.
- README/docs setup validation on a fresh Mac.
