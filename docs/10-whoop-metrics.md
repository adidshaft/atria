# WHOOP-style Metrics: Recovery & Strain

The two headline metrics people actually open WHOOP for — rebuilt from heart rate
alone. Code in `Metrics.swift`.

## Strain (0–21)

WHOOP's cardiovascular-load score on a 0–21 (Borg-style) scale.

- **TRIMP** (Banister training impulse) per sample:
  `dt · HRr · 0.64 · e^(1.92·HRr)`, where `HRr = (bpm − rest)/(max − rest)`.
- `max` comes from the local athlete profile: measured HRmax or the age-estimated
  `208 - 0.7 * age` formula. Existing installs migrate the old manual `maxHR`
  setting into the measured field.
- First launch presents a local-only profile onboarding flow so HRmax source is
  explicit before Strain is interpreted. The debug launch path can complete this
  flow for cabled-device verification without touching cloud state.
- `rest` comes from the learned resting-HR baseline when available, otherwise the
  live session resting HR or 60 bpm.
- TRIMP accumulates over **all of today's sessions + the live session** (strain
  is a whole-day metric).
- For explainability, the app also logs saved+live HR-reserve zone seconds:
  `z0_lt30`, `z1_30_50`, `z2_50_70`, `z3_70_85`, and `z4_85_100`, plus
  dropped sample-gap seconds and min/max HR reserve. These zones are diagnostic
  inputs for the Gate D rest-to-max audit; they do not replace the TRIMP score.
- Mapped to 0–21 with a saturating curve: `21 · (1 − e^(−TRIMP/40))`.
- Shown as a gauge on the main screen and per-session in History.
- The app logs the active profile on device for audit:

```text
WHOOPDBG strain_profile age=<years> source=<ageEstimate|measured> max_hr=<bpm> measured_max_hr=<bpm> rest_hr=<bpm>
WHOOPDBG onboarding complete=1 age=<years> source=<ageEstimate|measured> max_hr=<bpm> measured_max_hr=<bpm>
WHOOPDBG strain_zone_summary source=saved_plus_live rest_hr=<bpm> max_hr=<bpm> samples=<n> seconds_total=<seconds> z0_lt30=<seconds> z1_30_50=<seconds> z2_50_70=<seconds> z3_70_85=<seconds> z4_85_100=<seconds> dropped_gap_s=<seconds> min_hrr=<0-1> max_hrr=<0-1> trimp_total=<n.n> strain=<n.n> confidence=<learning|local>
WHOOPDBG strain_validation ready=<0|1> rest_to_max_ready=<0|1> primary_blocker=<blockers> external_hr_reference_validated=<0|1> ... criteria=total>=600_low_z0>=60_high_z3_z4>=60_max_hrr>=0.85_stream_coverage>=75_external_hr_reference_required
```

This is a faithful *model* of strain, not WHOOP's exact proprietary formula.
Gate D cannot pass from a Strain number alone: the validation diagnostic must
show enough low-zone and high-zone exposure, sufficient stream coverage, and an
external HR reference.

## HRV from realtime RR

The iPhone now receives realtime RR intervals primarily from standard BLE Heart
Rate Measurement `0x2A37`. That parser follows the BLE flags byte, reads 8-bit
or 16-bit HR, skips optional Energy Expended, and converts little-endian R-R
intervals from 1/1024 seconds to milliseconds. Proprietary `0x28` realtime RR is
kept as supplemental diagnostics when it carries intervals, but it is ignored for
HRV while fresh `2A37` RR is active. The app computes a clinical HRV snapshot
over a rolling 5-minute window:

- RR artifact handling:
  - log every decoded RR interval, then keep only intervals from **300–2000 ms**
  - drop beats where `abs(RRn - RRn-1) / RRn-1 > 20%`
  - metrics are computed from kept beats only; rejected beats are not
    interpolated or backfilled
  - confidence = kept beats / raw beats seen
- Clean-window acceptance remains separately gated by stable skin contact and
  source-specific RR continuity, so the app does not promote HRV merely because
  HR frames keep arriving.
- RR decode logs include implied BPM and an HR/RR mismatch count for diagnosis.
  This does not change the clinical correction rule; it only highlights decoded
  intervals that are unlikely to match the frame's current heart rate.
- Metrics:
  - **RMSSD**
  - **SDNN**
  - **pNN50**
  - **lnRMSSD**
