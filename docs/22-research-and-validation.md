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

- RR stream — **DEVICE-MEASURED 2026-06-29 (worn strap, ~3.5 min at rest), see audit below.** RR *does* flow at rest, entirely via **0x2A37** RR-flag; proprietary **0x28 realtime is never armed at rest** (`rr_source_0x28_*=0`), by design (avoids the prior full-protocol regression). Remaining: still validate the 0x28 realtime-arming sequence for the *active* path, and improve at-rest contact stability (see below).
- **HRV input — CONFIRMED GAP (see 2026-06-29 audit below):** Atria's HRV baseline is NOT restricted to a sleep/morning window; any session ≥5 min with `localRMSSD` is accepted (Sessions.swift:2318), unlike resting HR which checks `.sleepCandidate` (Sessions.swift:2303). Fix is gated on the RR-stream question and needs a worn strap to verify.
- Ectopic rejection — **CONFIRMED WIRED.** RR is range-filtered (300–2000 ms) and ectopic-cleaned (±20% of local median of ±2 neighbours), plus an HR-mismatch drop, before RMSSD/SDNN/pNN50 (HRV.swift:43,103,121-122,130,136); only `kept` (not raw) feeds the metrics. `kept/raw` confidence is computed (HRV.swift:136) and surfaced in the Vitals/Collection section (AtriaVitalsCollectionSections.swift:1963); on the Overview glance card it is mapped to "Personal baseline" rather than a raw "% kept" (AtriaOverviewSections.swift:1733-1738) — acceptable, minor.
- Baseline gating — **CONFIRMED WIRED.** HRV/RHR/recovery/body-age estimates are gated on `baselineSamples >= PersonalBaseline.trustedMinimumSamples` (=14, Insights.swift:15) at AtriaAnalytics.swift:159,209,945,1020; until then they return honest `.learning` states with `N/14` detail (no fabricated numbers). UI surfaces "Building baseline" badges; the explicit `N/14` count shows on the disconnected overview + accessibility text but NOT on the connected dashboard metric cards (minor honesty/informativeness nit — candidate to surface the count there too).
- Historical backfill: validate the historical RR layout against an external RR/IBI reference to unlock offline-time metrics.
- Sleep staging + SpO2: manage expectations to the ~60-80% industry ceiling; do not over-claim.

## 2026-06-29 — analytics gate audit (verifying workflow, adversarially checked)

Traced five accuracy gates compute → store → UI, each finding re-checked by an independent skeptic agent that opened the cited `file:line` and tried to refute the "surfaced" claim.

| Gate | Computed | Gated correctly | Surfaced (verified) |
|---|---|---|---|
| lnRMSSD z-score vs personal baseline | ✅ | ✅ (`hrvTrusted`, ln mean/SD, sd>0.1) | ✅ info sheet `Text(zone.targetSummary)` (AtriaMetricTargets.swift:344) |
| Ectopic RR cleaning (300–2000 ms, ±20%) | ✅ | ✅ | ⚠️ partial — confidence in Vitals footnote only; Overview maps to "Personal baseline" |
| Morning/sleep HRV window | ❌ **not applied** | ❌ | ❌ |
| ≥14-night baseline gating | ✅ | ✅ | ⚠️ partial — "Building baseline" shown; `N/14` only off the connected cards |
| ACWR + monotony | ✅ | ✅ (acute≥3, chronic≥14) | ✅ `hero.loadSignalSummaryText` (AtriaOverviewSections.swift:2178) |

**Headline (high-value, confirmed by skeptic):** HRV samples are not restricted to a sleep/early-morning window before entering the personal baseline / recovery.
- Evidence: `baselineLearningEvidence` accepts HRV on `localRMSSD != nil && duration >= 5*60` with no time-of-day/sleep gate (Sessions.swift:2318-2326), despite the misleading `"local_hrv_window"` label. Consumed via `baseline.learn(fromResting:hrv:at:)` at Sessions.swift:3903-3905 and 3934-3936. Contrast: resting HR uses the `.sleepCandidate` detection (Sessions.swift:2303-2306). The overnight window (`startHour >= 20 || startHour <= 3 || endHour <= 10`) already exists at Sessions.swift:2223/7611 but is never applied to HRV intake.
- Consequence: daytime RMSSD can pollute the HRV baseline, diverging from the WHOOP-like sleep-derived HRV the headline metric implies.
- **Why not fixed in this pass:** the fix changes baseline composition and recovery scores and cannot be visually confirmed on the BLE-less simulator. It also depends on the unresolved RR-stream question — a hard overnight-only gate could *starve* the HRV baseline (never reach 14 nights) if RR does not stream reliably during sleep. Must be device-verified with a worn strap.
- **Proposed phased fix (RR-aware, do on device):** (1) tag each accepted HRV sample with its window origin (overnight via the existing 2223 predicate vs daytime) instead of dropping; (2) once device logs confirm RR flows overnight, prefer overnight samples for the baseline and fall back to daytime only while overnight coverage is thin; (3) add a deterministic `LabelCheck` (AtriaAnalytics.swift calibration harness ~line 1480+) asserting a daytime-only RMSSD session is rejected/deprioritised once overnight coverage exists, so the gate is regression-tested without a strap.
- Minor follow-ups: dead `hrvNarrative` computed at AtriaHomeView.swift:2652-2654/2880-2882 but never rendered (either surface or delete); surface `N/14` on connected metric cards; consider a subtle "% kept" confidence affordance on the Overview HRV card.

