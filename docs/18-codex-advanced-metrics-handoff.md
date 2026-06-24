# Codex Handoff — Advanced metrics (steps, calories, VO₂, temp, IMU, SpO₂, BP, ECG)

Date: 2026-06-25
Hard constraint: **There is NO external reference device.** Just one WHOOP 4.0
strap that connects and streams over BLE, plus the iPhone. Every metric below is
judged against that reality. Do not fabricate physiology. Atria stays local-first
(no cloud, no account); keep the static suite green (`python3
test_handoff_static_checks.py`, no `https://` clients).

## 2026-06-25 implementation status

- Profile prerequisites: **shipped in code**. `AthleteProfile` now stores
  `biologicalSex`, `weightKg`, and `heightCm` with `decodeIfPresent` migration.
  Onboarding and Settings expose compact controls for the same fields.
- Phone steps: **shipped in code**. Atria queries `CMPedometer` from start of day,
  publishes `phoneStepsToday`, distance, and floors, and shows a single `Steps`
  tile in Today. Strap-derived steps are research-only in developer surfaces.
- Active calories: **estimate-gated**. Keytel HR→EE estimate is implemented and
  only produces `kcal` when sex + weight are set; otherwise the UI stays learning.
- VO₂ max: **rough estimate-gated**. Existing summary now uses the Uth-Sørensen
  formula directly and requires measured HRmax plus 7 resting baselines before
  leaving learning copy.
- WHOOP model/capability gates: **metadata-aware scaffold shipped**. Proprietary
  WHOOP service marks a strap as 4.0-class for SpO₂/temp probes. Metadata (`0x31`)
  is now scanned for explicit, redacted generation tokens and only then promotes
  the visible label to WHOOP 4.0/5.0/MG; unknown metadata keeps the honest generic
  label. ECG/BP gates remain false unless MG is explicitly detected.
- HealthKit additions: **scaffolded and gated**. Export authorization now includes
  read-only Apple steps, sleeping wrist temperature, and cuff BP types; it never
  writes BP/ECG/SpO₂. Active energy writes only for ready workout sessions with a
  complete sex+weight profile, and VO₂ max writes only with measured max HR plus
  7 resting baselines. Both are ledgered/idempotent like existing exports.
- IMU decode: **research-gated scaffold shipped in code**. `AtriaIMUDecoder`
  now evaluates 0x33 payloads across endian/scale/offset candidates, uses gravity
  as the first validation gate, and has synthetic rest/shake self-tests. BLE logs
  decoded candidates and persists only epoch features (`imuStillnessRatio`,
  `imuMovementIntensity`, `imuActivityBursts`, `imuValidationState`) plus
  research layout evidence (`imuScale`, `imuEndian`, `imuSampleRateHz`) on
  sessions. The Data tab now has a developer-only IMU audit card summarizing
  frames, sample rate, layout, gravity status, and strap-step research counts with
  phone-step agreement; raw IMU frames are not stored and sleep/steps are not
  promoted yet.
- Skin temp + SpO₂ discovery: **research-only probe scaffold shipped in code**.
  Metadata (`0x31`) and historical (`0x2f`) frames are scanned behind the existing
  4.0-class capability gates for aggregate-only candidate offsets: SpO₂-like bytes
  in the 90-100 range and temperature-like little-endian words in the 2500-4200
  range. Logs stay `research_unvalidated`, record `metric_promotions=0`, store no
  raw payloads through the probe, and do not write oxygen/temperature to HealthKit.
- BP/ECG fail-closed UX: **shipped in Settings**. A compact Sensors section says
  ECG is unavailable on WHOOP 4.0, blood pressure requires cuff-calibrated hardware,
  and blood oxygen remains research-only with no Health export. HealthKit keeps cuff
  BP read types only; no BP/ECG/AFib samples are written or shown as strap metrics.
- UI controls: **partially verified on physical iPhone**. Top-left status now maps
  to green `Live/Connected`, yellow `Connecting...`, and red `Not Connected`.
  Top-right buttons are grouped closer as native glass controls. Theme preference
  is persisted through Settings and applied via `preferredColorScheme`; physical
  screenshot forcing for Settings was blocked because `devicectl` launch arguments
  were not delivered in this environment.
- Verification so far: `python3 test_handoff_static_checks.py` green (35), generic
  iOS build green, physical install/launch green, Today screenshots captured at
  `logs/live-device/screenshots/advanced-metrics-today-fixed-20260624T222046Z.png`
  and `logs/live-device/screenshots/advanced-metrics-healthkit-today-20260624T222808Z.png`.

## OVERNIGHT OPERATING PRINCIPLES (this run is unattended — hold these above all)

You will run for hours without a human in the loop. Four non-negotiables, in
priority order. When any change risks one of these, stop and pick the safe option.