- Readiness gate:
  - the headline HRV number stays **learning** until the rolling window is at
    least 5 minutes of continuous RR coverage, has no raw RR timestamp gap over
    3 seconds, has at least 240 corrected beats, and keeps at least 75% of raw RR
    intervals. The app retains a small timing cushion so discrete beat arrivals
    do not turn a real 300-second capture into a false 299.x-second failure;
    metrics still use only the final 300-second sample window.
  - HRV collection starts only after the Heart Rate service has reported stable
    skin contact for at least 10 seconds. Contact loss resets the RR window and
    keeps the headline in **learning**.
- The main HRV card includes RMSSD, SDNN, pNN50, lnRMSSD, confidence, live RR
  tachogram, and diagnostic state. The tachogram line uses corrected RR samples;
  rejected RR artifacts are shown as orange points so they remain auditable
  without feeding HRV.
- The HRV card keeps clinical metric values in **learning** until the 5-minute
  readiness gate is met; before that it only shows quality state such as
  confidence, RR kept/raw counts, and the largest RR timestamp gap inside the
  rolling window for sparse-stream diagnosis.
- Respiratory rate is estimated from RSA in the recent tachogram when enough
  clean RR data exists. The app resamples the latest clean RR series at 4 Hz,
  scans the 6-30 breaths/minute band for the strongest spectral peak, and keeps
  respiratory rate unavailable unless that peak is strong enough to trust.

### Gate B device evidence

Verified on adidshaft's physical iPhone (`<DEVICE_ID>`) on
2026-06-12. Clean Debug build installed/launched with `devicectl`; simulator was
not used.

Key `WHOOPDBG` lines:

```text
send mode=wwr cmd=03 seq=0 ... frame=aa0800a82300030199bce9cf
cmdResp ch=61080003-... payload=24ce030002000000
frame ch=61080005 len=28 hex=aa1800ff2802079e2b6a28504a022f031a030000
hrv raw=15 kept=15 conf=100 window=11 ready=0 rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning
hrv raw=45 kept=45 conf=100 window=34 ready=0 rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning
hrv raw=15 kept=15 rejected_out_of_range=0 rejected_delta_over_20_percent=0 conf=100 window=11 ready=0 rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning
```

This verifies decode, artifact correction, artifact-rejection reason counts,
confidence, and readiness gating on device. A later debug-probe run reached a
ready 5-minute iPhone window:
`docs/evidence/gate-b/20260612T140338Z-probe-command-ready-window.md`
(`rmssd=44.2`, `conf=92`, `window=300`, `max_rr_gap_s=2.1`).

Latest physical iPhone ready-window evidence:

- `docs/evidence/gate-b/20260613T132138Z-gate-b-2a37-reset-keep-recording/`
- Standard `2A37` payload example:
  `standardHR payload=10435f03 hr=67 rrnum=1 rr_ms=843`.
- Ready capture: `raw=345`, `kept=315`, `conf=91`, `window=300`,
  `max_rr_gap_s=2.8`, `quality_resets=2`, `rmssd=46.7`, `sdnn=58.6`,
  `pnn50=25.6`, `lnrmssd=3.84`, `resp=12.0`.
- Independent replay found a strict `2A37` window with `raw=348`, `kept=318`,
  `conf=91.4`, `max_gap_s=2.845`, and `rmssd_ms=52.1`.
- `rr_source_0x28_used_values=0`, so this window did not estimate HRV from HR or
  depend on proprietary zero-RR frames.
- Saved RR-ledger replay status was verified on the physical iPhone in
  `docs/evidence/gate-b/20260613T143600Z-rr-ledger-replay-status-device-verify/`.
  On relaunch, `rr_ledger_summary` replayed `1298` saved real RR points and
  found `best_ready=1` (`raw=347`, `kept=317`, `conf=91`,
  `max_rr_gap_s=2.8`, `rmssd=46.0`) while `gate_status gate=B` stayed
  `reference_pending` with `reference_validated=0`.
- The same replay-status smoke saw no fresh live RR
  (`standard_2a37_rr_values=0`, `realtime_rr_fraction=0.000`), proving the app
  preserves and reports saved real RR without fabricating missing intervals from
  HR-only frames.

Prior ready-window evidence:

