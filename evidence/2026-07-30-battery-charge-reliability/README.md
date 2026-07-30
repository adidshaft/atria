# WHOOP 4 battery / charging reliability

Date: 2026-07-30 (Asia/Kolkata)

## Physical device

- iPhone device ID: `3803F5B6-1666-56D3-A71A-62F131F6CE3B`
- Strap peripheral ID:
  `C125C62E-C432-53E7-BD19-9761251B2C3E`
- App bundle ID: `com.adidshaft.atria`
- Final candidate executable SHA-256:
  `143d443af3df90d60cffa1607f5b6fc10e4ee07fb6510a3560a3479f229d4f54`
- Installation URL:
  `/private/var/containers/Bundle/Application/DBEFAD03-89C9-45C0-9509-FFDDC573CEE7/Atria.app/`

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
- The exact final Release issued a bounded standard `2A19` read after launch.
  It received a valid 92% callback at 00:23:16 IST, then a second scheduled
  callback at 00:24:55 IST. Accepted HR remained live through the second read
  with a 0.013-second packet age. Unlike the earlier unbounded A/B trials,
  these single-flight reads did not reconnect or interrupt the strap.
- The second callback reported 91%, down from 92%, and Atria immediately
  persisted `notCharging`. The physical charger was therefore not delivering
  power at that boundary; the visible no-bolt 91% pill was truthful.
- The database UUID remained
  `3A0E1087-4035-47FE-B081-3607AF09CBD1`, and the durable daily strap-step
  receipt SHA-256 remained
  `d864334e7b9a9edfec1746900f491cd590f46b69e4f063b8b6a1ee8a6bb1da5a`
  across the in-place Release install.

## Implemented policy

- Use direct `2A1B` truth when a future strap actually exposes it:
  current-link notification, or one standard readable response within a
  15-second request window.
- Never read `2A1B` while proprietary history owns the link.
- On this firmware, derive Charging only from qualified `2A19` increases:
  `1...10%`, at least 30 seconds and at most ten minutes.
- Refresh readable `2A19` asynchronously on the exact current peripheral only:
  never during proprietary history ownership, never more often than once per
  minute, and never with more than one request in flight. A 12-second timeout
  only releases the request; it cannot reconnect, pair, or issue a proprietary
  command.
- Expire Charging after 90 seconds without renewal; a percentage decline or
  disconnect clears it immediately.
- Never let history-origin battery events overwrite current SOC or charging.

## Verification

- `python3 test_handoff_static_checks.py`: `Ran 184 tests ... OK`
- Focused bounded-read admission XCTest: `** TEST SUCCEEDED **`
- `AtriaTests` simulator build-for-testing: `** TEST BUILD SUCCEEDED **`
- Signed physical Release build: `** BUILD SUCCEEDED **`
- Repeating fresh-level read while live HR continued: physically passed.
- Attach/remove visual acceptance: attach remains pending one controlled
  charger reseat. The decline already proves the detached/not-powered
  transition and correct no-bolt presentation; do not claim the attach row
  until a qualified rise or direct charger-state event is observed.
