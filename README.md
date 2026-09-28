<p align="center">
  <img src="assets/atria-logo.png" alt="Atria app icon" width="120" height="120">
</p>

<h1 align="center">Atria</h1>

<p align="center">
  Free local strap data, for life.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0A1A3E" alt="MIT license"></a>
  <a href="LICENSE-APACHE"><img src="https://img.shields.io/badge/license-Apache--2.0-0A1A3E" alt="Apache 2.0 license"></a>
  <img src="https://img.shields.io/badge/iOS-physical%20device%20required-0A1A3E" alt="Physical iPhone required">
  <img src="https://img.shields.io/badge/data-local%20only-2B6BE0" alt="Local-only data">
  <img src="https://img.shields.io/badge/HRV-personal%20baseline-D97706" alt="HRV personal baseline">
</p>

<p align="center">
  <a href="#help-make-atria-accurate">Help validate</a>
  ·
  <a href="#current-status">Status</a>
  ·
  <a href="#quick-start">Quick Start</a>
  ·
  <a href="docs/SETUP.md">Setup Guide</a>
  ·
  <a href="docs/README.md">Docs</a>
  ·
  <a href="CONTRIBUTING.md">Contributing</a>
  ·
  <a href="https://x.com/adidshaft">Contact adidshaft</a>
</p>

<p align="center">
  For queries reach out to <a href="https://x.com/adidshaft">adidshaft</a>.
</p>

Atria is an open-source iOS app and BLE research toolkit for using a compatible WHOOP strap locally, without the official WHOOP cloud, account, subscription, or app. It is designed for people who own unused straps and want honest local metrics: live heart rate, saved RR windows, strain, sleep/workout evidence, HealthKit export, and protocol research.

This project is independent and unaffiliated with WHOOP. It does not bypass paid cloud features. It talks to your own hardware over Bluetooth LE and keeps data on device.

## Help make Atria accurate

**Got a WHOOP 4 strap and any other fitness device? You can help calibrate Atria.**
Every number Atria shows gets checked against a trusted reference the same way
the step counter was: a known truth, a fixed test, repeats, and a pass bar set
before any data. Each metric has its own issue with the exact procedure.