1. **No external reference.** There is exactly ONE WHOOP 4.0 strap + the iPhone.
   Never assume a lab device, a second wearable, a cuff, or cloud truth. Your only
   references are the iPhone's own sensors (`CMPedometer`, `CMMotionManager`) and
   physics (gravity = 1 g). If a metric can't be validated against those, it ships
   research-gated, baseline-only, or not at all (§0). Never fabricate from HR/HRV.
2. **No lag.** The UI must stay scroll-smooth like the native WHOOP app. Hard
   rules: NO `.shadow`/`.blur`/Material on scrolling content; NO `ViewThatFits` in
   list cells (it renders every candidate); every list cell `Equatable` and
   `.equatable()`; heavy work off the main actor; throttle BLE→UI republishing.
   After any UI change, scroll Today/Vitals/Data on the cabled phone and confirm no
   jank. Adding a metric must not regress frame rate.
3. **UX + UI quality.** Match the existing language: rings + `AtriaMetricTile` for
   numbers, calm grouped cards (`atriaCard`/`atriaInsetCard`), glass only on
   interactive controls, status ONLY in the top pill, battery/charging only in the
   bottom bar. Fewer words, more visual cues. Text must never clip
   (`lineLimit` + `minimumScaleFactor` everywhere). Every new metric is one tile or
   ring with a ≤6-word caption, a state badge (learning/estimate/validated), and an
   info popover for any longer explanation — never inline paragraphs.
4. **Honesty / fail-closed.** No confident input → show "learning" or an estimate
   label, never a guess. Keep `python3 test_handoff_static_checks.py` green and the
   no-`https://` local-first guard intact. Commit small, build for sim then install
   on the cabled iPhone and verify with `devicectl … capture screenshot`.

Definition of done for EVERY item below: builds, static-green, installs on device,
visually verified, smooth scroll, honest label, and added to this doc's status.

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
  with a "research / unvalidated" label until it tracks a free reference. IMU and
  **SpO₂** live here: the 4.0 sensors physically exist, so it's a discovery problem,
  not an impossibility.
- **DO-NOT-SHIP** — the strap hardware fundamentally can't do it. **Blood pressure
  and ECG/AFib** are here on WHOOP 4.0 (no cuff, no electrodes). Probing/gating on a
  newer model is allowed; shipping a number from 4.0 is not.

Per-metric hardware verdicts are in the capability table at the end of §10. The
short version of the user's question — "if 4.0 can do it, build it; if it
fundamentally can't, fine": SpO₂ and skin temp CAN (sensors exist → probe); BP and
ECG fundamentally CANNOT on 4.0 (correctly excluded, gated to a future MG model).

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

## 2b. Strap naming, rename, & model detection — **PARTLY SHIPPED; gather real metadata tokens**

### What is already done (verified on a real WHOOP 4.0)
- Reads Device Information `0x180A`: Model `0x2A24`, Firmware `0x2A26`, Hardware
  `0x2A27` (Manufacturer `0x2A29` was already read). Published as
  `modelNumber/firmwareRevision/hardwareRevision` on `WhoopBLEManager`.
- **CONFIRMED FINDING: WHOOP 4.0 returns these characteristics EMPTY.** Standard
  Device Information does NOT carry the generation. So `whoopModelLabel` correctly
  falls back to "WHOOP strap". **Do not chase Device Information further — it's a
  dead end on this hardware.**
- **Rename shipped:** `customDeviceName` (persisted in UserDefaults,
  `setCustomDeviceName`) + `resolvedDeviceName` (custom → BLE peripheral name →
  "WHOOP strap", never collapses a real name). Settings → Device has an editable
  Name field; `makeCoreLiveState` now feeds `resolvedDeviceName` everywhere the
  device name shows. The peripheral name (e.g. "Adidshaft's WHOOP", seeded by the
  WHOOP account) is the recognizable identifier and is shown by default.

### What is now scaffolded — conservative proprietary metadata classification
`AtriaResearchProbe` scans metadata frame `0x31` printable runs, redacts
identifier-like tokens, and maps only explicit WHOOP generation strings to a model:
`WHOOP 4`, `WHOOP 5`, or `WHOOP MG`. Unknown metadata stays generic and does not
downgrade the existing proprietary-service 4.0-class probe capability.

### What to finish — prove the observed metadata token map on-device
Since Device Info is empty, the model/firmware/serial live in the WHOOP **metadata
frame `0x31`** (and possibly the clock/data-range responses), which the protocol
tools already classify. To get a real "WHOOP 4.0/5.0/MG":
1. With frame capture on, inspect the redacted `model_generation` /
   `model_evidence` fields from `WHOOPDBG sensor_research_probe` and
   `WHOOPDBG model_gate status=metadata_explicit`.
2. Cross-check against firmware patterns and which proprietary service generation
   responds. Build the map from observed bytes; **unknown → keep "WHOOP strap"**,
   never guess. Keep Serial out of storage (PII).
3. Surface as a read-only "Model" line under the editable Name (UI already there).

