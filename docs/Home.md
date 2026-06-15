# WHOOP BLE Project — Wiki

A running log + reference for reverse-engineering my WHOOP strap and building a
custom iOS app.

## Pages

1. [Overview & Goals](01-overview.md) — what this is and why.
2. [Device & BLE Map](02-device-ble-map.md) — IDs, GATT services, characteristics.
3. [Protocol Notes](03-protocol-notes.md) — the proprietary frame format & captures.
4. [macOS BLE Setup](04-macos-ble-setup.md) — the Python tooling + permission workaround.
5. [iOS App](05-ios-app.md) — architecture of the SwiftUI/CoreBluetooth app.
6. [Capture Analysis](07-capture-analysis.md) — findings from labeled captures.
7. [Ownership & Reset](08-ownership-and-reset.md) — why no blind factory reset; standalone design.
8. [Accuracy & Learning](09-accuracy-and-learning.md) — artifact rejection, feedback, adaptive baseline.
9. [WHOOP Metrics](10-whoop-metrics.md) — Recovery & Strain from HR.
10. [Validation Harness](12-validation.md) — replay RR captures and compare HRV.
11. [Roadmap](06-roadmap.md) — what's next.
12. [Master Plan](11-master-plan.md) — full feature set, accuracy program, phases.
13. [/goal](../GOAL.md) — strict execution contract.

## Timeline

- **2026-06-11** — Found the strap over BLE, mapped GATT, decoded frame framing,
  captured live HR on macOS, then built and shipped a native iOS app showing
  live heart rate (84 BPM confirmed on device). First commit.
