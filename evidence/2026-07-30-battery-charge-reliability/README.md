# WHOOP 4 battery / charging reliability

Date: 2026-07-30 (Asia/Kolkata)

## Physical device

- iPhone device ID: `3803F5B6-1666-56D3-A71A-62F131F6CE3B`
- Strap peripheral ID:
  `C125C62E-C432-53E7-BD19-9761251B2C3E`
- App bundle ID: `com.adidshaft.atria`
- Final candidate executable SHA-256:
  `b0438f794f0c32c5fe99a41f3e777e58660edcae859be82b28460ffd982c7222`
- Installation URL:
  `/private/var/containers/Bundle/Application/D1DA4797-B449-4058-9822-4757AD7EE77F/Atria.app/`

## Demonstrated transport facts

- Live HR and proprietary R10 remained active during the battery work.
- The accepted standard `2A19` level rose from 83% through 92% while the
  charger was physically attached.
- No `2A1B` characteristic proof was emitted on this firmware: no properties,
  subscription, read, or callback keys existed in the physical preference
  pull. The absence remained true after a signed Release reinstall.
- A fresh `2A19` notification epoch was confirmed at
  `1785433749.065175`; the cached 92% baseline was promoted only after
  current-link HR proved the same strap connection.
- Explicit automatic `2A19` reads remain disabled because earlier physical A/B
  trials disconnected this strap.

## Implemented policy

- Use direct `2A1B` truth when a future strap actually exposes it:
  current-link notification, or one standard readable response within a
  15-second request window.
- Never read `2A1B` while proprietary history owns the link.
- On this firmware, derive Charging only from qualified `2A19` increases:
  `1...10%`, at least 30 seconds and at most ten minutes.
- Expire Charging after 90 seconds without renewal; a percentage decline or
  disconnect clears it immediately.
- Never let history-origin battery events overwrite current SOC or charging.

## Verification

- `python3 test_handoff_static_checks.py`: `Ran 184 tests ... OK`
- `AtriaTests` simulator build-for-testing: `** TEST BUILD SUCCEEDED **`
- Signed physical Release build: `** BUILD SUCCEEDED **`
- Attach/remove visual acceptance: pending the controlled reseat/removal
  boundary below; do not claim this row passed until both transitions are
  observed on the installed Release.
