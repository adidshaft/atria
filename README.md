# Atria

**Free local WHOOP strap usage, for life.**

For queries reachout to [adidshaft](https://x.com/adidshaft).

![Atria logo](assets/atria-logo.png)

Atria is an open-source iOS app and BLE research toolkit for using a compatible WHOOP strap locally, without the official WHOOP cloud, account, subscription, or app. It is designed for people who own unused straps and want honest local metrics: live heart rate, saved RR windows, strain, sleep/workout evidence, HealthKit export, and protocol research.

This project is independent and unaffiliated with WHOOP. It does not bypass paid cloud features. It talks to your own hardware over Bluetooth LE and keeps data on device.

![Atria Today screen](assets/atria-today.png)

## Current Status

Atria is usable for local collection and honest diagnostics on a physical iPhone. Some clinical claims remain gated because they require independent reference data.

| Gate | Area | Status | What works | What remains |
|---|---|---:|---|---|
| A | BLE connection and live collection | Partial | Fresh scan/connect, standard `2A37` HR, battery, long-wear logging, reconnect watchdogs | Proprietary realtime stream remains diagnostic; custom RR stream is not reliable enough to be primary |
| B | HRV | Reference pending | Clean saved 5-minute RR package exists; RMSSD shown only with reference warning; RR correction/confidence enforced | Independent RR/IBI reference comparison within tolerance |
| C | Recovery | Learning | Recovery fails closed until validated HRV baseline exists | 7-day validated baseline and morning capture confidence |
| D | Strain and onboarding | Partial | HR-reserve TRIMP, learned resting HR, HRmax/profile controls, explainable strain | External HR reference validation and workout-intensity calibration |
| E | Sleep and workout detection | User-confirmed evidence | Sleep/workout candidates, user-confirmed examples, daily rollups, honest blockers | Fully automatic workout detection from cleaner sustained coverage |
| F | Trends and insights | Local progress | 7/30/90-day trend surfaces and anomaly routing from saved rollups | More history and HRV reference-backed trend confidence |
| G | Platform polish | Metric-gated | HealthKit HR/workout/sleep export, backups, notifications, widget/complication plumbing | HealthKit HRV write waits for validated HRV |
| H | Protocol expansion | Research-ready | Historical/archive decoder evidence and protocol diagnostics | Additional sensor validation and broader strap-history decoding |

## Principles

- **Local first:** no WHOOP account, no cloud dependency, no subscription requirement.
- **No fake metrics:** HRV and recovery stay in learning/reference-pending states unless real RR evidence is sufficient.
- **Physical-device verified:** BLE work must be tested on a real iPhone; the Simulator does not count.
- **Explainable outputs:** metrics expose source, confidence, and blockers instead of hiding uncertainty.
- **Conservative by default:** when data is missing, gappy, or unvalidated, Atria reports that clearly.

## What Works Today

- Physical iPhone BLE collection from a compatible strap.
- Live heart rate via standard BLE Heart Rate Measurement (`0x2A37`).
- Battery readout.
- Long-wear foreground collection with checkpointing and backups.
- Saved RR package detection with artifact filtering:
  - keep RR intervals in `300...2000 ms`
  - drop intervals with `>20%` beat-to-beat delta
  - report confidence as kept/raw RR percentage
- Local strain from personalized HR-reserve TRIMP.
- Sleep and workout candidate summaries with explicit blockers.
- HealthKit export for supported validated/local-safe data.
- Widget/complication data plumbing.
- Protocol research tools for BLE capture and frame analysis.

## What Does Not Work Yet

- Clinically passed HRV. Atria has a clean local RR package, but independent RR/IBI reference validation is still missing.
- Fully validated recovery. Recovery depends on validated HRV baseline.
- Fully automatic workout detection in all gym conditions. Current logic is honest about stream coverage and HR-intensity blockers.
- Any claim that requires WHOOP cloud data. This project intentionally stays local.

## Quick Start

Requirements:

- macOS with Xcode.
- A physical iPhone. BLE collection cannot be validated in the Simulator.
- A compatible strap that is free to advertise over BLE.
- Apple Developer signing configured for the iOS app target.

Build and run:

```sh
open WhoopApp/WhoopApp.xcodeproj
```

Select the Atria app target, choose your physical iPhone, set signing if needed, and run.

For command-line physical-device verification:

```sh
./live_device_debug.sh --seconds 45 --log logs/live-device/run.log --log-gate-status --standard-hr-only --long-wear-mode --leave-running
```

## Repository Layout

| Path | Purpose |
|---|---|
| `WhoopApp/` | Native SwiftUI iOS app, widget, HealthKit, BLE, and local metrics code. |
| `tools/` | Analysis helpers for captures, references, and protocol evidence. |
| `docs/` | Technical notes, gate plans, evidence summaries, and protocol research. |
| `scan.py`, `probe.py`, `listen.py`, `whoop_codec.py` | macOS BLE exploration and decode tooling. |
| `live_device_debug.sh` | Physical-iPhone build/install/launch/log harness. |
| `assets/` | Logo and README screenshots. |

## Contributing

The fastest useful contributions are:

- Improve BLE reliability without increasing radio traffic.
- Add tests around RR parsing, correction, and confidence gates.
- Improve workout detection from real saved sessions.
- Decode additional historical/protocol payloads with evidence.
- Improve docs for setup and troubleshooting.

Before opening a PR, read [CONTRIBUTING.md](CONTRIBUTING.md). Do not submit code that estimates HRV from HR-only data or silently promotes low-confidence metrics.

## Safety and Privacy

Atria is not medical software. It is a local research and personal-fitness project. Do not use it for diagnosis, treatment, or safety-critical decisions.

The app is designed to keep data local. Be careful when sharing logs or evidence files; they may contain timestamps, heart-rate samples, device names, and workout/sleep patterns.

## License

Dual licensed under MIT or Apache-2.0. See [LICENSE](LICENSE) and [LICENSE-APACHE](LICENSE-APACHE).
