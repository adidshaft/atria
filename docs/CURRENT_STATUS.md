# Current product status

Reviewed **23 September 2026**, using repository source, GitHub issue history and
the latest local Claude session. This is a dated snapshot; linked issues carry
subsequent acceptance evidence.

## Which version is being described?

| Checkpoint at review | State |
|---|---|
| Public default `main` — `de633035` | The default checkout. It does not contain all development work below. |
| Published `dev` — `d31edb0a` | 365 commits ahead of that `main`; integration [#43](https://github.com/adidshaft/atria/pull/43) remains draft. |
| Local `dev` — `0447c592` | Another 60 unpublished commits, including September 23 Mac research and offline Swift ports. They are not included in the published PR head. |

This documentation update does not publish that local backlog, install an app,
change production sensor gates, or establish a new release. The latest session
ended after dispatching a UI pass; no completed UI result was established by this
audit. Coordinate through [#48](https://github.com/adidshaft/atria/issues/48).

## Product and research

| Area | Supported statement | Remaining proof |
|---|---|---|
| iPhone collection | Standard BLE heart rate, local persistence and battery collection exist; runtime reliability work is on `dev`. | Fresh onboarding, actual lease expiration, and current workout/background receipts. |
| HRV and recovery | Personal-baseline values are distinct from independently validated values. | WHOOP-specific RR-unit investigation, validated baseline/reference comparisons and gated HealthKit export. |
| Steps | Development builds have shown Today/widget agreement. Local Mac fused estimation passed some development-capture comparisons. | Held-out accuracy, autonomous full-day coverage, reconnect/reset accounting and physical iPhone integration. |
| R10/R11 | Local Mac research decoded high-rate IMU, metadata and pulsatile optical data. Swift decoders/estimator have an offline port. | Production R10 remains disabled; sustained iPhone transport is unproven. Raw optical data is not a validated SpO₂ percentage. |
| Disconnect history | A short Mac experiment recovered contiguous 1 Hz history by pausing live before draining, then resuming. | Long gym-gap/overnight analysis and iPhone lifecycle integration. Raw high-rate IMU/PPG during disconnects is unrecoverable. |
| Temperature | The new R10 candidate has one contact-thermometer comparison. The older V24 thermal signal has separate format-specific evidence. | Repeated calibration, slope and baseline stability. One point does not qualify an absolute temperature product. |
| Sleep and insights | Settled local sleep/workout and baseline-backed summaries exist. | Review-only sleep behavior, fresh active-sleep authority, shared cycle/window provenance and concise UI. |

The latest capture had started and completed short automatic-drain checks when
reviewed. Its planned overnight duration and gym recovery are **pending outcomes**,
not acceptance receipts. No Bluetooth probe, capture restart or iPhone pairing
change was performed for this audit.

## Active work

Issues remain open until their own acceptance evidence is attached. Code, Mac
experiments, simulator tests, surface agreement and physical acceptance are not
interchangeable.

| Issue | Next result needed |
|---|---|
| [#46 iPhone R10/R11 transport](https://github.com/adidshaft/atria/issues/46) | Bounded duty-cycle/reconnect implementation and physical sustained-stream/background proof. |
| [#47 RR units](https://github.com/adidshaft/atria/issues/47) | Reproduce the WHOOP-specific discrepancy, preserve standard HRS behavior, and version stored provenance. |
| [#21 all-day steps](https://github.com/adidshaft/atria/issues/21) | Fresh labelled walks/controls, long-gap coverage, no double-credit and iPhone quantity proof. |
| [#31 sensor decoding](https://github.com/adidshaft/atria/issues/31) | R11 channel/gain interpretation, paired SpO₂ references and repeated temperature validation. |
| [#48 UI and insights](https://github.com/adidshaft/atria/issues/48) | Concise primary copy, accessible detail and consistent source/confidence across surfaces. |
| [#45 runtime surfaces](https://github.com/adidshaft/atria/issues/45) | Real Lock Screen/Live Activity/widget and workout state acceptance; preview alone is insufficient. |
| [#44 verification](https://github.com/adidshaft/atria/issues/44) | Classify/repair the static gate and provide public deterministic decoder fixtures. |
| [#42 distribution](https://github.com/adidshaft/atria/issues/42) | Successful supported-build-host upload and physical TestFlight-install receipt. |
| [#41 sleep consistency](https://github.com/adidshaft/atria/issues/41) | Review/integrate the dev fix through #43. |
| [#38 day browsing/storage](https://github.com/adidshaft/atria/issues/38) | Measured navigation latency, atomic bounded persistence and compaction parity. |
| [#26 evidence retention](https://github.com/adidshaft/atria/issues/26) | Content-addressed references and validated manifests before retiring source data. |
| [#25 sleep review](https://github.com/adidshaft/atria/issues/25) | Physical Confirm/Adjust/Dismiss flow with matching persisted state. |
| [#30 active sleep](https://github.com/adidshaft/atria/issues/30) | Fresh in-progress sleep authority and overnight entry/exit evidence. |
| [#32 stress validation](https://github.com/adidshaft/atria/issues/32) | Labelled free-living evaluation of the exact exported scoring version. |
| [#34 nightly panel](https://github.com/adidshaft/atria/issues/34) | Shared settled-cycle provenance and reference/physical acceptance for the five biomarkers. |
| [#23 onboarding](https://github.com/adidshaft/atria/issues/23) | Fresh-container physical pairing, first samples, persistence and reconnect. |
| [#22 background lease](https://github.com/adidshaft/atria/issues/22) | Actual iOS lease-expiration callback, durable prefix survival and automatic HR recovery. |
| [#2 recovery qualification](https://github.com/adidshaft/atria/issues/2) | Qualified post-wake window and mature reference-validated baseline; personal-baseline tier stays separate. |
| [#3 HR/strain validation](https://github.com/adidshaft/atria/issues/3) | Independent rest/high-effort reference and profile-sensitivity evidence. |
| [#5 trends](https://github.com/adidshaft/atria/issues/5) | Consistent day/cycle windows, real history and correctly labelled confidence. |
| [#6 HealthKit HRV](https://github.com/adidshaft/atria/issues/6) | Independent HRV qualification plus physical write/readback proof. |

Previously closed gates are historical acceptance decisions. They do not prove
new transport paths, new sensor formats or newer product-wide requirements.

## Verification and publication

A fresh run of `python3 test_handoff_static_checks.py` on local `0447c592`
completed **189 tests with 77 failures**. This is not a result for `main` or
published `dev`. The aggregate `test_handoff_local.sh` stops at that stage, so
later audit commands need separate execution while it is red. No GitHub Actions
workflow currently provides a required integration check.

The local R10/R11 test class has five tests, three of which skip without an
intentionally private biometric fixture. The session's five-test local pass is
not a public clean-clone pass. Add synthetic public fixtures; never upload the
private capture just to remove skips. See [contributing](../CONTRIBUTING.md).

Raw evidence, health samples, device identifiers, machine paths and signing
material need review before publication. Build-directory ignore rules are
housekeeping, not evidence deletion. Existing archives and the ongoing capture
remain intact. Historical protocol/handoff notes retain their dated context;
this summary does not rewrite their experiments as current product promises.