**Already validated — steps** (iPhone, sample-exact metronome, one step per click):
100 → 95, 80 → 80, 120 → 107, phone locked in a pocket 100 → 100, two minutes of desk typing ≈ 0 false steps ([#21](https://github.com/adidshaft/atria/issues/21)).

### How to contribute

1. **Run the app.** Clone the repo, open `Atria/Atria.xcodeproj`, sign with your
   Apple ID and run on a physical iPhone (iOS 26.1+) with a WHOOP 4 strap. See the
   [Quick Start](#quick-start) and [setup guide](docs/SETUP.md).
2. **Pick a metric** from the table below that your device can check.
3. **Wear both at the same time** and follow the procedure in its issue (full
   detail in the [validation plan](docs/METRIC_VALIDATION_PLAN.md)).
4. **Share the summary, not your data.** Post the device model, number of
   sessions, error per condition (MAE / bias) and pass or fail in the issue.
   Raw heart-rate, sleep and RR files stay on your own machine.
5. **Fixing a miss?** Open a PR on `dev`. The fix must hold on every repeat and be
   per-user or self-calibrating (Atria ships to many people — no constants tuned
   to one wearer), with a regression test.

### What needs checking

| Metric | Compare against | Issue | Status |
|---|---|---|---|
| Heart rate | Chest strap | [#51](https://github.com/adidshaft/atria/issues/51) | ⏳ Needs a reference |
| RR intervals & HRV | Chest strap with RR (Polar H10 best) | [#52](https://github.com/adidshaft/atria/issues/52) | ⏳ Needs a reference |
| Resting heart rate | Chest strap overnight; watch or ring | [#53](https://github.com/adidshaft/atria/issues/53) | ⏳ Needs a reference |
| Respiratory rate | Paced breathing (no device); watch or ring overnight | [#54](https://github.com/adidshaft/atria/issues/54) | ⏳ Anyone can start |
| Sleep onset, wake & naps | Sleep diary; watch, ring or bed sensor | [#55](https://github.com/adidshaft/atria/issues/55) | ⏳ Anyone can start |
| Sleep stages | Watch or ring (agreement); EEG headband or PSG (true) | [#56](https://github.com/adidshaft/atria/issues/56) | 🟡 Estimate |
| Sleep need, performance, consistency | Sleep diary (arithmetic check) | [#57](https://github.com/adidshaft/atria/issues/57) | ⏳ Anyone can start |
| Recovery | WHOOP app recovery; known hard/easy days | [#58](https://github.com/adidshaft/atria/issues/58) | 🟡 Personal baseline |
| Strain, HR zones, max HR | Chest strap in workouts; WHOOP app strain | [#59](https://github.com/adidshaft/atria/issues/59) | 🟡 Local estimate |
| Stress | Labelled test (no device); watch stress score | [#60](https://github.com/adidshaft/atria/issues/60) | ⏳ Anyone can start |
| Skin temperature (relative) | Watch or ring wrist/finger temperature | [#61](https://github.com/adidshaft/atria/issues/61) | 🟡 Relative only |
| Blood oxygen | Overnight fingertip oximeter | [#62](https://github.com/adidshaft/atria/issues/62) | 🔬 Hidden until proven |
| VO2max | Watch VO2max or a lab / Cooper test | [#63](https://github.com/adidshaft/atria/issues/63) | 🟡 Estimate |
| Active calories | Watch active energy | [#64](https://github.com/adidshaft/atria/issues/64) | 🟡 Estimate |
| Detected workouts | Workout diary | [#65](https://github.com/adidshaft/atria/issues/65) | ⏳ Anyone can start |
| Steps (whole day) | Phone pedometer; drained history | [#21](https://github.com/adidshaft/atria/issues/21) | ✅ Walks validated |

### Devices that work as references

Any of these popular devices is useful. Chest straps are the most accurate for
heart rate and RR; watches and rings are good for sleep, temperature and
day-level checks.

| Kind | Examples | Best for |
|---|---|---|
| **Chest straps (ECG)** | Polar H10, Polar H9, Garmin HRM 600 / HRM-Pro Plus, Wahoo TRACKR / TICKR, Coros Heart Rate Monitor, Suunto Smart Heart Rate Belt | Heart rate, RR intervals, HRV, resting HR, strain and zones |
| **Optical armbands** | Polar Verity Sense, Scosche Rhythm, Coros HR armband | Heart rate in workouts (not RR/HRV) |
| **Smartwatches** | Apple Watch (Series 8+ / Ultra for wrist temperature), Garmin Forerunner / Fenix / Venu, Samsung Galaxy Watch, Google Pixel Watch, Fitbit | Sleep timing, respiratory rate, wrist temperature, VO2max, calories, stress |
| **Smart rings** | Oura Ring, Samsung Galaxy Ring, Ultrahuman Ring, RingConn | Sleep timing and stages, skin temperature, resting HR, respiratory rate |
| **Pulse oximeters** | Wellue O2Ring, Masimo MightySat, Nonin fingertip oximeters | Blood oxygen (overnight) |
| **Sleep references** | Withings Sleep Analyzer, EEG headbands (e.g. Muse S), home sleep test / PSG | Sleep timing; true sleep stages (EEG / PSG only) |
| **WHOOP app** | An active WHOOP membership on the same strap | Recovery and strain (plan for Atria and the app sharing the strap's history) |
| **No device** | A metronome, a stopwatch and a diary | Steps, respiratory rate, stress protocol, sleep diary, detected workouts |

## App Tour

<p align="center">
  <a href="assets/screenshots/atria-today-overview.png"><img src="assets/screenshots/atria-today-overview.png" alt="Atria Today overview" width="180"></a>
  <a href="assets/screenshots/atria-today-glance.png"><img src="assets/screenshots/atria-today-glance.png" alt="Atria Today metrics at a glance" width="180"></a>
  <a href="assets/screenshots/atria-vitals-live.png"><img src="assets/screenshots/atria-vitals-live.png" alt="Atria live vitals monitor" width="180"></a>
  <a href="assets/screenshots/atria-vitals-overview.png"><img src="assets/screenshots/atria-vitals-overview.png" alt="Atria health monitor" width="180"></a>
</p>

<p align="center">
  <a href="assets/screenshots/atria-hrv-trends.png"><img src="assets/screenshots/atria-hrv-trends.png" alt="Atria HRV trends" width="180"></a>
  <a href="assets/screenshots/atria-journal-insights.png"><img src="assets/screenshots/atria-journal-insights.png" alt="Atria journal insights" width="180"></a>
  <a href="assets/screenshots/atria-activity-timeline.png"><img src="assets/screenshots/atria-activity-timeline.png" alt="Atria daily activity timeline" width="180"></a>
</p>

<p align="center">
  <a href="assets/screenshots/atria-workout-setup.png"><img src="assets/screenshots/atria-workout-setup.png" alt="Atria workout setup" width="180"></a>
  <a href="assets/screenshots/atria-activity-picker.png"><img src="assets/screenshots/atria-activity-picker.png" alt="Atria activity picker" width="180"></a>
  <a href="assets/screenshots/atria-live-workout.png"><img src="assets/screenshots/atria-live-workout.png" alt="Atria live workout" width="180"></a>
</p>

<p align="center">
  <a href="assets/screenshots/atria-workout-summary.png"><img src="assets/screenshots/atria-workout-summary.png" alt="Atria workout summary" width="180"></a>
  <a href="assets/screenshots/atria-breathwork.png"><img src="assets/screenshots/atria-breathwork.png" alt="Atria breathwork" width="180"></a>
  <a href="assets/screenshots/atria-metric-customization.png"><img src="assets/screenshots/atria-metric-customization.png" alt="Atria Today metric customization" width="180"></a>
</p>

## Current Status

**Status reviewed 28 September 2026.** The public default branch, published
`dev`, and latest local research are at different checkpoints. See
[Current product status](docs/CURRENT_STATUS.md) for the branch boundaries,
active issues, and acceptance gates. The new Mac R10/R11 findings are not yet
an enabled iPhone feature or a released build.

Atria is usable for local backup and honest diagnostics on a physical iPhone. For the current single-strap build, personal baseline is the end-user ready HRV/recovery state; external-reference validation remains an optional/internal gate for HealthKit HRV and research claims, not a required user task.

### At a glance

**✅ Implemented** · **🟡 Limited confidence** · **🔬 Research only** · **⏳ Pending** · **⛔ Blocked**

“Implemented” describes working functionality, not independently validated health
accuracy. Status includes development work; the branch boundaries above still
apply. Confidence labels are evidence categories, not completion percentages.

| Capability | Achieved | Confidence / availability | Next milestone |
|---|---|---|---|
| **Live HR, battery & local data** | iPhone collection, persistence and reconnect handling | ✅ Implemented; background acceptance remains | [Fresh onboarding](https://github.com/adidshaft/atria/issues/23) · [lease expiration](https://github.com/adidshaft/atria/issues/22) |
| **HRV & recovery** | RR filtering, RMSSD and personal baselines | 🟡 Personal baseline; reference-unverified | [Resolve RR scaling](https://github.com/adidshaft/atria/issues/47) · [qualify recovery](https://github.com/adidshaft/atria/issues/2) |
| **Strain** | Personalized HR-reserve TRIMP | 🟡 Local estimate; calibration pending | [Rest/high-effort reference comparison](https://github.com/adidshaft/atria/issues/3) |
| **Sleep & workouts** | Candidates, saved sessions and daily summaries | 🟡 Coverage-dependent; review flow needs proof | [Physical sleep review](https://github.com/adidshaft/atria/issues/25) · [workout surfaces](https://github.com/adidshaft/atria/issues/45) |
| **Trends, widgets & insights** | Local history views and shared display data | 🟡 Cross-surface consistency still under review | [Trend confidence](https://github.com/adidshaft/atria/issues/5) · [concise UI](https://github.com/adidshaft/atria/issues/48) |
| **All-day steps** | Live R10 gyro-cadence count on iPhone, foreground and locked | ✅ Metronome walks validated; whole-day totals pending | [Whole-day totals](https://github.com/adidshaft/atria/issues/21) |
| **R10/R11 motion & optical streams** | Mac decoding and offline Swift port | 🔬 Local research; production iPhone path disabled | [Sustained iPhone integration](https://github.com/adidshaft/atria/issues/46) |
| **Disconnect recovery** | Short Mac test recovered contiguous 1 Hz history | 🔬 Long-gap/iPhone proof pending; raw high-rate gaps remain lost | [Overnight analysis and lifecycle checks](https://github.com/adidshaft/atria/issues/46) |
| **Skin temperature** | Relative °C vs the wearer's own sleep baseline (shown) | 🟡 Relative only; absolute calibration unproven | [Reference comparison](https://github.com/adidshaft/atria/issues/61) |
| **SpO₂** | Pulsatile R11 optical data decoded on Mac | ⏳ No defensible percentage yet | [Channel/gain interpretation and reference validation](https://github.com/adidshaft/atria/issues/31) |
| **HealthKit** | Supported HR/workout/sleep export plumbing | ✅ Implemented for supported data; HRV export gated | [Qualified HRV and device readback](https://github.com/adidshaft/atria/issues/6) |
| **Integration & release** | Draft integration PR and local device builds | ⛔ Verification and distribution gates open | [Repair checks](https://github.com/adidshaft/atria/issues/44) · [TestFlight receipt](https://github.com/adidshaft/atria/issues/42) |

### From working data to trusted features

```mermaid
flowchart TD
    A["IMPLEMENTED · iPhone HR + local storage"] --> B["LIMITED CONFIDENCE · Personal HRV / recovery"]
    B --> C["PENDING · RR scale + reference qualification"]
    D["RESEARCH · Mac R10/R11 decoding"] --> E["RESEARCH · Offline Swift port"]
    E --> F["PENDING · Sustained iPhone transport"]
    G["RESEARCH · Short-gap 1 Hz recovery"] --> H["PENDING · Long-gap + overnight proof"]
    F --> I["PENDING · All-day steps + sensor validation"]
    H --> I
    classDef implemented fill:#dcfce7,stroke:#166534,color:#14532d
    classDef limited fill:#fef3c7,stroke:#92400e,color:#78350f
    classDef research fill:#dbeafe,stroke:#1d4ed8,color:#1e3a8a
    classDef pending fill:#f1f5f9,stroke:#64748b,color:#334155,stroke-dasharray:5 5
    class A implemented
    class B limited
    class D,E,G research
    class C,F,H,I pending
```

Solid boxes describe existing functionality or research results; dashed boxes
are unfinished milestones. The paths show dependencies, not a release timeline.
See the [full status and issue index](docs/CURRENT_STATUS.md) for acceptance criteria.

## Principles

- **Local first:** no WHOOP account, no cloud dependency, no subscription requirement.
- **No fake metrics:** HRV and recovery stay learning until real local RR/baseline evidence is sufficient, then appear as personal-baseline/unverified. Validated remains an internal/export tier, not a default user promise.
- **Physical-device verified:** BLE work must be tested on a real iPhone; the Simulator does not count.
- **Explainable outputs:** metrics expose source, confidence, and blockers instead of hiding uncertainty.
- **Conservative by default:** when data is missing, gappy, or unvalidated, Atria reports that clearly.

## What Works Today

- Physical iPhone BLE collection from a compatible strap.
- Live heart rate via standard BLE Heart Rate Measurement (`0x2A37`).
- Battery readout.
- Long-wear foreground backup with checkpointing.
- Saved RR window detection with artifact filtering:
  - keep RR intervals in `300...2000 ms`
  - drop intervals with `>20%` beat-to-beat delta
  - report confidence as kept/raw RR percentage
- Local strain from personalized HR-reserve TRIMP.
- Sleep and workout candidate summaries with explicit blockers.
- HealthKit export for supported validated/local-safe data; HealthKit HRV remains gated on validated SDNN.
- Widget/complication data plumbing.
- Protocol research tools for BLE backup and frame analysis.

## What Does Not Work Yet

- Clinically validated HRV. Atria can show local RMSSD as a personal baseline; independent RR/IBI validation is not part of the single-strap user path.
- Fully validated recovery. Recovery can display as a personal baseline; the validated tier stays gated for export/research uses.
- Fully automatic workout detection in all gym conditions. Current logic is honest about stream coverage and HR-intensity blockers.
- **Validated whole-day steps.** Development builds have displayed step totals,
  but display agreement does not establish all-day accuracy. September 23 Mac
  experiments recovered 1 Hz history across a short disconnect and exercised a
  fused step estimator. Fresh held-out walks, long gaps, and physical iPhone
  integration remain open. Raw high-rate IMU is not stored during disconnects.
  ([#21](https://github.com/adidshaft/atria/issues/21),
  [#46](https://github.com/adidshaft/atria/issues/46))
- **SpO₂.** Historical V24 DC candidate fields did not support a defensible
  percentage. Newly decoded Mac R11 pulsatile optical data is a separate
  research source, not a validated SpO₂ value.
  ([#31](https://github.com/adidshaft/atria/issues/31))
- **Calibrated absolute skin temperature.** The older V24 thermal signal and
  the new R10 candidate have different evidence. R10 has one contact-thermometer
  comparison; repeatability, slope and per-device calibration are unproven.
  The product target remains deviation from a personal baseline.
- **Confirmed WHOOP-specific RR scaling.** Mac source comparisons found a
  discrepancy with the app's standard Heart Rate Service conversion. A
  source-specific investigation is pending; independent HRV and HealthKit
  validation gates remain unchanged.
  ([#47](https://github.com/adidshaft/atria/issues/47))
- Any claim that requires WHOOP cloud data. This project intentionally stays local.

## Quick Start

Requirements:

- macOS with Xcode.
- A physical iPhone running iOS 26.1 or later. BLE collection cannot be validated in the Simulator.
- A compatible strap that is free to advertise over BLE.
- Apple Developer signing configured for the iOS app target.

Build and run:

```sh
open Atria/Atria.xcodeproj
```

Select the Atria app target, choose your physical iPhone, set signing if needed, and run.

> **New to the project?** [`docs/SETUP.md`](docs/SETUP.md) covers signing, the
> device-log harness, the errors you will actually hit, and which logs are safe
> to share before you post evidence anywhere.

For command-line physical-device verification:

```sh
ATRIA_DEVICE_ID="YOUR-PHYSICAL-DEVICE-ID" ./live_device_debug.sh --seconds 45 --log logs/live-device/run.log --log-gate-status --standard-hr-only --long-wear-mode --leave-running
```

Local tooling checks (offline; the current development static gate has known
failures tracked in [#44](https://github.com/adidshaft/atria/issues/44)):

```sh
./test_handoff_local.sh
```

Long-wear acceptance, when extended physical-device checks are allowed:

```sh
ATRIA_DEVICE_ID="YOUR-PHYSICAL-DEVICE-ID" \
  python3 tools/monitor_long_wear.py \
  --preset overnight \
  --label overnight-$(date -u +%Y%m%dT%H%M%SZ)
```

That monitor is non-invasive: it uses `live_device_debug.sh --pull-only` to sample
sessions and the active journal without relaunching Atria. The handoff is not
accepted until the final summary reports `acceptance_status=pass` and
`acceptance_blockers=none`, and the handoff audit confirms the summary is the
full overnight shape rather than a short custom smoke.

Accessibility/performance acceptance also needs measured physical-device
results. Capture them with `tools/capture_accessibility_visual_evidence.sh` and
`tools/capture_dashboard_scroll_performance.sh`, then create the local manifest
with `tools/prepare_accessibility_performance_evidence.py`.

To summarize the current handoff evidence without running the device:

```sh
python3 tools/audit_handoff_status.py --skip-external-reference
```

After overnight and accessibility/performance evidence exists:

```sh
python3 tools/audit_handoff_status.py \
  --skip-external-reference \
  --summary <overnight-summary.json> \
  --accessibility-performance <accessibility-performance-summary.json>
```

## Repository Layout

| Path | Purpose |
|---|---|
| `Atria/` | Native SwiftUI iOS app, widget, HealthKit, BLE, and local metrics code. |
| `tools/` | Analysis helpers for captures, references, and protocol evidence. |
| `docs/` | Technical notes, validation plans, and protocol research — start at [`docs/README.md`](docs/README.md). |
| `scan.py`, `probe.py`, `listen.py`, `whoop_codec.py` | macOS BLE exploration and decode tooling. |
| `live_device_debug.sh` | Physical-iPhone build/install/launch/log harness. |
| `test_*.py`, `test_*.sh` | Offline regression checks and evidence harnesses; physical capture scripts require a device. |
| `gate_*.sh`, `reference_*.sh` | Capture and reference-comparison runs for sensor validation. |
| `assets/` | Logo and README screenshots. |
| `evidence/` | Physical-device evidence trees. Gitignored — may contain personal health data. |

No WHOOP credentials are required. Physical-device builds use your own Apple
signing configuration. Review staged changes for private data before publication;
ignore rules cover known signing material, evidence and logs.

- [Research validation corpus](docs/research-validation-corpus.md) — the rules and fixtures used for reproducible sensor validation.

## Contributing

All development, issue fixes and documentation updates land on **`dev`**.
Reviewed changes reach **`main`** through the dev → main integration PR.

The fastest useful contributions are:

- Improve BLE reliability without increasing radio traffic.
- Add tests around RR parsing, correction, and confidence gates.
- Improve workout detection from real saved sessions.
- Decode additional historical/protocol payloads with evidence.
- Improve docs for setup and troubleshooting.

Start with [`docs/SETUP.md`](docs/SETUP.md) to get a build running, then browse
[open issues](https://github.com/adidshaft/atria/issues) — they are labelled by
area (`area: ble`, `area: sleep`, `area: steps`…), by type, and by what each one
is waiting on (`needs: device proof`, `needs: reference`, `blocked`).

Before opening a PR, read [CONTRIBUTING.md](CONTRIBUTING.md). Do not submit code that estimates HRV from HR-only data or silently promotes low-confidence metrics.

## Safety and Privacy

Atria is not medical software. It is a local research and personal-fitness project. Do not use it for diagnosis, treatment, or safety-critical decisions.

The app is designed to keep data local. Be careful when sharing logs or evidence files; they may contain timestamps, heart-rate samples, device names, and workout/sleep patterns.

## License

Dual licensed under MIT or Apache-2.0. See [LICENSE](LICENSE) and [LICENSE-APACHE](LICENSE-APACHE).
