# Atria — Research & Validation Audit

Date: 2026-06-27. Benchmarks Atria's data reading, calculations, UI data-feeding, and user-wanted features against the actual WHOOP app and current health-science. Pairs with docs/21 (the build spec). Findings are research, not implementation status.

## 1. Data reading completeness (vs WHOOP 4.0)

- WHOOP 4.0 strap exposes: PPG heart rate, RR intervals, SpO2 (red+IR, sleep-only), skin temperature (relative-to-baseline), 3-axis IMU.
- Atria reads the same channels: HR (0x2A37), RR (proprietary 0x28 realtime + 2A37 RR-flag), battery (2A19 + battery-status), IMU/gravity (0x33), SpO2 + skin-temp probes (0x33, research-gated), events (0x30), model/firmware.
- Real gap #1 (priority): RR-stream reliability — the proprietary realtime RR stream is intermittent on some units (rr_values=0 at rest; RR flows at higher contact/activity). RR is the input to HRV, Recovery, and sleep, so it is the weakest link.
- SpO2/skin-temp are research-gated, relative-only, sleep-only — which MATCHES WHOOP's own methodology (sleep-only, signal-gated, temp relative to baseline). Appropriately conservative, not behind.
- Offline/historical sync downloads but is barred from metrics until the RR layout is validated.

## 2. Calculation accuracy (vs WHOOP & health standards)

- Benchmarks (peer-reviewed): WHOOP RHR CCC 0.91 / MAPE ~3%; HRV CCC 0.94 / MAPE ~8% vs ECG. Sleep: total-sleep-time off by -1.4 min, light/deep good, REM off by 21 min, 4-stage agreement ~62% (the industry ceiling). WHOOP computes HRV during sleep weighted to the last slow-wave phase (the "morning" reading).
- Atria methods (AtriaAnalytics): recoveryV2 = lnRMSSD z-score vs personal rolling baseline + RHR z-score + sleep + RSA respiratory; strain = TRIMP (Edwards/Banister); HRV = RMSSD; recovery bands 67/34 (WHOOP's); RSA respiratory rate; target zones at z +/-2 sigma.
- Standards verdict: lnRMSSD vs personal baseline is the sports-science gold standard for HRV-guided recovery; TRIMP is the validated training-load standard; z-vs-baseline is correct personalization; 67/34 matches WHOOP. Methods are on par.
- Accuracy depends on INPUTS, not the formulas: HRV must come from the sleep window (last SWS / morning), RR must be ectopic-cleaned (300-2000 ms range filter, drop +/-20% outliers), baselines need >=14 nights. 4-stage sleep and SpO2 sit at the ~60-80% industry ceiling everywhere.

## 3. UI data-feeding (smoothness)

- Pipeline is throttled (HR display 400-750 ms, side-effects 1500 ms) and cached/derived; connection status is a single derived source of truth. The "Live with Bluetooth off" and stuck-"Connecting" bugs are fixed; the tab-switch "lag" was a Debug-build artifact (Release 270-430 ms). Remaining is polish (live-number transitions, ~400 ms cold-render), not bugs.

## 4. What users want more (community signal)

- #1 want = NO SUBSCRIPTION (Atria's core identity). WHOOP's 2024-25 backlash is about pricing tiers and forced 4.0->5.0 upgrades.
- Highest-leverage features: (1) actionable coaching not just numbers (Part-D "(i)" sheets + a ReadinessEngine with ACWR/monotony), (2) journal/behavior -> recovery correlation, (3) a real sleep coach (need, debt, consistency), (4) recovery-scaled strain target, (5) trends/history depth incl. a year heatmap, (6) trust (reliable connection + honest "building baseline"), (7) glanceable widgets + data export.
- Atria's edge WHOOP can't match: local, no-subscription, honest, deeply customizable (drag-drop + editable target zones).

## Open research questions (to resolve)

- RR stream: validate the realtime-arming sequence (timing, withResponse vs withoutResponse, characteristic order) so RR flows steadily; confirm whether RR arrives via 0x2A37 RR-flag or 0x28 and under what contact/mode.
- HRV input: confirm Atria's HRV is computed from the sleep window (last SWS / morning) like WHOOP, not arbitrary daytime RR.
- Ectopic rejection: confirm RR is range-filtered (300-2000 ms) and ectopic-cleaned (+/-20% of local median) before RMSSD.
- Baseline gating: confirm personal baselines require >=14 valid nights before driving Recovery / target zones / readiness, with population fallback until then.
- Historical backfill: validate the historical RR layout against an external RR/IBI reference to unlock offline-time metrics.
- Sleep staging + SpO2: manage expectations to the ~60-80% industry ceiling; do not over-claim.

## Sources

- [WHOOP HR/HRV validation (Physiological Reports, 2025)](https://physoc.onlinelibrary.wiley.com/doi/10.14814/phy2.70527)
- [Wearable sleep-staging vs PSG systematic review (JMIR mHealth, 2024)](https://mhealth.jmir.org/2024/1/e52192)
- [WHOOP SpO2 sensor feature (WHOOP support)](https://support.whoop.com/hc/en-us/articles/4405801024027-4-0-Sensor-Feature-Measuring-Blood-Oxygen-Levels-SPO2-)
- [WHOOP subscription backlash (Customer Contact Week)](https://www.customercontactweekdigital.com/cx-news-and-trends/articles/whoop-upgrade-customer-backlash)
- [NOOP open-source WHOOP companion (analytics reference)](https://github.com/noop-app/noop)