- `docs/evidence/gate-b/20260613T-gate-b-sleep-continuity-result/`
- Adaptive gate: `rr_fraction_0.978`, `max_rr_gap_s=1.9`.
- Ready capture: `raw=299`, `kept=288`, `conf=96`, `window=300`,
  `max_rr_gap_s=2.0`, `rmssd=49.0`, `sdnn=69.6`, `pnn50=32.6`,
  `lnrmssd=3.89`, `rejected_delta_over_20_percent=11`, `interpolated=11`.
- Whole run: `realtime_rr_fraction=0.944`, `rr_values=344`,
  `historical_2f_frames=0`, pulled CSV rows `1230`.

The full Gate B exit remains open until a full 5-minute iPhone capture is
compared against a reference recording within +/-5 ms RMSSD.

The HRV card now exposes that final reference workflow directly. Export creates
the best saved 300-second real-RR package for comparison, and Import copies a
selected independent RR/IBI CSV into `Documents/atria-reference/rr-reference.csv`
before running the existing Gate B validator. Physical iPhone evidence in
`docs/evidence/gate-b/20260614T174320Z-rr-reference-import-export-ui-device-verify/`
verified the dashboard export wrapper with
`WHOOPDBG rr_reference_export_ui status=ok`; the exported window was real and
ready for comparison (`raw=368`, `kept=361`, `conf=98`, `max_rr_gap_s=1.8`,
`rmssd=32.7`) but stayed `reference_validated=0` until an independent reference
is imported.

## Recovery (%) — confidence-gated v2

WHOOP's green/yellow/red readiness score.

WHOOP's recovery is driven mainly by **HRV** + resting HR. The app now keeps that
contract explicit:

- **High confidence** requires a validated HRV value plus at least **7 validated
  personal HRV baseline samples**. The score uses lnRMSSD z-score vs the rolling
  personal baseline, blended with resting-HR z-score:
  `score = clamp(50 + 16 * (0.75 * lnRMSSD_z - 0.25 * RHR_z), 1...99)`.
- **Learning** is shown when HRV exists but the HRV baseline is not mature yet.
- **Fallback** is shown when HRV is unavailable; the ring may still show the
  resting-HR proxy, but it is labeled `fallback`, not presented as full recovery.
- Bands match WHOOP: **green ≥67**, **yellow 34–66**, **red <34**.
- Only HRV that passed the 5-minute RR gate can be saved into the baseline.
  Failed or aborted captures remain `learning` and do not train Recovery v2.
- The Recovery ring displays the confidence state and the reason (`learning HRV
  baseline 3/7`, `HRV learning - RHR fallback`, or the z-score explanation).
- The app logs the decision on device:

```text
WHOOPDBG recovery_v2 percent=<n|-1> confidence=<learning|fallback|high> uses_hrv=<0|1> detail=<reason>
```

> Sleep is only a low-confidence local candidate until motion/IMU is validated,
> so high-confidence Recovery is still HRV + resting HR. HR-only sleep can
> improve local RHR evidence, but it does not become WHOOP-style sleep staging.

## Why these are buildable without a subscription

These derive from the standard Heart Rate service, the local realtime RR command
channel, and locally-learned baselines. No WHOOP cloud, account, or subscription
is used.

## Daily guidance (Strain Coach)

WHOOP's core daily decision loop, in `Dashboard.swift`:

- Recovery sets an **optimal strain target**: `6 + recovery/100 · 13` (~6 at 0%,
  ~19 at 100%).
- The target is shown only when Recovery v2 is **high confidence**. If Recovery is
  `learning` or `fallback`, the coach stays in baseline-building mode and does
  not show a push/rest target from an unvalidated proxy.
- Today's strain vs that target drives the call:
  - recovery <34% → **Prioritize recovery** (red)
  - strain < target−2 → **Room to push** (green)
  - within ±2 → **On target** (blue)
  - strain > target+2 → **Ease off** (orange)
- Shown as a `DailyGuidanceCard` with a 0–21 bar: filled = current strain, marker
  = today's target.
- The on-device decision is logged:

```text
WHOOPDBG guidance_decision recovery=<n|learning> recovery_confidence=<learning|fallback|high> target=<n.n|learning> strain=<n.n> state=<learning|ready> reason=<rule>
```

## Activity detection

Saved HR sessions are classified locally after capture:

