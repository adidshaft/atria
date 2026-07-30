# 2026-07-30 v17 physical Release checkpoint

## Exact build

- Configuration: `Release`
- Destination: `generic/platform=iOS`
- Result: `** BUILD SUCCEEDED **`
- Installed bundle: `com.adidshaft.atria`
- App binary SHA-256:
  `0ecc7357ce9c1337c684d52bf18063ea897d8cb833373663a8118667ac460039`
- dSYM UUID: `E804F9B3-0E01-3814-97B0-0691806244CB`
- Physical installation URL:
  `/private/var/containers/Bundle/Application/8A10935B-AA12-45E6-8BF1-0D9905BA11A0/Atria.app/`

## Strap-only step quantity

| Setup | Expected | Observed | Result | Evidence |
|---|---|---|---|---|
| Twelve physically counted WHOOP 4 walks, four planted-feet controls, and every whole-second boundary shift from -2 through +2 | Walks within 5%; controls zero; no phone motion | 80/80 passed; W90 returned 92 at the exact boundary and 93/93/92/93/93 across shifts; controls remained zero; `phoneMotionUsed=false` | PASS | `verify-whoop4-v17.json` |
| Relaunch the signed Release with an existing v17 daily receipt | Receipt remains durable and the Today card uses the same authority | The installed Release displayed `>=486`, `Partial archive`, `23% covered`; the persisted receipt reports 486 steps, 5,730 qualified seconds, 19,419 missing seconds, and 6,702 decoded WHOOP rows | PASS | `whoop4-motion-tick-days-v1.json`, `physical-today-v17-step-card.jpeg` |

The physical daily result is deliberately a lower bound. The prior installed
build durably banked only 5,730 of the 25,149 seconds in the open
physiological-day window. V17 does not fill the missing 19,419 seconds with
phone steps, estimates, GPS, HR, or extrapolation.

## Live restoration

| Setup | Expected | Observed | Result |
|---|---|---|---|
| Install and launch the exact signed Release while preserving app data and pairing | Existing motion-bank work completes without losing the process; accepted live HR resumes | Process remained alive; the UI first showed `Reading`, then automatically restored moving live HR (72–95 bpm observed) and the current 83% battery | PASS |
| Relaunch the exact Release in place | Durable receipt and live acquisition survive | V17 receipt remained on disk and visible; live HR resumed without re-pairing or a Bluetooth toggle | PASS |

## Validation

- Static handoff gate: 184/184 passed.
- Physical corpus: 80/80 passed.
- Release build: succeeded, signed, embedded widget validated.
- Focused XCTest source compiled, linked, codesigned, and validated. XCTest
  execution did not begin because CoreSimulator forced each specifically
  booted simulator back to `Shutdown`; this is recorded as an environment
  blocker and is not represented as a test pass.