## 2026-06-29 — RR-at-rest device measurement (worn strap, "ADIDSHAFT'S WHOOP" 4.0)

Captured live via `/usr/bin/log` is root-gated on devices, so used `devicectl device process launch --console --terminate-existing com.adidshaft.atria --atria-enable-debug-logs` (NSLogv → stderr) for ~3.5 min at rest. (Note: `log` is shadowed by a shell builtin — must call `/usr/bin/log`; device `log collect` needs sudo.)

**Verdict: "RR doesn't flow at rest" is NOT reproduced.** The RR pipeline is healthy at rest; the limiters are contact-quality gaps and baseline maturity, not a missing stream.
- **Source:** RR arrives 100% via `0x2A37` (`rr_source_2a37_values` climbed 2→1594 over the window). `rr_source_0x28_decoded_values=0`, `rr_source_0x28_used_values=0` throughout — 0x28 realtime is deliberately skipped at rest (`mode=standard_hr_only`, `realtime_start=skipped`, `historyOnly status=arming realtime_start=skipped`).
- **Window fills:** the 5-min RMSSD window reached `window=299–300` with `raw ≈ 380–394` RR/window. Ectopic cleaning confirmed live: `kept` 99–100%, `conf` 99–100, only 0–2 `rejected_delta_over_20_percent` and occasional `rejected_hr_mismatch=1`; `rejected_out_of_range=0`.
- **Contact gaps are the real issue:** `rr_quality state` oscillated `learning → poor_contact → ready → poor_contact`, driven by `max_rr_gap_s` (≈2s ⇒ ready; 8–10s ⇒ poor_contact), with one ~110s dropout (`max_rr_gap_s=110.7`). Improving at-rest contact stability (fit-check coaching) would do more for HRV than touching the protocol.
- **Readiness is baseline-gated, not RR-gated:** `hrv ready=0 reason=window` persisted *even when window=300, conf=100, gap=2.0* — i.e. the HRV metric stays `rmssd=learning` until the ≥14-night personal baseline exists, consistent with the baseline-gating finding. So RR/HRV plumbing is fine; the user sees "learning" because the baseline isn't built, not because RR is absent.
- **Connection health caveat:** `ble_link successes=321 attempts=323 disconnects=302` and a `connection_diagnosis reason=coexistence_risk "Fit check needed"` — high lifetime disconnect churn + official-app coexistence pressure.
- **Implication for the HRV sleep-window fix (above):** gating HRV to overnight is feasible since RR flows at rest, but overnight *contact* reliability (the gaps/dropouts) is the dependency to verify before hard-gating — phase the fit-check/contact coaching first.

**Historical RR layout (secondary, for backfill validation):** `historicalData cmd=05` frames carry `strap4_v24_rr19` = 0–1 "primary" RR per frame (e.g. 767 ms) plus `k_rr64` = rolling 4-RR buffer (e.g. 567,706,724,703) and a `candidate_rr` offset map; `noop_gravity_*` IMU gravity is present and validated. Layout is decodable but still needs an external IBI reference to validate ordering/dedup before unlocking offline-time HRV.

## Sources

- [WHOOP HR/HRV validation (Physiological Reports, 2025)](https://physoc.onlinelibrary.wiley.com/doi/10.14814/phy2.70527)
- [Wearable sleep-staging vs PSG systematic review (JMIR mHealth, 2024)](https://mhealth.jmir.org/2024/1/e52192)
- [WHOOP SpO2 sensor feature (WHOOP support)](https://support.whoop.com/hc/en-us/articles/4405801024027-4-0-Sensor-Feature-Measuring-Blood-Oxygen-Levels-SPO2-)
- [WHOOP subscription backlash (Customer Contact Week)](https://www.customercontactweekdigital.com/cx-news-and-trends/articles/whoop-upgrade-customer-backlash)
- [NOOP open-source WHOOP companion (analytics reference)](https://github.com/noop-app/noop)