- **Workout** uses sustained elevated HR: at least 10 minutes, enough total time
  above `max(70% HRmax, resting HR + 30)`, and a continuous elevated bout. This
  is medium confidence because it is HR-only, and a single peak or short spike
  cannot classify a workout.
- Workout readiness is gap-aware. HR sample gaps over `5s` are treated as
  missing coverage, reset sustained elevated bouts, and are excluded from the
  observed duration used by the detector. Missing HR is never filled in from
  wall-clock time.
- Post-run audits expose why a candidate failed without changing production
  detection. `tools/analyze_workout_store.py` now prints HR percentiles
  (`p90`, `p95`, `p99`), counts above the production threshold and borderline
  threshold, and a `failure_class` such as `hr_signal_below_workout_band`,
  `fragmented_stream`, `insufficient_workout_band_time`,
  `insufficient_elevated_time`, or `insufficient_continuous_bout`. These fields
  are diagnostic only: a near miss cannot become a workout unless the normal
  sustained-HR gates pass with real samples.
- Saved workout replay scans broad 5-minute-spaced windows from 10 to 90 minutes
  across saved chunks, then applies the same sustained-HR and gap gates. Window
  scanning can reveal a valid real workout hidden inside a long capture, but it
  never lowers HRR50, fills gaps, or promotes a short spike. App logs and the
  analyzer both expose p95/p99 HR and samples above threshold so a low wrist-HR
  distribution is distinguishable from a stream-coverage failure. The offline
  analyzer rounds HRR thresholds to match Swift's positive-BPM rounding.
- **Sleep candidate** uses an overnight low-HR window of at least 3 hours. This
  is intentionally low confidence until strap motion/IMU is decoded; the app
  must not call HR-only sleep a final sleep-stage result.
- Resting HR for HR-only sleep-candidate rollups uses the 5th percentile of the
  overnight HR window. Non-sleep sessions use the session 10th percentile
  fallback. The selected source is logged so RHR is auditable.
- Each detection is logged for device evidence:

```text
WHOOPDBG activity_detect kind=<Workout|Sleep candidate> confidence=<low|medium|high> duration_s=<seconds> avg_hr=<bpm> peak_hr=<bpm> reason=<rule>
WHOOPDBG resting_source label=<session> value=<bpm> source=<hr_only_sleep_candidate_5th_percentile|session_10th_percentile> stable_10th=<bpm> sleep_5th=<bpm>
WHOOPDBG live_workout tick=<n> samples=<n> duration_s=<seconds> observed_duration_s=<seconds> dropped_gap_s=<seconds> max_gap_s=<seconds> gap_count=<n> avg_hr=<bpm> peak_hr=<bpm> rest_hr=<bpm> max_hr=<bpm> threshold_hr=<bpm> elevated_s=<seconds> longest_bout_s=<seconds> ready=<0|1> label=<session>
WHOOPDBG workout_replay_summary sessions=<n> ready=<n> best_label=<session> status=<ready|learning> reason=<rule> duration_s=<seconds> observed_duration_s=<seconds> dropped_gap_s=<seconds> max_gap_s=<seconds> gap_count=<n> p95_hr=<bpm> p99_hr=<bpm> samples_above_threshold=<n> samples_above_borderline=<n> hr_distribution_below_workout_band=<0|1> elevated_s=<seconds> required_elevated_s=<seconds> longest_bout_s=<seconds> required_bout_s=<seconds> source=saved_sessions
WHOOPDBG workout_validation status=<ready|learning> reason=<rule> label=<requested> matched_label=<session> duration_s=<seconds> elevated_s=<seconds> required_elevated_s=<seconds> longest_bout_s=<seconds> required_bout_s=<seconds> workouts_matching=<n>
```

Latest current-device forensics after the long/gym wear:
`docs/evidence/gate-e/20260614T033509Z-current-device-store-forensics/`. The
best aggregate stayed `ready=0` with `stream_coverage_percent=37`, `p95=87`,
`p99=106`, `peak=120`, `threshold=121`, `samples_above_threshold=0`,
`samples_above_borderline=44`, and
`failure_class=hr_signal_below_workout_band`. The active journal peaked at
`87` bpm. This is why the app must keep the workout in `learning` instead of
weakening HRR50 or filling gaps.

