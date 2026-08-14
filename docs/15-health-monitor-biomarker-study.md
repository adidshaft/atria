# Health Monitor Biomarker Study

Status: engineering specification and validation plan. This document separates values Atria can calculate locally from values that require an authoritative WHOOP import or a validated device-specific decoder.

## Executive status

| Metric | Current Atria status | Production claim allowed now |
|---|---|---|
| Respiratory rate | Local RR/RSA estimate from qualified sleep windows | Show as an Atria estimate; do not claim WHOOP parity without paired validation |
| Resting heart rate | Sleep HR aggregation and baseline support exist | Show as a qualified local overnight RHR; exact WHOOP deep-sleep weighting is unverified |
| HRV | Qualified RR intervals and RMSSD/lnRMSSD support exist | Show local RMSSD with quality/window provenance; do not claim exact WHOOP selection parity |
| Blood oxygen (SpO₂) | Raw red/IR candidates only; no validated conversion to percent | Do not fabricate a percentage; import an authoritative value or keep unavailable |
| Skin temperature | Raw/provisional field and baseline concepts exist; absolute conversion is unvalidated | Do not show °C/°F as measured truth until calibrated; import an authoritative value or keep unavailable |

“Available” means the value has a source, timestamp/window, quality status, and a known computation path. A missing or unvalidated input must lower confidence or omit the metric; it must never be silently replaced with a guessed value.

## Required streams and their current status

- RR intervals and derived HR: available from the historical/live data paths.
- Accelerometer/gravity: available and useful for motion rejection; a public gyroscope stream is not currently established.
- Continuous raw PPG waveform: not available through the current public data path. RR intervals are sufficient for local HRV and an RSA-based respiratory estimate, but not for reproducing every vendor algorithm.
- Red/infrared optical channels: raw candidate fields exist, but they are not a calibrated SpO₂ waveform/percentage pipeline.
- Skin-temperature raw field: candidate data exists, but its engineering-unit conversion and device-specific behavior are not validated.
- Sleep episodes/stages: local detection and staging exist, but “second sleep” and exact vendor stage boundaries require paired validation.

## Metric contracts

### Respiratory rate

Use qualified sleep RR windows, reject gaps and motion-contaminated intervals, estimate the respiratory sinus-arrhythmia frequency in a physiologic band, then aggregate robustly (for example, a median of valid windows). The exact WHOOP implementation and any stated laboratory accuracy are not public contracts for Atria. Store the estimate, valid-window count, motion/gap exclusions, and algorithm version.

### SpO₂

The physiological definition is oxygenated hemoglobin divided by total hemoglobin, expressed as a percentage. That definition is not a decoder. Atria must first establish the device’s optical transfer function from red/IR signals to saturation, including LED/photodiode behavior, ambient/contact effects, quality rejection, and calibration range. Until then, raw red/IR values are research data only.

### Resting heart rate

Compute from qualified overnight sleep HR, with motion and poor-signal rejection and a documented aggregation rule. A deep/slow-wave weighting may be a useful experiment, but WHOOP’s exact weighting and final-night selection are not publicly verified. Keep the selected samples and weighting metadata so results are auditable.

### HRV

For clean successive RR intervals in the selected sleep window:

$$
RMSSD = \sqrt{\frac{1}{N-1}\sum_{i=1}^{N-1}(RR_{i+1}-RR_i)^2}
$$

Store both RMSSD and, when used by downstream models, `ln(RMSSD)`. Record ectopic/outlier rules, minimum sample count, gap limits, sleep window/stage, and whether the value is local or imported. “Deepest sleep only” is a validation hypothesis, not an established WHOOP-equivalence requirement.

### Skin-temperature deviation

After a validated raw-to-temperature conversion:

`deviation = nightly measured skin temperature − personal baseline`

Build the baseline only from accepted nights, retain the baseline version/window, and avoid presenting absolute temperature as core temperature. Before conversion validation, show the raw channel only in diagnostics, not as a user-facing °C/°F value.

## Two ways to close the SpO₂ and skin-temperature gaps

### Authoritative import (fastest path to user-facing values)

Use an official WHOOP export or API response where available, preserving the original value, unit, source, cycle/sleep window, and retrieval time. OAuth client secrets must remain server-side; they must not be embedded in the iPhone app. Imported values should be labeled `WHOOP authoritative`, not presented as Atria-decoded sensor output.

### Device-specific calibration (local decoder path)

Run a paired reference campaign and hold out entire nights/days for evaluation:

1. Skin temperature: wear the strap beside a calibrated skin-temperature reference across normal sleep, warm/cool conditions, contact changes, and recovery from exertion. Collect at least three nights initially, preferably 50–100 nights for a robust device/person model. Fit only after checking linear and nonlinear residuals; store device/firmware and calibration revision.
2. SpO₂: pair the strap with a medical-grade fingertip oximeter during stable sleep/rest windows and across a meaningful saturation range. Pair timestamps, reject motion/contact failures, and never use uncontrolled hypoxia as a casual experiment. A ratio-to-percent curve must be evaluated on held-out nights, not only on the fitting set.

Suggested release gates are provisional engineering gates, not medical certification: SpO₂ bias ≤1 percentage point, MAE ≤2 points, 95th-percentile absolute error ≤4 points, and correlation ≥0.8; skin-temperature bias ≤0.2 °C, MAE ≤0.3 °C, and correlation ≥0.9. Revisit these thresholds with a qualified clinical/measurement review before making health claims.

## Baselines and dependent scores

Maintain rolling, quality-filtered baselines for lnRMSSD/RMSSD, RHR, respiratory rate, skin temperature, sleep performance, and (once validated) SpO₂. Median/MAD is robust for early deployments; mean/standard deviation can be added after enough stable nights. Track HRmax and zones from high-confidence exercise, with an explicit fallback and provenance. Keep a 7–14 day sleep-debt history and distinguish naps from the primary sleep episode.

Stress, strain, recovery, and sleep-need/performance may consume these metrics only when their required inputs are present and sufficiently qualified. If SpO₂ or skin temperature is unavailable, the score must say which contributor is missing and either reduce confidence or use a documented partial-score policy. It must not infer normal SpO₂ or normal temperature from HR, RR, or a population range.

## Data contract for every displayed tile

Every value should carry:

- metric and unit;
- source: `Atria computed`, `WHOOP authoritative`, `reference-calibrated`, or `unavailable`;
- sleep/cycle ID and start/end window;
- algorithm and calibration revision;
- sample count, quality flags, and exclusions;
- baseline value/window and maturity state;
- confidence and a human-readable reason when partial or unavailable.

The five-metric Health Monitor is complete only when each tile has either a validated local decoder or an authoritative imported value. Until then, respiratory rate, RHR, and HRV can be useful qualified local estimates; SpO₂ and skin temperature should remain explicitly unavailable or imported-authoritative.

## Claims that require caution

The following statements should not be treated as confirmed Atria or public WHOOP contracts without independent evidence: an exact 20-second-every-30-minute SpO₂ schedule, exact deep-sleep weighting for RHR/HRV, a fixed “deepest period” rule, ±1 breath/min laboratory accuracy, and availability of a gyroscope in the public WHOOP stream. They are reasonable hypotheses to test, not assumptions to encode as facts.
