# Codex Handoff — Advanced metrics (steps, calories, VO₂, temp, IMU, SpO₂, BP, ECG)

Date: 2026-06-25
Hard constraint: **There is NO external reference device.** Just one WHOOP 4.0
strap that connects and streams over BLE, plus the iPhone. Every metric below is
judged against that reality. Do not fabricate physiology. Atria stays local-first
(no cloud, no account); keep the static suite green (`python3
test_handoff_static_checks.py`, no `https://` clients).

## 0. The validation doctrine (read first — it decides everything)

Without a lab reference you cannot prove absolute accuracy. So every metric ships
in exactly ONE of four tiers, and the tier is part of the feature:

- **SHIP** — derivable from already-validated inputs. Two free references exist:
  1. **The iPhone's own sensors.** `CMPedometer` (Apple-calibrated steps),
     `CMMotionManager` (phone IMU), `CMAltimeter`. These are ground truth you
     already own. Steps and IMU-decoding can be validated against the phone.
  2. **Physics.** At rest the accelerometer magnitude MUST equal **1 g**. That
     single fact self-calibrates the IMU scale with no external device.
- **BASELINE-ONLY** — the raw value can't be calibrated to absolute units, but a
  *personal-baseline deviation* is still honest (e.g. "+0.3 vs your 14-night
  baseline"). Skin temperature lives here IF the byte is even found.
- **RESEARCH-GATED** — decodable but unproven; ship behind `AtriaDeveloperMode`
  with a "research / unvalidated" label until it tracks a free reference.
- **DO-NOT-SHIP** — would require hardware the strap lacks or a reference you
  don't have. SpO₂, blood pressure, and ECG/AFib are here. Probing is allowed;
  shipping a number is not.

Rule of thumb: **if you'd have to estimate it from HR/HRV, it's fake — don't.**
Everything fails closed: no confident input → show "learning", never a guess.

Free reference you DO have, restated, because it unlocks most of the list:
- **Steps / IMU** → validate against `CMPedometer` + gravity.
- **Calories / VO₂** → population formulas (no per-user reference needed; label as
  estimate).
- **Temp / SpO₂ field discovery** → self-induced maneuvers (sauna, cold plunge,
  breath-hold) move a real byte in a known direction. That's your reference.

## 1. Code anchors (where to work)

- `WhoopBLEManager.swift`
  - Proprietary frame types: `realtime 0x28`, `imu 0x33`, `metadata 0x31`,
    `historical 0x2f` (see the `static let` block ~line 598). `protocolIMUFrameCount`
    already counts 0x33; `logIMUCandidate(payload:)` ~line 7015 already sees them.
  - `sendCommand(_ cmd: UInt8, _ data: [UInt8], mode:)` ~line 6417 — how to ask the
    strap for a stream (existing probes send `0x21` selector sweeps, `0x16`).
  - CoreMotion is ALREADY imported: `phoneMotionManager = CMMotionManager()` (~390),
    `phonePedometer = CMPedometer()` (~399), `recordPhoneStepEvidence(_:)` (~8288),
    `CMPedometer.isStepCountingAvailable()`. Steps are half-wired already.
  - Battery/HR/RR parsing patterns to copy for new characteristics.
- `Insights.swift` → `struct AthleteProfile` (add sex/weight/height here).
- `HealthKitExporter.swift` → add `activeEnergyBurned`, `stepCount`,
  `bodyTemperature`/`appleSleepingWristTemperature`, `vo2Max`, gated like the
  existing `heartRateVariabilitySDNN` export.
- `VO2MaxEstimateSummary` already exists (Vitals profile section) — extend, don't
  duplicate.

## 2. Profile prerequisites (do this FIRST — calories & VO₂ depend on it)

`AthleteProfile` currently has only `age`, `measuredMaxHR`, `maxHRSource`. Add:
```swift
enum BiologicalSex: String, Codable, CaseIterable { case male, female, unspecified }
var biologicalSex: BiologicalSex = .unspecified
var weightKg: Double = 0            // 0 == unknown
var heightCm: Double = 0            // optional, 0 == unknown
```
- Migrate `Codable` with `decodeIfPresent` (old profiles must still load).
- Add ONE compact onboarding step (sex + weight; height optional) and the same
  fields in `AtriaSettingsView` Profile section. Keep it minimal per the UI rules.
- Gate calorie/VO₂ confidence on these being set; otherwise show "Add weight to
  estimate calories" once, not repeatedly.

## 3. Steps — **SHIP (phone) + RESEARCH (strap)**  ← the important one

Two sources, clearly distinguished. Never blend silently.

### 3a. Phone steps (ship now)
The honest, Apple-validated source. `CMPedometer` is already instantiated.
- **Today total:** `phonePedometer.queryPedometerData(from: startOfDay, to: now)`.
- **Live:** `phonePedometer.startUpdates(from: startOfDay)` while foregrounded;
  stop on background to save power (steps backfill on next query).
- Store `phoneStepsToday: Int`, `phoneStepsSource = "CMPedometer"`,
  `phoneDistanceMeters`, `phoneFloors` (from `CMPedometer`/`CMAltimeter`).
- **UI:** a Steps tile/ring on Today or Vitals labeled **"Steps · phone"** with a
  one-line caption "Counted by iPhone motion." Honest about phone-in-pocket gaps.
- **HealthKit:** prefer to **READ** `HKQuantityType.stepCount` (iOS already logs
  it) and display, rather than writing duplicates. Only write if reading is
  unavailable. Never write strap-derived steps as if Apple-validated.

### 3b. Strap steps from IMU (research-gated — depends on §6)
Once 0x33 is decoded (§6): band-pass accel magnitude 0.5–3 Hz, count peaks with a
refractory window (~250 ms) and an amplitude threshold above rest noise.
- **Validation has a free reference:** compare strap-step count to
  `CMPedometer` over the same window. Promote out of developer-gate only when the
  strap count tracks phone steps within ~10 % across several controlled walks.
- Until then: developer-mode only, labeled "strap steps (research)".

## 4. Active calories / energy burn — **SHIP (estimate)**

Needs §2 (sex, weight, age) + restHR + maxHR (already have). Use the standard
**Keytel (2005) HR→EE** regression — kcal/min:
```
male:   EE = (-55.0969 + 0.6309*HR + 0.1988*weightKg + 0.2017*age) / 4.184
female: EE = (-20.4022 + 0.4472*HR - 0.1263*weightKg + 0.0740*age) / 4.184
```
- Integrate over session HR points (skip HR gaps > continuity limit, reuse the
  existing gap logic). **Active** calories = Σ max(0, EE(HR) − EE(restHR)).
- Store on the session: `activeCalories`, `caloriesConfidence`
  (`needsProfile` if weight/sex unset; else `estimate`). Label "estimate" in UI.
- Reuse the existing TRIMP machinery for the time-integration loop — calories and
  TRIMP share the same HR-reserve walk; add calories as a second accumulator.
- **HealthKit:** write `activeEnergyBurned` only for ready/confirmed workouts,
  gated and idempotent like the existing exports. Separate active vs basal; do not
  invent basal (or compute Mifflin-St Jeor BMR from sex/weight/height/age and mark
  it clearly "BMR estimate").

## 5. VO₂ max — **SHIP (rough estimate, improve existing)**

`VO2MaxEstimateSummary` exists. Add the **Uth–Sørensen** resting-HR estimate,
which needs only maxHR + restHR you already have:
```
VO2max ≈ 15.3 * (maxHR / restingHR)   // ml/kg/min
```
- Confidence = `estimate` (population ±10–15 %); requires a stable resting
  baseline (≥7 nights) and a credible maxHR (prefer measured over age-estimate).
- Keep it ONE number with a "rough estimate" caption. **HealthKit:** write
  `vo2Max` only when confidence ≥ estimate and maxHR is measured, gated.

## 6. IMU (accelerometer / gyro) — **RESEARCH → unlocks steps & sleep**

0x33 frames already arrive and are counted. Decode them:
1. **Layout probe.** Dump raw 0x33 payloads (developer capture already exists).
   Hypotheses: 3×`int16` (accel) or 6×`int16` (accel+gyro), little- vs big-endian.
2. **Self-calibrate with gravity (your free reference).** Hold the strap still:
   the 3-axis vector magnitude must be constant ≈ **1 g**. Sweep endian/scale
   candidates; the one giving |a| ≈ 9.81 m/s² at rest AND ≈2 g during a sharp
   shake is correct. Record `imuScale`, `imuEndian`, inferred `imuSampleRateHz`
   (from frame timestamps).
3. **Axes orientation:** tilt tests — gravity should move between axes as you
   rotate the strap 90°.
4. **Cross-check:** strap the phone next to the WHOOP; compare WHOOP-IMU magnitude
   to `CMMotionManager.deviceMotion.userAcceleration`. They should correlate.
- Store epoch features (not raw): `imuStillnessRatio`, `imuMovementIntensity`,
  `imuActivityBursts`, plus `imuValidationState`. Keep raw frames out of the saved
  session (too large) — features only.
- Gate behind `AtriaDeveloperMode` until the gravity test passes on-device.

## 7. Skin temperature — **BASELINE-ONLY, and only if the byte exists**

WHOOP measures skin temp but computes it overnight; it is NOT known to stream live
over BLE. So this is a **discovery task first**:
1. **Probe.** With frame capture on, log all non-HR characteristic payloads with
   timestamps over a long wear. Look for a byte/word that (a) sits in a plausible
   thermistor range, (b) drifts slowly, (c) follows a **circadian dip at night**.
2. **Self-reference maneuver.** Sauna/hot shower then cold exposure: a real temp
   byte moves up then down within minutes. Correlate byte position with the
   maneuver timeline. That is your calibration-free field discovery.
3. **You still cannot get absolute °C without a reference thermometer.** So ship
   **deviation only**: `skinTempRaw`, `skinTempBaseline` (rolling 14-night),
   `skinTempDeviation`, `temperatureSource`, `temperatureConfidence`. UI shows
   "+0.3 vs baseline", never "36.7 °C", unless the user later supplies a reference.
4. **If the probe finds nothing → do not implement.** Write the negative result in
   `docs/` so it isn't re-attempted blindly.
- HealthKit: only if shipped — `appleSleepingWristTemperature` is the right type
  and is itself a baseline-deviation metric, which matches.

## 8. SpO₂ / blood oxygen — **DO-NOT-SHIP (probe only)**

- WHOOP computes SpO₂ only during sleep, on-device; there is no evidence it streams
  a live SpO₂ value over BLE, and you have **no pulse oximeter to validate against**.
- Allowed: a one-time **breath-hold probe** (SpO₂ physiologically dips ~30–60 s into
  a breath-hold) to check whether any byte responds. Log it; do not surface a number.
- **Never estimate SpO₂ from HR or HRV** — that is fabricated physiology. If a byte
  is ever proven, it would still be RESEARCH-GATED + disclaimed, never a health
  readout.

## 9. Blood pressure — **DO-NOT-SHIP**

- BP needs a cuff or validated pulse-transit-time across two sites. The strap has
  neither, and you have no reference cuff. There is no honest path from WHOOP 4.0.
- The only legitimate route is **importing** a reading the user took on a real,
  validated cuff (e.g. via HealthKit `bloodPressureSystolic/Diastolic`) — but the
  user has no external device, so leave a read-only HealthKit import stub, unused,
  and document that estimation from HR/HRV is forbidden.

## 10. ECG / arrhythmia / AFib — **DO-NOT-SHIP (medical)**

- WHOOP 4.0 has no ECG electrodes; optical HR irregularity is not an ECG and must
  never be labeled AFib. The README already states Atria is not medical software.
- Optional, heavily-gated **research** signal only: an "irregular RR" *hint* from
  RR-interval dispersion (Poincaré SD1/SD2, elevated pNN50 outliers) shown in
  developer mode, captioned "research signal, not a diagnosis, not AFib." Default
  off. If in doubt, omit entirely.

## 11. Automatic sleep staging — **after §6 (sleep/wake only)**

Once IMU motion is decoded + gravity-validated, combine motion stillness + HR
relative to baseline + RR/HRV stability per epoch to label **sleep vs wake +
interruptions** only. **Do NOT claim REM/deep/light** — that needs polysomnography,
which you cannot reference. Keep the existing user-confirmed-sleep flow as the
weak label/reference.

## 12. HealthKit additions (all gated + idempotent, mirror existing exporter)

`activeEnergyBurned` (workouts), `stepCount` (read, not write),
`appleSleepingWristTemperature` (if §7 ships), `vo2Max` (if confident). Reuse the
existing ledger/idempotency + permission-separation pattern (`hrvType` export is
the template). Never write SpO₂/BP/ECG.

## 13. Testing without an external reference

- **Physics:** unit-test that the IMU decoder yields |a| ≈ 1 g on a synthetic
  rest payload and ≈2 g on a synthetic shake payload.
- **Phone-as-reference:** an on-device dev screen showing strap-steps vs
  `CMPedometer` and WHOOP-IMU vs `CMMotionManager` side by side.
- **Self-consistency:** calories must be monotonic with TRIMP; VO₂ stable when
  inputs are stable; temp deviation ~0 at baseline.
- **Self-induced maneuvers logged with timestamps** (breath-hold, sauna, walk) so a
  byte's response can be correlated offline.
- Keep `python3 test_handoff_static_checks.py` green; keep everything fail-closed.

## 14. Recommended order (value ÷ risk)

1. **Profile fields** (§2) — unblocks 4 & 5.
2. **Phone steps** (§3a) — ship; already half-wired; highest user value.
3. **Active calories** (§4) — ship as estimate.
4. **VO₂ max** (§5) — small win on existing code.
5. **IMU decode** (§6) — research; unlocks strap-steps (§3b) + sleep (§11).
6. **Skin temp probe** (§7) — baseline-only IF found; else document negative.
7. **SpO₂/BP/ECG** (§8–10) — probe + document; do-not-ship numbers.

Each item: build for sim, then install on the cabled iPhone
(`devicectl device capture screenshot` to verify), and keep status in exactly one
of the four tiers. When in doubt about honesty, ship "learning", not a guess.