### Feature gating (the reason model matters)
Derive `WhoopModel` → `supportsSpO2` (4.0+), `supportsSkinTemp` (4.0+),
`supportsECG` (MG only), `supportsBloodPressure` (MG + cuff). Unknown model →
conservative: HR/RR/accel only, no SpO₂/temp/ECG probes. §6–10 must check these
flags first. Until the `0x31` decode lands, treat a strap that speaks the
`61080001…` service as "assume 4.0-class capabilities for probing, label honestly
as WHOOP strap in UI."

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

## 8. SpO₂ / blood oxygen — **RESEARCH-GATED (the hardware EXISTS on 4.0)**

Hardware verdict: **WHOOP 4.0 CAN do this.** 4.0 added a red+infrared pulse
oximeter specifically for blood oxygen; it is real on the band. So this is a
*discovery* problem, not an impossibility — upgraded from do-not-ship.
- WHOOP computes SpO₂ **only during sleep, on-device**, so it is unlikely to appear
  as a live characteristic. Look for it in the **historical / metadata frames**
  (`0x2f` / `0x31`) the protocol tools already read, not in the live `0x28` stream.
- **Probe:** with frame capture on across a full night, search for a byte that sits
  in the 90–100 range and only populates during the sleep window. A daytime
  **breath-hold** (SpO₂ dips ~30–60 s in) is a self-induced reference to confirm a
  candidate byte responds in the right direction.
- **You have no pulse oximeter to validate absolute accuracy**, so even when found,
  ship it RESEARCH-GATED (developer mode) + disclaimed "research, not a medical
  reading," and only for sleep. **Never estimate SpO₂ from HR/HRV** — that is fake.
- HealthKit: `oxygenSaturation` exists, but only write once a byte is proven AND
  the value tracks the breath-hold direction; otherwise read-only/none.

## 9. Blood pressure — **DO-NOT-SHIP on 4.0 (hardware can't, and that's fine)**

Hardware verdict: **WHOOP 4.0 CANNOT do this honestly.** 4.0 has only PPG — no
cuff, no two-site PTT. WHOOP's own "Blood Pressure Insights" is a **WHOOP 5.0 / MG**
beta that *requires three cuff calibration readings* as a reference. You have no
cuff, so even the 5.0 method is unavailable.
- Leave only a read-only HealthKit `bloodPressureSystolic/Diastolic` **import** stub
  (used if the user ever logs a real cuff reading elsewhere). Estimating BP from
  HR/HRV is forbidden. Gate any attempt on detecting a 5.0/MG model (§2b) AND a
  user-supplied cuff calibration — neither is present today.

## 10. ECG / arrhythmia / AFib — **DO-NOT-SHIP on 4.0 (hardware can't, and that's fine)**

Hardware verdict: **WHOOP 4.0 CANNOT do this.** ECG needs skin electrodes; 4.0 has
none. ECG is a **WHOOP MG (medical-grade, 5.0 era)** feature only. Optical HR
irregularity is not an ECG and must never be labeled AFib.
- Gate any ECG code path on detecting a WHOOP MG model (§2b); on 4.0 it is simply
  absent. Optional, heavily-gated **research** signal only: an "irregular RR" *hint*
  from RR dispersion (Poincaré SD1/SD2, pNN50 outliers) in developer mode, captioned
  "research signal, not a diagnosis, not AFib." Default off; omit if unsure.

### Hardware capability summary (WHOOP 4.0)
| Metric | 4.0 sensor exists? | Verdict |
|---|---|---|
| HR / HRV / RR / resp. rate | ✅ PPG | shipped |
| Skin temperature | ✅ thermistor | probe → baseline-only (§7) |
| **SpO₂ / blood oxygen** | ✅ pulse oximeter | **probe → research-gated (§8)** |
| Accelerometer / motion | ✅ 3-axis accel | research → unlocks steps/sleep (§6) |
| Gyroscope | ❔ (likely accel-only) | confirm during IMU probe; don't assume |
| Blood pressure | ❌ (5.0/MG + cuff) | do-not-ship (§9) |
| ECG / AFib | ❌ (MG only) | do-not-ship (§10) |
| GPS / steps-on-band | ❌ no GPS | use phone `CMPedometer` (§3) |

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

1. **Model detection** (§2b) — ship; easy; gates everything below.
2. **Profile fields** (§2) — unblocks 4 & 5.
3. **Phone steps** (§3a) — ship; already half-wired; highest user value.
4. **Active calories** (§4) — ship as estimate.
5. **VO₂ max** (§5) — small win on existing code.
6. **IMU decode** (§6) — research; unlocks strap-steps (§3b) + sleep (§11).
7. **Skin temp probe** (§7) — baseline-only IF found; else document negative.
8. **SpO₂ probe** (§8) — research-gated if a sleep-window byte is proven.
9. **BP / ECG** (§9–10) — do-not-ship on 4.0; gate to a future MG model.

Each item: build for sim, then install on the cabled iPhone
(`devicectl device capture screenshot` to verify), and keep status in exactly one
of the four tiers. When in doubt about honesty, ship "learning", not a guess.