Latest broad-window replay after the cabled device checkpoint:
`docs/evidence/gate-e/20260614T171800Z-broad-workout-window-optimized-device-verify/`.
The app built, installed, launched, and emitted deep Gate E status with
`workout_saved_ready=0`, `best_source=stitched_observed_chunks`,
`stream_coverage_percent=85`, `threshold_hr=121`, `p95_hr=91`, `p99_hr=106`,
`samples_above_threshold=5`, `elevated_s=3`, and
`next_action=validate_wrist_hr_underreporting_or_profile_before_more_workouts`.
The matching analyzer replay scanned `640` single windows and `1572` aggregate
windows with `total_ready=0`, confirming there is no hidden valid HRR50 workout
window in the saved store.

The Gate E replay now also emits a compact on-device
`WHOOPDBG hr_profile_validation_plan` whenever the best workout candidate has
enough inspected data but the wrist-HR distribution stays below the personalized
HRR50 workout band. This line repeats the decisive evidence (`p95_hr`, `p99_hr`,
`threshold_hr`, samples above threshold/borderline, coverage, and required
elevated seconds) and points to the existing independent-reference flow:
export the Atria HR package, then validate against `Documents/atria-reference/hr-reference.csv`
or a non-Atria HealthKit HR source. It does not count a workout, estimate
intensity, or change thresholds; Gate E remains learning until sustained real HR
or external HR validation proves the profile/strap signal.

Physical iPhone evidence in
`docs/evidence/gate-d/20260614T172603Z-hr-profile-validation-plan-device-verify/`
verified the plan line and pulled an HR reference package. The same run showed
HealthKit access is available but not yet useful as an independent reference:
`healthkit_total_hr_samples=43371`, `healthkit_atria_hr_samples=43371`, and
`healthkit_independent_hr_samples=0`.

The same proof gap is now visible in the dashboard diagnostics, not only in
launch logs. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T173043Z-hr-reference-ui-device-verify/` verified
`WHOOPDBG hr_reference_ui state=missing_independent_hr ... workout_p95_hr=91
workout_p99_hr=106 workout_threshold_hr=121 workout_samples_above_threshold=5
workout_elevated_s=3 workout_required_elevated_s=1200`. The UI remains
fail-closed and points to independent HR proof instead of weakening the detector.
The same card now exposes the reference workflow directly: Export creates the
Atria HR package for comparison, Import copies a selected independent CSV into
`Documents/atria-reference/hr-reference.csv`, then immediately runs the existing
Gate D validator. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T173634Z-hr-reference-import-export-ui-device-verify/`
verified the dashboard export path with
`WHOOPDBG hr_reference_export_ui status=ok ... reference_validated=0`; import
still cannot pass without a true non-Atria HR source.

## Trends and anomalies

History renders local 7/30/90-day trend windows from saved sessions:

- Recovery is averaged from the same confidence-gated Recovery v2 method; if HRV
  is unavailable it remains the labeled RHR fallback/learning value.
- HRV averages only validated saved RMSSD values. Missing HRV is shown as
  `learning`, never inferred from HR.
- RHR uses the sleep-candidate 5th percentile when an overnight low-HR window is
  present, otherwise the saved session's stable resting estimate.
- Strain uses the profile HRmax and learned resting HR.
- Anomalies require at least 3 sessions in the window and are limited to clear
  high outliers for RHR or Strain.
- Device verification logs include coverage, the HRV reference gate, anomaly
  labels, and the same short explanation shown in History:

```text
WHOOPDBG trend_summary sessions=<n> rest_hr=<bpm> max_hr=<bpm> windows=3
WHOOPDBG trend_window days=<7|30|90> sessions=<n> coverage_days=<n> coverage_percent=<n> confidence=<learning|partial|high> recovery=<n|learning> hrv=<n|learning> hrv_state=<reference_pending|validated_samples_N> rhr=<n|learning> strain=<n.n|learning> anomalies=<n> anomaly_flags=<none|...> detail=<coverage_sparse...>
```

## HRV on iPhone — status

Gate A is unblocked. The full realtime/HRV protocol is validated on macOS and now
on iPhone: writing `[0x23,0x00,0x03,0x01]` to TX `61080002` via
write-without-response after `61080005` notify confirmation produces CMD_RESP on
`61080003` and REALTIME_DATA (`0x28`) with HR + RR intervals on `61080005`.
