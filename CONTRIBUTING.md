# Contributing to Atria

Contributions are welcome when they preserve the project contract: local-only data, honest confidence states, and no fabricated health metrics.

## Ground Rules

- Test BLE changes on a physical iPhone when behavior depends on the strap.
- Keep HRV sourced only from real RR/IBI intervals.
- Keep metrics fail-closed when data is insufficient, aborted, or unvalidated.
- Document protocol claims with logs, captures, or deterministic fixtures.
- Avoid adding cloud services, account dependencies, or subscription assumptions.

## Development Setup

1. Open `Atria/Atria.xcodeproj` in Xcode.
2. Configure signing for the app and widget targets.
3. Run on a physical iPhone with iOS 26.1 or later. See [setup](docs/SETUP.md) for signing and simulator test destinations.
4. Use `./live_device_debug.sh` for repeatable device verification when changing BLE, metrics, HealthKit, or app-state behavior.

## Local Checks

Run the offline monitor/tooling regression before touching physical-device evidence:

```sh
./test_handoff_local.sh
```

This py-compiles the long-wear monitor, runs its acceptance parsing tests, and
checks static handoff invariants such as production strap-write blocking,
validated HRV export gating, restored-peripheral reuse, and iOS 26-only UI
cleanup. The audit status test verifies that local artifacts and physical
long-wear summaries are interpreted conservatively.
It does not replace physical iPhone validation for BLE, background collection,
thermal, or battery behavior.

Record the tested commit, command, pass/fail/skip counts, and any missing
fixtures. A skipped fixture test is not validation of its decoder or estimator.
Prefer synthetic fixtures that can run from a clean clone; never add raw personal
captures just to remove a skip.

**Known verification debt:** a September 23, 2026 audit of local `dev` at
`0447c592` ran `python3 test_handoff_static_checks.py`: 189 tests, 77 failures.
That result describes that development commit, not `main` or every checkout.
Track reconciliation in [#44](https://github.com/adidshaft/atria/issues/44).
The wrapper stops on a failing command, so a stopped run does not establish that
its later suites passed. Report the actual result for your branch; compare
pre-existing failures before attributing them to a change, and do not remove
safety assertions merely to make a check pass.

For long-wear proof after Atria is already running on a plugged-in physical
iPhone with the strap connected:

```sh
ATRIA_DEVICE_ID="YOUR-PHYSICAL-DEVICE-ID" \
  python3 tools/monitor_long_wear.py \
  --preset overnight \
  --label overnight-$(date -u +%Y%m%dT%H%M%SZ)
```

Only treat the run as accepted when the monitor summary says
`acceptance_status=pass` and `acceptance_blockers=none`.

## Branches and evidence scope

- The repository uses two branches: `dev` and `main`.
- All development, issue fixes, documentation and repository maintenance land on `dev`.
- Promote reviewed work from `dev` to `main` through the integration PR; do not create topic branches or direct-to-main maintenance PRs.
- A branch name alone does not establish release acceptance.
- Cite the commit and platform for evidence. Mac protocol captures, simulator tests,
  and physical iPhone acceptance establish different things; do not promote one
  into a claim about another.
- Keep issue status aligned with shipped behavior. Link partial progress and its
  remaining acceptance checks instead of closing an issue on an offline prototype.

## Pull Request Checklist

- The change is scoped to one logical behavior.
- Report the iOS build result and exact tested commit, or explain why a build was not required.
- Physical-device evidence is included for BLE or runtime behavior changes.
- New metrics expose source and confidence.
- Docs are updated when behavior, gates, or setup changes.
- Logs, screenshots, and fixtures are reviewed for private health data and identifiers before sharing.
- Failures and skipped checks are disclosed, with linked follow-up issues where applicable.

## Areas That Need Help

- Cleaner onboarding for users who only have a strap and iPhone.
- Workout auto-detection from inconsistent BLE coverage.
- Historical payload decoding with reproducible fixtures.
- Tests for artifact correction and gate readiness logic.
- README/docs setup validation on a fresh Mac.
