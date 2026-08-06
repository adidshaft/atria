# 2026-07-30 v17 physical Release checkpoint

## Exact build

- Configuration: `Release`
- Destination: `generic/platform=iOS`
- Result: `** BUILD SUCCEEDED **`
- Installed bundle: `com.adidshaft.atria`
- App binary SHA-256:
  `8c9ea62ba46ae275835232946fa38573282a01f784ff0763f291f0914403d183`
- dSYM UUID: `5079E1EA-C92A-39D6-9ED2-F7C4A93F73FC`
- Physical installation URL:
  `/private/var/containers/Bundle/Application/FE343356-5CAF-4017-9F6A-264FEB4E8FDC/Atria.app/`

## Strap-only step quantity

| Setup | Expected | Observed | Result | Evidence |
|---|---|---|---|---|
| Twelve physically counted WHOOP 4 walks, four planted-feet controls, and every whole-second boundary shift from -2 through +2 | Walks within 5%; controls zero; no phone motion | 80/80 passed; W90 returned 92 at the exact boundary and 93/93/92/93/93 across shifts; controls remained zero; `phoneMotionUsed=false` | PASS | `verify-whoop4-v17.json` |
| Relaunch the signed Release with an existing v17 daily receipt | Receipt remains durable and the Today card uses the same authority | The installed Release displayed `>=486`, `Partial archive`, `23% covered`; the persisted receipt reports 486 steps, 5,730 qualified seconds, 19,419 missing seconds, and 6,702 decoded WHOOP rows | PASS | `whoop4-motion-tick-days-v1.json`, `physical-today-v17-step-card.jpeg` |
| Continue real wear through later reconnects and in-place Release installs | The same durable authority advances and remains explicitly partial rather than disappearing or becoming a false exact total | The physical card displayed `≥812` and `Partial archive · 24% covered`; the pulled receipt reports 812 steps, 7,066 qualified seconds, 22,463 missing seconds, 8,128 decoded rows, and the same saved strap/current-cycle boundary | PASS | `physical-current-partial-step-card.png`, physical `whoop4-motion-tick-days-v1.json` pull |

The physical daily result is deliberately a lower bound. The prior installed
build durably banked only 5,730 of the 25,149 seconds in the open
physiological-day window. V17 does not fill the missing 19,419 seconds with
phone steps, estimates, GPS, HR, or extrapolation.

The later 812-step receipt is also deliberately a lower bound. Its physiological
cycle began at 15:05 IST, while this development session did not open the
autonomous bank until 18:16 IST and repeatedly installed/relaunched Release
builds afterward. Six resulting short tickets remained at attempt zero under
real device thermal deferral. This is development-created missing coverage,
not permission to inflate the receipt; the current successor bank remains open.

## Live restoration

| Setup | Expected | Observed | Result |
|---|---|---|---|
| Install and launch the exact signed Release while preserving app data and pairing | Existing motion-bank work completes without losing the process; accepted live HR resumes | Process remained alive; the UI first showed `Reading`, then automatically restored moving live HR (72–95 bpm observed) and the current 83% battery | PASS |
| Relaunch the exact Release in place | Durable receipt and live acquisition survive | V17 receipt remained on disk and visible; live HR resumed without re-pairing or a Bluetooth toggle | PASS |

## Autonomous bank lifecycle

| Setup | Expected | Observed | Result | Evidence |
|---|---|---|---|---|
| Leave the reopened all-day bank untouched across the prior 79–125 second terminal-reconciliation failure window | Repeated reconciliation must not close the autonomous bank | The bank remained open for 202.771 seconds. Its only close was accompanied by a real `CBErrorDomain:6` range-loss boundary; CoreBluetooth reconnected 6.362 seconds later and accepted live HR resumed automatically | PASS | Pulled preferences and durable reconnect trail |
| Relaunch with the resulting exact ticket still at attempt 0 while an older terminal consumer materialization blocks its BLE request | Retain the exact ticket, but immediately resume present capture rather than sacrificing new all-day seconds | The exact 202.771-second ticket remained durable at attempt 0 with `deferred_terminal_materialization`; concurrently, a successor bank remained enabled and continuously open for 173.106 seconds, with zero additional closes and live HR packet age 0.268 seconds | PASS | `cadence-final.json`, `physical-final-release-live.jpeg` |

No coverage is credited to the deferred ticket until its exact window reaches
the existing verification threshold. Reopening the successor bank preserves
new factual strap data; it does not estimate, extrapolate, or mark the older
interval recovered.

## Validation

- Static handoff gate: 184/184 passed.
- Physical corpus: 80/80 passed.
- Release build: succeeded, signed, embedded widget validated.
- Updated `AtriaTests` target: compiled and validated for both arm64 and
  x86_64 iOS Simulator architectures.
- Focused XCTest source compiled, linked, codesigned, and validated. XCTest
  execution did not begin because CoreSimulator forced each specifically
  booted simulator back to `Shutdown`; this is recorded as an environment
  blocker and is not represented as a test pass.
