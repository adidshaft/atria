# Atria vs WHOOP — metric truth, patents, and replacement plan

Status: analysis only. No product code was changed for this document.  
Branch context: `codex/whoop-remaining-product-gaps`  
Written: 2026-08-14  
Scope: what Atria actually reads, how every hero metric is calculated, what public WHOOP patents/docs support, what is scientifically sound, what is product fiction, and what it would take to replace the official WHOOP app **without WHOOP cloud APIs**.

Binding in-repo policy this document respects:

- `docs/16-metric-authority-and-confidence-policy.md`
- `docs/WHOOP_REMAINING_PRODUCT_GAPS.md`
- `docs/14-spo2-skin-temperature-decoder-validation.md`
- `docs/17-muscular-load-and-fusion.md`
- `docs/WHOOP4_PROTOCOL_FINDINGS.md`

---

## 0. Do not touch: motion, steps, IMU, gait

Atria has spent a large amount of physical-capture time on Gate 4 (strap-only steps / motion). That work includes counted walks, planted-feet arm-motion controls, v24 tick scaling, gravity-cadence models, R10 lease failures, and an explicit all-day-authority withdrawal. **This document must not be used as a license to reopen that stack.**

### Hard rule

Do **not** change any of the following unless a proposed change is *already proven* on a new held-out physical walk **and** a planted-feet negative control, on this strap/firmware, on a frozen build:

- `AtriaWhoop4MotionTickStepModel` and `whoop4-motion-ticks-to-steps-v1`
- `AtriaWhoop4GravityCadenceStepModel`
- v24 motion tick @88–89 scaling (including the 155/132 ticks-per-step constant)
- live IMU / R10 / `0x33` / `0x2B` / cmds `0x3F`, `0x6A`, `0x69` product policy
- `AtriaStrapMotionAvailability` and open-cycle vs closed-archive step presentation
- sleep-motion qualification that consumes gravity / stillness
- phone-pedometer fusion as a replacement for strap steps
- “just use HealthKit steps” as day authority
- planted-feet / arm-swing heuristics that were already burned in Gate 4

### Why this rule exists

- Gate 4 is **not sealed for all-day authority**. The protocol ledger is explicit: a workout-local counted walk can pass while the autonomous all-day selector fails.
- Earlier models were fooled by planted-feet arm motion. That is the exact failure that makes a “smarter detector” look good in the lab and lie on a desk.
- High-rate IMU leases (`0x3F` / `0x6A` / R10) have physically killed the BLE link (`CBErrorDomain: 6`) on this iPhone. Reopening that path is a reliability regression, not a feature.
- A wrong daily step total is less damaging than a week of broken sleep-motion qualification, missed history drains, or a strap that will not stay connected.

### What this document is allowed to say about steps

- Current product posture (fail-closed, complete vs partial vs unavailable, live evidence max age 15 s, prior-cycle receipts not attributed to today) is **correct engineering**.
- Do not promise WHOOP-parity all-day steps.
- Do not rip the tick model out.
- Do not add a second competing step authority.
- If Gate 4 is ever reopened, it is a **physical validation program**, not a formula tweak in this assessment.

If a later section mentions motion, it is only as context for sleep/wake or activity *review* prompts. It is not a backlog item.

---

## 1. Executive verdict

Atria is already closer to a real WHOOP replacement than almost any unofficial WHOOP client. It is **not** scientifically finished. It will never become “WHOOP but free” by copying unpublished WHOOP scores.

WHOOP’s published patents and support pages do **not** give production formulas. They give **structure**:

- last slow-wave HRV window before wake
- intensity from heart-rate reserve, scaled onto 0–21
- sleep need ≈ baseline + strain + debt − naps
- recovery as a mix of HRV, RHR, sleep (later: respiration, skin temp, SpO2, cycle)

The weights, sleep-stage model, SpO2 transfer function, and 0–21 calibration are trade secrets. Matching their numbers is the wrong target. Matching the **daily decisions** those numbers support, with measurements you can defend, is the right one.

**“Nothing provisional, everything accurate” and “full WHOOP clone including stages, Healthspan, muscular Strain, and five-signal stress” cannot both be true** on a 4.0 whose SpO2/temp decoders are unvalidated, with no PSG set and no outcome-calibrated Recovery.

WHOOP itself is provisional. They just do not label it.

The winning Atria is automatic where the signal is real (HR, HRV, RHR, cardio load, sleep hours) and quieter than WHOOP where a wrist cannot measure the thing (EEG stages, biological age, medical SpO2, “validated” readiness).

---

## 2. What the strap actually emits vs what Atria uses

WHOOP 4.0 (“Harvard”) hardware: green PPG (HR + beat timing), red/IR LEDs, thermistor, 3-axis IMU, almost certainly a gyro that is **not** in the public historical stream.

GATT the app talks to:

- Proprietary service `61080001-8d6d-82b8-614a-1c8cb0f8dcc6`
  - `61080002` command TX
  - `61080003` command RX
  - `61080004` live/data (not production history)
  - `61080005` **production historical channel** (`0x2F` after `SEND_HISTORICAL_DATA 0x16`)
  - `61080007` diagnostic / research
- Standard Heart Rate `0x180D` / `0x2A37` — **primary live HR + RR**
- Battery `0x180F` / `0x2A19` (notify is truth; first read can be stale `0x64`)
- Device Info `0x180A`

There is **no** standard step characteristic on this firmware.

### Signal table

| Signal | Source | Product use |
|---|---|---|
| Live HR | `0x2A37` | Primary. Correct. |
| Live RR / IBI | `0x2A37` bit 4 | Primary HRV. Artifact-gated 300–2000 ms; drop >20% successive; implied-HR mismatch ≤35 bpm. **No interpolation.** |
| Historical HR + RR | `0x2F` v24 HR@17, RR@19 | Overnight backfill after drain. Solid for this firmware. |
| Gravity XYZ | `0x2F` v24 f32 @36/40/44 | Sleep motion qualification, physiology gate. **Do not reopen casually.** |
| Motion tick u16 | v24 @88–89 | Step *candidate* after the v1 tick model. **Do not reopen casually.** |
| Battery / contact / clock | GATT + `0x30` / `GET_CLOCK 0x0B` | Quality gates. |
| Proprietary live RR `0x28` | Compact realtime | Diagnostic only. Unreliable as primary. |
| High-rate IMU / gyro (R10) | `0x2B` / `0x3F` / `0x6A` | Research. Kills this phone’s BLE link. |
| Optical words @64/@66 | Historical v12/v24 | **Not decoded.** Not red/IR. Not SpO2%. |
| Skin ADC @68 | Historical v12/v24 | Relative raw only. **No °C.** |
| Native vendor step total | — | **Does not exist** on this GATT map. |

If a metric cannot be built from live/historical HR+RR, gravity-as-stillness, user logs, and the already-frozen step model, it is research, an estimate, or fiction.

---

## 3. Public WHOOP / patent structure (not their production code)

### US9750415B2 — HRV with sleep detection (Whoop, Inc.)

Disclosed, and therefore fair game as *physiology structure*:

1. Detect sleep (accelerometer and/or HR; they also mention GSR).
2. Record HR continuously **without** necessarily computing HRV all day.
3. Detect wake.
4. Find the most recent slow-wave period before wake.
5. Inside that period, pick a predetermined-duration window with the best data-quality metric.
6. Compute HRV there.
7. Feed that HRV, and optionally sleep duration / stage information, into a recovery score.

Atria already adopted (4)–(6) as **window selection only** (`AtriaRecoveryHRVWindowSelection`). It does **not** copy undisclosed WHOOP weights. That is the correct IP/science split.

The same patent describes **intensity** (Strain’s ancestor):

```text
v(t) = (HR(t) − RHR) / (MHR − RHR)
I     = ∫ w(v(t)) dt
N     = I / (w(1) · 24 h)
score = 21 · f(N)     # f is arctan / sigmoid / “canonical workout” fit
```

`w` is unpublished. They talk about weighting harder above anaerobic threshold. That is the same *idea* as Banister’s exponential, not the same function.

Also disclosed: Recovery displayed as 0–100 with qualitative bands; example thresholds in the figures are ~66% and ~33%. Atria’s green ≥67 / yellow 34–66 / red <34 is the public vocabulary, not stolen math.

### US11185292B2

Recovery described as a **weighted combination** of HRV, resting HR, sleep quality / sleep score, plus data-quality metrics. Still no coefficients.

### US20240252121A1 — determining sleep need

Sleep need as a function of physiological measurements, with a debt term that is **scaled and capped**. Atria adopted the *capped debt* structure with its own 8.0 h cap and 0.5 credit. It does not reproduce undisclosed WHOOP coefficients.

### US20240188865A1 — stress (cited in Atria stress model)

Direction only: dynamic HR/HRV weighting, periodic scoring, motion adjustment, a timeline. Atria’s equation and constants are its own (`AtriaPhysiologicalStressModel` v3).

### What WHOOP publicly lists today (support / locker copy, 2025–2026)

Recovery inputs (current support language): HRV, RHR, respiratory rate, sleep duration/quality, skin temperature, SpO2, menstrual-cycle phase when applicable.

HRV practice (public + long-standing member description): RMSSD, often from last deep sleep, vs a ~14-day personal baseline. Some independent writeups claim `lnRMSSD`. WHOOP has also discussed HRV-CV (7-day SD / 7-day mean) as a *research/insight* metric, not as the Recovery hero.

Strain: 0–21, all-day cardiovascular load, later plus muscular load on strength. Formula unpublished.

Sleep: duration, stages, need, consistency, efficiency, planner tiers (Peak / Perform / Get By).

Hardware extras: Health Monitor (HRV, RHR, resp, SpO2, skin temp). WHOOP 5.0 / MG add Healthspan / WHOOP Age, better sensors, and on MG cardiovascular features Atria cannot grow from a 4.0.

**None of the above is a license to claim numerical parity.**

---

## 4. Metric-by-metric: formula, class, verdict

Legend:

- **Keep** — scientifically or product-correct; do not rewrite
- **Improve** — same authority, better inputs or labeling
- **Demote / kill** — do not lead the product with this
- **Do not touch** — motion/steps or other high-cost physical work

Science class:

- *Measured* — decoded sensor or user log
- *Literature* — published algorithm, citable
- *Engineering heuristic* — Atria-owned, honest, unvalidated against outcomes
- *WHOOP-shaped UX* — familiar product loop, not WHOOP math

---

### 4.1 Heart rate

**Authority:** `0x2A37` live; `AtriaWhoop4HistoricalRecordDecoder` historical.  
**Formula:** decoded BPM. Downstream plausible range 35–240. Gaps >15 s are not interpolated into load / calories / zones.  
**Class:** measured.  
**Verdict: Keep.** Same raw sensor family as WHOOP. Atria does not invent a smoothed “optical HR” reconstruction, which is a feature.

---

### 4.2 RR / tachogram

**Authority:** `HRVAnalyzer.analyze` in `HRV.swift`.  
**Gates:** 300–2000 ms; implied-HR mismatch ≤35 bpm; local median ±20% (radius 2); **no interpolation**. Production HRV requires **every** interval in the window to be `standardHeartRateMeasurement2A37`. Mixed / proprietary / legacy windows return no snapshot.  
**Class:** measured + standard artifact screening.  
**Verdict: Keep.** Forbidding HRV from HR-only data is the most important honesty rule in the app. Never relax it.

---

### 4.3 HRV (RMSSD / SDNN / pNN50 / lnRMSSD)

**Authority:** `HRVSnapshot` + `AtriaRecoveryHRVWindowSelection`.

```text
RMSSD   = sqrt(mean of successive adjacent NN diffs²)
SDNN    = sample SD of kept RR
pNN50   = 100 × (# |diff| > 50 ms) / N
lnRMSSD = ln(RMSSD)
```

Ready gates: window ≥300 s; max RR gap ≤3 s; kept ≥ ceil(window × 0.5 beats/s); successive diffs ≥70% of (kept−1); confidence = kept/raw ≥0.75. Saved recovery windows also require **kept ≥ 240**.

Display eligibility: ready and age in [−5 min, 24 h].  
Recovery eligibility: same civil day, measurement end hour **04:00–11:00**, age ≤24 h.  
Live stress eligibility: provenance `localRRWindow`, age ≤10 min.

Window selection: if motion-validated stages exist, prefer last deep/SWS segment before wake that **fully contains** a ready window; else best-quality (ready → kept → confidence → tighter gap).

**Class:** literature (Task Force 1996 RMSSD; sports-science `lnRMSSD`).  
**vs WHOOP:** last-SWS structure from US9750415B2; Atria falls back to best-quality when stages are missing and **must keep saying so**.

**Verdict: Keep. This is the strongest thing in the app.**

Improve only:

- Prefer median + MAD of nightly `lnRMSSD` as the *comparator* (a 30-day MAD receipt already exists and is unused in the displayed score). One alcohol night should not explode mean/SD.
- Keep 14 nights as the maturity bar. Seven is too few to call “personal baseline.”
- When stages are missing, the Recovery receipt should say “best-quality window,” not imply last-SWS.

Do not invent a new HRV metric (SDNN hero, frequency-domain LF/HF, “WHOOP-equivalent ms”). RMSSD is the correct short-window wearable metric.

---

### 4.4 Personal baselines (RHR, HRV)

**Authority:** `PersonalBaseline` in `Insights.swift`.

- One canonical sample per civil day (overnight wins; else lowest RHR).
- EMA α = 0.1; max step 2 bpm RHR / 6 ms HRV.
- Trust: **14 distinct fresh days/nights within 21 days**.
- HRV: overnight-only once ≥7 overnight lnRMSSD nights; below that a blend. Version 1 HRV requires standard 2A37 RR inside **confirmed main sleep**. Pre-v1 HRV stripped on decode.

**Class:** engineering EMA + personal z-scores. Overnight preference is WHOOP-*like*, not cloned.  
**Verdict: Keep.** Improve later by actually *using* the unused 30-day median/MAD receipt as the robust comparator, behind a model-version bump so history does not rewrite.

---

### 4.5 Overnight / session resting HR

**Authority:** `SavedSession.restingStable` / `sleepCandidateRestingHR`.

- Session baseline: **10th percentile** of accepted HR.
- HR-only sleep candidate: **5th percentile**.
- Confirmed-sleep RHR is the night’s stored value (35–240).
- Typical overnight band: mean ± 1 SD, **min 14 nights**, 30–120 bpm.

**Class:** robust percentile heuristic, not deep-sleep-weighted RHR.  
**Verdict: Keep.** Do not add WHOOP-style deep-sleep RHR weighting until stages are reference-validated. The 10th/5th percentile rule is conservative and appropriate for wrist PPG.

---

### 4.6 Respiratory rate

**Authority:** `AtriaAnalytics.RespRateRsa.estimate`; night value = median of qualified windows wholly inside confirmed sleep.

- Last 90 s of RR, ≥20 beats, duration ≥45 s, no inter-beat gap >5 s.
- Linear resample 4 Hz.
- Periodogram scan 9.0–30.0 breaths/min, step 0.5.
- Fail if peak power / band power < 0.18.
- Floor raised from 6 bpm specifically to avoid Mayer-wave false 6–8 /min.

**Class:** literature RSA / HF estimate. Not a chest-band sensor.  
**Verdict: Keep as an Atria estimate.** Elevated sleep RR is one of the better early-illness signals in the wearable literature. Do not claim WHOOP ±1 /min lab accuracy. Recovery may use resp only after a trusted 14-night baseline (`sd > 0.1`) — already gated.

---

### 4.7 Recovery (0–100%)

**Authority (only):** `Metrics.recoveryV2` → `AtriaAnalytics.Recovery.estimate(hrvSnapshot:...)`.  
Deprecated ungated estimators must never reach UI (`AtriaMetricAuthorityGuardTests`).  
Frozen as `FrozenRecoverySummary` (`recovery_v2`, **model version 3**) once per morning on the physiological cycle’s wake day. Naps must not rewrite it (GAP-04 closed). Civil midnight does not roll Recovery.

**Full model**

```text
z_hrv   = (ln RMSSD − personal mean) / sd     # clamp ±2.5; min SD 0.05
z_rhr   = (RHR − personal mean) / sd          # min SD 1.0 bpm
z_sleep = average of:
            (efficiency − 0.85) / 0.10
            (clamp(hours, 0, 9) − 7.0) / 1.5
          then clamp ±2
z_resp  = −z(rate) if 14-night baseline exists

observed_weight = 0.95  (1.00 if resp qualified)
blended = (0.60 z_hrv − 0.20 z_rhr + 0.15 z_sleep [+ 0.05 z_resp]) / observed_weight
percent = round(clamp_1_99( 100 / (1 + exp(−1.6 × (blended + 0.20))) ))
```

**Fallbacks (already honest)**

| Missing | Behavior | Confidence |
|---|---|---|
| Sleep, both baselines trusted | Renormalize 0.60 / 0.20 / (0.05) | unverified |
| HRV | Sleep 0.75 + RHR 0.20 + resp 0.05 | unverified |
| Sleep + HRV | RHR weight **stays 0.20** (not renormalized to 100%) | unverified |
| Else | no percent | learning |

Colors: ≥67 green, 34–66 yellow, <34 red (public WHOOP band vocabulary).  
`validated` tier exists but `hrvReferenceValidated` is **false in production**. That word currently means “we have a personal baseline,” not “this score predicts readiness.”

**Class:** engineering heuristic with published physiology. Not a clinical readiness model.  
**Sleep term uses population 7 h / 85%**, which the code itself discloses. That is the one internal contradiction with the “no population substitutes” rule.

**Verdict: Keep the *engine* (personal z + fail-closed contributors + freeze). Do not lead the product with the percentage until it is outcome-calibrated.**

Improve:

1. Primary morning surface should be three measured numbers: HRV vs 14–30 day band, RHR vs band, sleep hours vs *that night’s* frozen need.
2. Keep Recovery as a **versioned coaching index**. Never call it measured.
3. Replace population sleep z with a personal sleep baseline (same 14-night rule as HRV).
4. Calibrate the logistic against *your* next-day data: next-night HRV, next-day RHR, session RPE, subjective readiness. If blended z does not move those outcomes, throw the weights out — do not add more inputs.
5. Rename production `validated` → `personal baseline`. Reserve `validated` for a held-out outcome study.
6. Do **not** add skin temp, SpO2, cycle phase, or stages into Recovery until each one independently predicts leftover variance after HRV+RHR.

Kill as a goal: numerical equality with WHOOP Recovery. Dual-wield testers will see 61 vs 44 and call the app broken. Different sensors-in-use, different window, different mix.

---

### 4.8 Strain (0–21)

**Kernel authority:** `AtriaStrainLoadModel` via `AtriaAnalytics.Strain.trimp` / `dailyTRIMP`.  
**Exactness authority:** `Metrics.StrainPresentation.resolve`.

Banister HRR TRIMP (male 0.64 / 1.92; female 0.86 / 1.67; PMC10944953 / PMC13287160):

```text
HRR  = clamp( (meanBPM − RHR) / (HRmax − RHR) )
load += (dt/60) · HRR · a · exp(k · HRR) · w
```

- Workout: `w = 1`.
- Continuous-day: `w = 0` if HRR ≤ 0.30; linear ramp 0.30–0.40; 1 above (Phillips arXiv:2508.11613v2 *structure*, not Fitbit Cardio Load).
- Adjacent samples, `dt ≤ 15 s`, BPM 35–240.
- Confirmed sleep subtracted. Pauses split segments so a short pause cannot re-integrate.

Display (calibration version **3**):

```text
Strain = 21 × (1 − exp(−TRIMP / 150))
```

`/150` was re-fit after `/250` made a TRIMP-65.6 session look like 4.85. That is product calibration, not physiology.

Bands (WHOOP *published vocabulary*, not WHOOP math): Light 0–9 / Moderate 10–13 / High 14–17 / All Out 18–21.

Partial coverage: `< 95%` → `≥ x.x` and `Partial · N% tracked`. Correct.

Edwards zone-load exists as an **audit** scorer, not the hero number. Keep it in the lab.

**Class:** Banister TRIMP is literature. 0–21 curve is Atria engineering.  
**Verdict: Keep the kernel. Treat 0–21 as a skin.**

Improve:

- Store **raw daily TRIMP** as truth. 0–21 is presentation.
- Recalibrate `/150` on a corpus of *your* days labeled easy / moderate / hard / brutal and session RPE — not one memorable workout. Bump `displayCalibrationVersion` and migrate; never silently rewrite.
- Do not imply 12.4 Atria = 12.4 WHOOP.

Do not add activity-type multipliers inferred from IMU. That is a motion-stack change. Logged muscular fusion is the only extra term, and it is already provisional (see 4.9).

---

### 4.9 Muscular load (logged strength)

**Authority:** `AtriaStrengthLog.muscularLoadReceipt` + `AtriaStrainLoadModel.muscularTRIMPEquivalent`.  
Documented in `docs/17-muscular-load-and-fusion.md`.

```text
effortAdjustedVolume = Σ effectiveLoad × reps × (0.55 + 0.45 × RPE/10)
density              = min(0.15, 0.03 × quickSupersetTransitions)   # ≤90 s
score                = min(100, 100 × (1 − exp(−EAV × (1+density) / 5000)))
equivalent TRIMP     = 45 × (score/100)^1.6
dayLoad              = cardioTRIMP + Σ equivalents
```

A set is load-qualified only with positive reps **and** frozen effective load or entered weight. Score exists only if **every** load-qualified set has explicit RPE. Incomplete RPE → **zero** muscular load. Unlogged “Strength” → zero. Body-mass fractions exist only for named movements (pull-up 0.95, dip 0.90, push-up 0.65, squat/lunge 0.75, burpee 0.60). Unknown movements: no estimate.

**Class:** engineering-provisional. More honest than inferring muscular load from a wrist.  
**Verdict: Keep the logbook model. Do not treat the fuse as truth.**

Improve: show lifting work as its own bar until you have enough logged sessions to fit `45` and `1.6`. Fusing an uncalibrated term into the only Strain number makes cardio days and lifting days incomparable.

Do **not** infer muscular load from IMU. That would reopen the motion stack.

---

### 4.10 Strain target / daily coach

**Authority:** `Coach.baseStrainTarget` / `Coach.guide` in `Dashboard.swift`; frozen as `AtriaFrozenDailyStrainTarget`.

```text
Recovery ≤ 33 → target 9
Recovery ≥ 67 → target 17
else          → 9 + ((R − 33) / 34) × 8
ACWR > 1.30   → target −2 (floor 4)
ACWR < 0.80   → target +1 (cap 21)
```

**Class:** WHOOP-shaped UX. Local heuristics.  
**Verdict: Keep the *loop* (recovery → a day’s budget → ease/push). Do not pretend the 9–17 map is physiology.**

Improve only after Recovery is outcome-calibrated: map the target off **yesterday’s TRIMP that still left tomorrow’s HRV in-band**, not off a 0–100 ring. Until then, the current map is an acceptable coach sentence generator if Recovery is labeled as an index.

---

### 4.11 Heart-rate zones

**Authority:** `Metrics.heartRateZone` / `HRZone` — HRR everywhere (GAP-03 closed). Frozen per workout as `AtriaHRRZoneBoundaries`.

```text
frac = (BPM − RHR) / (HRmax − RHR)
Rest <50%, Warm-up 50, Fat burn 60, Aerobic 70, Anaerobic 80, Max ≥90%
```

Audit buckets (strain zones, different cuts): z0 <30, z1 30–50, z2 50–70, z3 70–85, z4 ≥85% HRR.

Max-HR suggestion: 180-day session peaks, 95th percentile, trigger if ≥ current+3; suppress 60 days after dismiss.

**Class:** literature (Karvonen / HRR). Names are consumer (“Fat burn”), not ACSM.  
**Verdict: Keep.** Unifying on HRR was the right fix. Do not revert any surface to %HRmax.

---

### 4.12 Calories

**Authority:** `AtriaAnalytics.Daily.dayCalories` — Keytel et al., then **gross − resting-at-RHR**, `dt ≤ 15 s`. Needs age / weight / sex. Unspecified sex → nil.

**Class:** published population equations, typically ±20–30%.  
**Verdict: Keep, labeled `≈`.** Do not build coaching on kcal. Do not chase WHOOP calorie parity.

---

### 4.13 Steps / motion / floors

**Authority:** `AtriaWhoop4MotionTickStepModel` + `AtriaDailyStepPresentation`.  
**Algorithm:** `whoop4-motion-ticks-to-steps-v1` (v24 bytes 88–89 / 155/132 ticks-per-step from 2026-07-27 physical work).

Presentation: complete vs partial vs unavailable; open cycle never looks like a closed day; prior-cycle receipt not attributed to today; live evidence max age 15 s; fail closed if model not qualified / receipts conflict / motion unresolved.

**Gate 4 status (authoritative ledger in `docs/WHOOP4_PROTOCOL_FINDINGS.md`):** workout-local counted walks can pass; **all-day autonomous authority is not sealed.** Planted-feet arm motion has failed earlier models.

**Verdict: Do not touch.** See §0.

This assessment previously considered phone-pedometer fusion as a replacement. That is **rejected here** unless a future physical program proves it will not split day-authority, sleep-motion qualification, or archive receipts. A second step number is worse than a partial honest one.

---

### 4.14 Sleep detection (sleep vs wake)

**Authority:** `AtriaSleepWakeResearch.classify`.

Motion path: duration ≥20 min; IMU stillness ≥0.72 and movement ≤0.18; avg HR ≤ RHR+18; strap steps available and ≤ max(8, ⌊duration/600⌋).  
HR-only path: duration ≥3 h; avg HR ≤ RHR+12; HR SD ≤9; start hour 20–03; confidence `hr_only`.  
Nap heuristic: duration in nap band and local start ≥11 and end ≤20.

Resumed-sleep is a separate review segment; confirmation cannot extend the main record across an awake gap.

**Class:** research heuristic. Activity-type classifier (GAP-11) is still open.  
**Verdict: Keep the conservative review-first posture.**

Improve **product**, not the motion thresholds (those sit next to Gate 4):

- Auto-confirm **only** when HR density + qualified RR + existing *already-qualified* stillness + clock position all fire, with one-tap undo.
- Medium confidence stays a review card.
- Never auto-save a sport type.

Do not retune stillness 0.72 / movement 0.18 / step ceilings without a new labeled night set. That is motion-adjacent.

---

### 4.15 Sleep stages / hypnogram

**Authority:** `AtriaSleepWakeResearch.stageSegments`.

Gates: duration ≥20 min; ≥6 HR samples/min; adjacent gap ≤15 s; coverage ≥85%; max hole ≤90 s; 30 s epochs.

Classifier (main night) is a hand-written rule set on ΔHR, difference-of-Gaussians (σ=120 s vs 600 s), local SD, night progress, and optional motion. REM/Deep/SWS/Light/Awake.

Provenance:

- Motion-backed `research-motion-v2-*` → “Checked stages”
- HR-only `research-hr-estimate-v1-*` → **must** show `Estimated stages · HR-only`
- HR-only stages **never shrink saved hours**
- Manual sleep → no stages
- Manual / unconfirmed naps → no hypnogram

**Class:** engineering / research heuristic. Not PSG. Not WHOOP staging.  
**Literature:** consumer wrist devices are acceptable at sleep vs wake and poor at REM/Deep. Users treat colored bars as EEG. They are not.

**Verdict: Keep the honesty gates. Do not promote stages.**

If you refuse provisional:

- Hero sleep picture = duration + efficiency (motion nights only) + overnight HR + respiration.
- REM/Deep stay behind the estimate label until participant-separated validation against PSG or a PSG-validated headband worn the same nights.
- Never feed stages into Recovery (circular: stages are inferred from the same HR you would then “confirm”).

Do not retune the DoG / ΔHR cutoffs as a “WHOOP match” project. That is unvalidated cosmetics.

---

### 4.16 Sleep Need / debt / sufficiency

**Authority:** `AtriaSleepBudget.sleepNeedComponents`. Historical nights read only `FrozenNeed`.

```text
base        = clamp(baseHours, 6, 10)
strainAdder = max(0, min(yesterdayStrain, 21) − 8) × (0.62 / 7)
              # 15.0 strain → ~37 min  (WHOOP’s published blog number)
              # 21 strain   → ~69 min
debtAdder   = min(debt, 8 h) × 0.5
napCredit   = napHours × 0.9
need        = clamp(base + strain + debt − nap, 6, 10)

debt        = Σ last 7 nights  max(0, needed − slept) × 0.75^age
              capped at 8.0 h
sufficiency = round(100 × slept / need)
```

**Class:** structural debt/cap inspired by US20240252121A1; coefficients are Atria / WHOOP-public-number heuristics. 8 h cap is explicitly validation-gated in code comments.

**Verdict: Keep the ledger and freeze. Change the strain adder’s *input*, not the idea of a ledger.**

Improve:

- Learn **base need** from the user’s own sufficient nights (next-day HRV/RHR in-band), not 7–8 h folklore.
- Strain adder should eventually take **yesterday’s TRIMP**, not the 0–21 skin. That is a one-line input swap after TRIMP is treated as truth — it does not require motion work.
- Sufficiency stays labeled Sufficiency. Do not rename it Sleep Score.

---

### 4.17 Sleep Consistency

**Authority (only):** `AtriaSleepConsistency.result`.

Confirmed non-nap nights with a **recorded timezone**. Last 14. Min 5 or `--`. Civil minutes in the event TZ; times <12:00 anchored +24 h. Typical = mean bed / mean wake. Regularity `100 − round(meanAbsDev / 120 × 60)`. Combined = mean of bed and wake regularity.

**Class:** simple schedule regularity. Defensible as timing, not quality.  
**Verdict: Keep the single engine and timezone fail-closed rule.**

Improve (optional, not urgent): Sleep Regularity Index (Phillips et al. 2017) is what circadian papers use. Mean clock deviation punishes shift work and jet lag the same way, and a single 4 a.m. night drags the center. Raise the minimum from 5 nights toward 10 if you show a percentage people will train against.

Do not add a second consistency chart.

---

### 4.18 Composite Sleep Score

**Authority:** `AtriaSleepScore.provisional` only.

Weights: Sufficiency 0.50, Consistency 0.25, Efficiency 0.15, Overnight load 0.10 — **API-pinned nil** until GAP-10. Renormalize present components. Need ≥2 present or no composite. `isProvisional = true` always. Persisted on `DailyRollupStoreEntry.sleepScore` from frozen inputs.

**Class:** WHOOP-shaped product with unvalidated weights. The code says so permanently.  
**Verdict: Demote. Do not lead Health with this.**

There is no gold-standard “sleep score.” PSG gives stages and AHI, not a 0–100 lifestyle grade. If you refuse provisional, the composite cannot be the hero. Keep the three honest components on one card.

---

### 4.19 Overnight HR load (not “sleep stress”)

**Authority:** `AtriaSleepStressProjection.make`. Copy forbids “sleep stress” (GAP-05 closed).

5-min buckets. Score `3 × clamp((meanHR − RHR − 3) / max(10, 0.20×RHR))`. High periods: score ≥2, merge if ≤6 min apart. Gates: RHR 35–120; window ≥60 min; ≥12 buckets spanning ≥ min(3 h, 45% of night).

**Class:** conservative HR-elevation chart. Not stress, not stage, not diagnosis.  
**Verdict: Keep as visualization.** Do not put it in Recovery or Sleep Score (GAP-10 still open). Do not rename it back to stress.

---

### 4.20 Stress monitor (0–3)

**Authority:** `AtriaPhysiologicalStressModel.evaluate` (scoringVersion 3).

5-min HR window, 1-min cadence. ≥5 HR samples, span ≥290 s, max raw gap 60 s. RR span ≥90 s, gap ≤3 s for RMSSD.

```text
h          = clamp((meanHR − RHR) / (HRmax − RHR))
HR_stress  = sigmoid(8 × (h − 0.25))
w_HR       = 0.5 + 0.5 × (1 − smoothstep(0.05, 0.35, h))
HRV_stress = sigmoid(1.3 × (median_base − lnRMSSD_now) / max(0.15, 1.4826×MAD))
base       = w_HR × HR_stress + (1 − w_HR) × HRV_stress   # or HR_stress if no HRV
M          = 1, or max(0.65, 1 − 0.35×intensity) if qualified activity
score      = 3 × M × base
             then EMA half-life 3 min (continuity gap ≤90 s)
```

Missing motion **cannot invent calm** (`M = 1`). Stale HRV cannot seed live stress.

**Class:** Atria-owned activation index (patent cited for direction only).  
**Verdict: Keep.** It is sympathetic activation, not psychological stress. It cannot tell a hard set from caffeine from anxiety. Do not put it into Recovery. Do not add temp/SpO2 into it until those decoders exist **and** survive a still-vs-desk control — which is sensor work, not a stress-formula tweak.

Do not retune the activity attenuator using IMU intensity experiments. That is motion-adjacent.

---

### 4.21 VO₂max estimate

**Authority:** `AtriaAnalytics.VO2Max`.

Uth–Sørensen–Overgaard–Pedersen 2004: `15.3 × HRmax / RHR`, clamp 20–80. Needs ≥7 qualified RHR days for preliminary, 14 for “rough estimate,” and a **measured** HRmax (age-predicted does not unlock).

**Class:** classic HR-ratio estimate. Large error bars.  
**Verdict: Keep, labeled rough.** Do not feed it into a “body age” hero as if it were a treadmill test.

---

### 4.22 Fitness age / Healthspan / pace of aging

**Authority:** `AtriaFitnessAge.summary` (production). Older `AtriaAnalytics.BiologicalAge` remains as a factor toolkit.

Equal-weight offsets from VO2 (FRIEND decade medians), RHR anchors, lnRMSSD age curve, zone-2+ minutes/week, sleep consistency. Sum clamped ±12 years. Pace of aging from 4 weekly observations.

**Class:** compact local approximations. The code says “not a medical measurement.”  
**Verdict: Demote or hide.** This is the same genre as WHOOP Healthspan: a lifestyle smoothie in a lab coat. It will get medical-claim trouble and it will make serious users distrust the good numbers. It is not required to replace WHOOP’s daily loop.

---

### 4.23 Training load (ACWR / monotony)

**Authority:** `AtriaAnalytics.TrainingLoad.summary`.

Daily strain from day TRIMPs. Acute = mean last 7, chronic last 28. ACWR = acute/chronic. Monotony = mean/SD (cap 9.99). Bands follow Gabbett-style watch/bad thresholds.

**Class:** literature-shaped load heuristic.  
**Verdict: Keep as a secondary analytics card.** Useful for people who actually train every day. Do not let ACWR silently dominate the home ring. The −2 / +1 target tweak is enough.

---

### 4.24 Physiological cycle vs civil day

**Authority:** `AtriaPhysiologicalCycle` + `AtriaHealthMetricAuthority`.

Main-sleep wake is the cycle boundary. Midnight does not mint a new Recovery. Fallback kinds fail closed rather than steal another day’s frozen score.

**Class:** product architecture matching WHOOP’s sleep-to-sleep day.  
**Verdict: Keep. This is one of the things that makes Atria feel like a replacement rather than a fitness-tracker midnight reset.**

---

### 4.25 Workout detection / review prompt

**Authority:** `AtriaWorkoutPromptEvaluator`.

≥8 min sustained; ≥5 min elevated at +30 bpm over rest, continuous 5 min; zone lookback 6 min with ≥4 min samples, 90 s continuous, zone index ≥3. Contact-quality fail if artifacts ≥15%, zeros ≥25%, accepted share <70%. Cooldown 45 min. **Phone motion not used.**

**Class:** interruptibility heuristic. GAP-11 (named sport classifier) is open.  
**Verdict: Keep as review, not auto-save.**

Do not train an automatic activity-type classifier on IMU until Gate 4 is sealed. GAP-11 is explicitly a labeled-capture program. Shipping a wrong type automatically is worse than asking.

---

### 4.26 Journal / behavior insights

**Authority:** `AtriaBehaviorImpact` / `AtriaJournalInsights`.

90-day window; ≥5 vs ≥5 days; |Δ mean Recovery| ≥3 points; Welch p < 0.10. Typed answers: 30-min grid, ≥12 days, adjusted p, Spearman-like rank with 2000 permutations. Copy is associative (“while” / “with”). Always shows n.

**Class:** exploratory within-person stats. Better than WHOOP Journal’s causal vibe.  
**Verdict: Keep.** Raise the minimum nights if you ever phrase a percent as a cost. Prefer pairing journal tags to **HRV and RHR**, not to the Recovery composite, so the insight survives a Recovery model bump.

---

### 4.27 Menstrual cycle (opt-in)

**Authority:** `AtriaCycleTrackingStore`. Default OFF. Isolated JSON.

Calendar phases: default 28 / period 5 / luteal 14. ≥2 completed cycles → median cycle 15–60 = personalized. Phase recovery averages only when personalized.

**Class:** diary + calendar. WHOOP uses temp/HRV; Atria cannot until skin temp is validated.  
**Verdict: Keep as estimate.** Show phase next to HRV. Do not multiply Recovery by a cycle coefficient. Follicular/luteal HRV differences are real on average and small compared with alcohol and sleep.

---

### 4.28 Breathwork

Cadence 5.5 breaths/min (resonance-frequency heuristic). Optional start vs end RMSSD delta if enough RR.

**Verdict: Keep.** Descriptive only.

---

### 4.29 Sleep planner (Peak / Perform / Get by)

**Authority:** `AtriaSleepPlanner.plan`.

Need fractions 1.00 / 0.85 / 0.70. Time in bed = target / efficiency. Efficiency = median of confirmed nights with 0.5 < eff ≤ 1, else **0.90 default (labeled)**.

**Class:** WHOOP-public tier names; local arithmetic.  
**Verdict: Keep.** The 0.90 default is honest if labeled. Prefer hiding Peak/Perform until a personal efficiency exists.

---

### 4.30 Smart wake

**Shipped honesty:** UI says smart early wake is **in development**. Live same-night stages are not produced, so the window **behaves as a hard alarm**.

**Verdict: Keep the hard alarm. Do not advertise smart wake until live staging exists and is validated.** Building live staging to unlock this would be a large sleep-stage project, not a small alarm tweak.

---

### 4.31 SpO2

`validatedSpO2DecoderAvailable = false`. Offsets 64/66/68 are research u16s. Ratio 64/66 is a hypothesis feature, not a percentage.

**Verdict: Keep blank.** Showing a % would be fabrication. The path is `docs/14` (fingertip oximeter, same clock, negative controls, firmware-locked decoder). That is a measurement campaign, not a UI ticket.

Even after decode, WHOOP’s own SpO2 is a short overnight burst average, not a medical oximeter. Product use: nightly trend / illness context, labeled estimate, never Recovery fill-in on day one.

---

### 4.32 Skin temperature

`validatedSkinTemperatureDecoderAvailable = false`. `productionSkinTemperatureDecoder = nil`. Experimental relative raw (`AtriaRelativeSkinSignal`) vs 7–30 prior nights, same strap/layout/offset. Never °C, never HealthKit, never Recovery/Strain.

**Verdict: Keep relative-raw in research. Do not show °C.** After `docs/14`, the useful product is **deviation from personal nightly baseline**, not core temperature cosplay.

---

## 5. What is actually excellent (keep this culture)

Atria’s best ideas are not WHOOP features. They are anti-WHOOP:

- One authority per metric; frozen receipts; no silent history rewrite.
- No fabricated HRV, SpO2, or °C.
- Standard `0x2A37` as the live source of truth.
- Historical drain that can reconstruct a night after the phone was elsewhere.
- Contributors that can be zero-weight and visible.
- Tests that ban words you are not allowed to claim.
- Wake-to-wake physiological day.
- Nap does not rewrite morning Recovery.
- HR-only hypnograms cannot shrink saved hours.
- Partial strain shows `≥`.
- Journal is statistically gated and associative.
- Smart wake admits it is a hard alarm.
- Motion/steps fail closed instead of inventing an 8,000.

That honesty is how you replace WHOOP in India without a subscription and without looking like a clone that lies worse than the original.

---

## 6. What is weak, invented, or should not lead the product

| Item | Why | Action |
|---|---|---|
| Composite Sleep Score as hero | Invented 50/25/15/10, permanently provisional | Demote. Show components. |
| Recovery as if measured | 60/20/15/5 + logistic are knobs | Whiteboard of HRV, RHR, sleep. Index optional. |
| Sleep z vs 7 h / 85% | Population norm inside an anti-population policy | Personal sleep baseline. |
| Strain 0–21 as truth | `/150` fitted to make one session “look right” | Store TRIMP. Skin optional. |
| `15.0 strain = 37 min` sleep | WHOOP marketing number | Eventually TRIMP → need, fit from your nights. |
| Fitness age / Healthspan | Lifestyle smoothie in a lab coat | Hide or kill as hero. |
| Word `validated` on Recovery | Means baseline exists, not outcome-proof | Rename. |
| Auto hypnogram ambition | PPG ≠ EEG | Sleep/wake + overnight HR first. |
| Fusing uncalibrated lifting into Strain | Incomparable days | Separate muscular bar until fitted. |
| Numerical WHOOP equality | Different kernel, window, mix | Stop. |
| All-day strap steps “just fix it” | Gate 4 not sealed; years of physical work | **Do not touch.** |
| Phone steps as new authority | Splits receipts and sleep-motion | **Do not touch.** |
| Live high-rate IMU for product | Physically kills this link | **Do not touch.** |

---

## 7. What WHOOP users actually pay for

Not “a 67% Recovery.” They pay for a loop:

1. Strap stays on and the night is never missing.
2. Morning: one decision plus a sentence about today.
3. Day: load accumulates without opening the app.
4. Workout: auto-detected enough that logging is optional.
5. Sleep: a picture of the night that feels complete.
6. Over months: journal + baselines that feel personal.
7. Hardware extras on 4.0: temp + SpO2 on Health Monitor. On 5.0/MG: Healthspan, better sensors, BP/ECG on MG.

You can replace **1–3 and 6 now** if reliability stays high.

You can replace **4** without a perfect classifier: high-precision “you were working” + user picks the type. Do not use IMU type-classification to get there.

You can replace **5** with duration + efficiency + overnight HR + respiration. You cannot honestly replace the colored hypnogram yet.

You can replace **7** only by finishing `docs/14`. There is no software shortcut.

You **cannot** replace MG blood pressure / ECG / Healthspan on a 4.0. Do not try. Sell 4.0 as a local performance OS, not a medical watch.

You should not replace WHOOP by calling their cloud. That creates cost, ToS war, and dependency. Everything above is on-device from a strap the user owns.

---

## 8. The replacement that is actually accurate

Build the product around **six measured or logged quantities**. Everything else is coaching copy.

1. **HR** — live + historical. Already good.
2. **lnRMSSD** — last clean overnight window, 14–30 day band.
3. **Overnight RHR** — same.
4. **Sleep/wake timeline** — existing detector + confirm-when-certain. Do not retune motion constants.
5. **Cardiovascular load** — Banister TRIMP, sex-specific, gaps dropped.
6. **Logged work** — sport type, duration, optional sets/RPE.

Derived, versioned, never pretending to be sensors:

- Sufficiency vs learned need
- Sleep regularity
- Activation / stress (HR+HRV)
- RSA respiration
- Optional Recovery index **after** it tracks next-day HRV/RHR/RPE

Hardware program (this is how you stop being “HR-only WHOOP”):

- Finish SpO2 + skin-temp against cheap reference devices (`docs/14`). Firmware-lock the decoder. Show **deviation**, not theatrical 98%.
- Collect 50–100 labeled nights and 50 labeled workouts from real wearers, participant-separated, **without changing the step/IMU stack** unless a capture happens to produce a new Gate 4 seal as a side effect.

Coaching that makes people cancel WHOOP:

> HRV −12% vs your 21-day median. RHR +4. You slept 6:10 vs 7:40 need. Cap today around TRIMP X (last easy day that still left tomorrow’s HRV intact).

That sentence is more useful than a 41% ring, and you can generate it from data you already have.

---

## 9. Recommended work (ordered). Motion/steps excluded.

These are the only items this assessment is willing to call product-positive **without** touching Gate 4.

> **Status 2026-08-14** — items 2–10 landed on `codex/whoop-remaining-product-gaps`:
> 2+3 in `280c7a88` (heroes demoted; `validated` tier reserved, replay/display read "Personal baseline"),
> 4 in `1e50cdb3` (`AtriaTodayMorningWhiteboardModel`), 5+6 in `563b59a2` (Recovery v4:
> personal sleep baseline w/ population fallback tier-capped to `unverified`; robust 30-day
> median/MAD HRV comparator preferred when trusted; `recoveryV2ModelVersion = 4`, frozen v3
> receipts untouched), 7+8 in `cc50038b` (`dayTRIMP`/`trimp` stored truth; need adder consumes
> TRIMP through the display authority — per-user slope fit still open, 37-min-at-15 stays a
> labeled heuristic), 9 in `5751f6d8`, 10 in `2b6031de` (qualified-RR conjunct + banner Undo).
> Item 1 is standing work; P2 campaigns remain open.

### P0 — truth and leadership (no new sensors)

1. **Never-lose-the-night reliability** — drain, reconnect, freeze, cycle boundary. This is already the project’s real moat. Protect it.
2. **Demote Sleep Score and Fitness Age** as heroes. Sufficiency + contributors stay.
3. **Rename Recovery `validated` → `personal baseline`.** Keep the engine.
4. **Morning whiteboard** — HRV vs band, RHR vs band, hours vs frozen need, yesterday TRIMP. Recovery ring can stay as a secondary index.
5. **Personalize Recovery’s sleep term** (drop 7 h / 85% population z). Model-version bump. History frozen.

### P1 — same data, better science

6. Use the unused 30-day median/MAD HRV receipt as the robust comparator (version bump).
7. Treat TRIMP as stored truth; keep 0–21 as a versioned skin.
8. Point Sleep Need’s strain adder at yesterday TRIMP, not the 0–21 skin. Fit the hours/TRIMP slope from *your* nights when you have them; until then the 37-min-at-15 mapping can remain as a labeled heuristic.
9. Journal insights: pair to HRV/RHR, not only Recovery %.
10. Auto-confirm sleep **only** on the existing high-agreement path (HR density + qualified RR + already-qualified stillness + clock). Do not retune stillness/step ceilings. One-tap undo.

### P2 — measurement campaigns (not formula tweaks)

11. `docs/14` SpO2 + skin temp vs fingertip oximeter and adjacent skin probe. Then Health Monitor tiles. Then, and only then, consider them as Recovery *candidates*.
12. Recovery outcome calibration (next-day HRV, RHR, RPE, subjective readiness). New model version or keep the index unlabeled.
13. GAP-10 overnight load — HRV + HR slope + existing motion context vs a questionnaire or intervention. Not a color threshold.
14. GAP-12 sleep staging vs a reference dataset. Until then, do not promote REM/Deep.

### Explicitly not recommended

- Reopening Gate 4, tick scale, gravity-cadence, R10 lease, or phone-step authority.
- Automatic named-sport classifier on IMU (GAP-11) before Gate 4 is sealed.
- Live high-rate optical/IMU (`0x6C` / `0x6A` / `0x3F`) as a product path on this phone.
- Importing WHOOP cloud Recovery/Strain/Sleep as “authoritative.”
- Adding cycle phase, SpO2, or temp into Recovery as neutral fillers.
- Building Smart Wake on HR-only stages.
- Cloning WHOOP Coach personality, more rings, or a second consistency chart.
- Biological-age marketing.

---

## 10. Hard truth

“Nothing provisional, everything accurate” means **showing fewer numbers**, not inventing better constants.

WHOOP’s power is a confident morning ritual on top of unpublished mixes and a stage picture the literature only weakly supports. Atria’s power is that a skeptical user can open the receipt and see the work.

Users who already own a dead strap will leave WHOOP for **no subscription + nights that do not vanish + numbers that survive a cross-examination**. They will not leave for a second Recovery percentage that disagrees with the first, and they will leave *you* if a casual “fix steps” commit undoes a year of physical motion work.

Protect motion. Measure HRV. Freeze the night. Coach from the whiteboard.

---

## 11. Source map (canonical files)

| Concept | File / symbol |
|---|---|
| Metric policy | `Atria/Atria/Metrics.swift` `MetricAuthority`; `docs/16-…` |
| Recovery | `AtriaAnalytics.Recovery.estimate`; `FrozenRecoverySummary` |
| Strain kernel | `AtriaStrainLoadModel` |
| Strain display | `displayCalibration` loadScale 150, version 3 |
| Strain exactness | `Metrics.StrainPresentation.resolve` |
| Strain target | `Dashboard.swift` `AtriaFrozenDailyStrainTarget` |
| Sleep Need | `AtriaSleepBudget.sleepNeedComponents` / `FrozenNeed` |
| Sleep Score | `AtriaSleepScore.provisional` |
| Consistency | `AtriaSleepConsistency.result` |
| HRV / windows | `HRV.swift` `HRVSnapshot`, `AtriaRecoveryHRVWindowSelection` |
| Stress | `AtriaPhysiologicalStressModel` v3 |
| Overnight HR load | `AtriaSleepStressProjection` |
| Zones | `HRZone` / `AtriaHRRZoneBoundaries` |
| Calories | `AtriaAnalytics.Daily.dayCalories` |
| Steps | `AtriaWhoop4MotionTickStepModel` — **do not touch** |
| SpO2 / temp | `AtriaResearchProbe` flags; `docs/14` |
| Muscular | `AtriaStrengthLog.muscularLoadReceipt`; `docs/17` |
| Journal | `AtriaJournalInsights` / `AtriaBehaviorImpact` |
| Cycle (product day) | `AtriaPhysiologicalCycle` |
| Cycle (menstrual) | `AtriaCycleTrackingStore` |
| BLE map | `docs/02-device-ble-map.md`; `AtriaBLESchema.swift` |
| Protocol ledger | `docs/WHOOP4_PROTOCOL_FINDINGS.md` |
| Remaining gaps | `docs/WHOOP_REMAINING_PRODUCT_GAPS.md` |

---

## 12. Patent and literature anchors

- US9750415B2 — Whoop, HRV in last SWS before wake; HRR intensity → 0–21 scale
- US11185292B2 — Recovery as weighted HRV + RHR + sleep + quality
- US20240252121A1 — Sleep need from physiology; scaled and capped debt
- US20240188865A1 — Stress timeline direction (HR/HRV/motion)
- Task Force of the ESC/NASPE (1996) — RMSSD
- Banister TRIMP; sex constants PMC10944953, PMC13287160
- Keytel et al. (2005) — HR energy equations
- Uth, Sørensen, Overgaard, Pedersen (2004) — 15.3 × HRmax/HRrest
- Phillips et al. (2017) — Sleep Regularity Index
- Gabbett — ACWR as a *heuristic*, not a law
- Miller et al. / other wearable-vs-PSG papers — sleep/wake ok, stages weak

---

## 13. Post-handoff remaining work (after items 2–10)

Reviewed: 2026-08-14, on `codex/whoop-remaining-product-gaps` after:

| Item | Commit | What shipped |
|---|---|---|
| 2+3 | `280c7a88` | Sleep Score / Fitness Age off the default Home glance; Recovery `.validated` reserved; UI says Personal baseline |
| 4 | `1e50cdb3` | `AtriaTodayMorningWhiteboardModel` — HRV, RHR, slept vs frozen need, yesterday strain |
| 5+6 | `563b59a2` | Recovery **v4**: personal sleep baseline (population fallback caps tier at unverified); 30-day median/MAD HRV comparator; `recoveryV2ModelVersion = 4`; frozen v3 receipts untouched |
| 7+8 | `cc50038b` | `dayTRIMP` persisted; Sleep Need adder consumes TRIMP via the display authority; 37-min-at-15 stays a labeled heuristic |
| 9 | `5751f6d8` | Journal pairs to HRV and RHR first, Recovery second |
| 10 | `2b6031de` | Silent sleep auto-confirm requires qualified RR; banner Undo |

**Software formula work from §9 is done.** What remains is not another week of invented constants. Motion/steps/IMU remain **do not touch** (§0).

### Still perfect — do not reopen

- 2A37 as live HR/RR truth; no HR-only HRV
- Quality-gated RMSSD / lnRMSSD; last-SWS window only when stages are motion-validated
- Recovery v4: personal z, robust 30-day HRV, personal sleep term, fail-closed contributors, morning freeze, naps cannot rewrite
- Banister TRIMP kernel; 15 s gap rejection; HRR zones frozen per workout
- Frozen Sleep Need receipts; one consistency engine; timezone fail-closed
- Wake-to-wake physiological day
- Sleep Score and Fitness Age off the default Today glance
- Morning whiteboard leading with measured numbers
- Journal statistical gating, now on HRV/RHR
- Auto-confirm only on high-agreement + qualified RR + Undo
- SpO2 % and absolute °C still blank
- Gate 4 / tick / gravity / R10 left alone

### Still leftover, and worth doing (sure product improvement, no motion)

These are the only remaining **code** items this document is willing to call net-positive without new labeled captures.

1. **Reliability (standing item 1).** Never-lose-the-night is still the moat. Drain, locked reconnect, freeze, cycle boundary. This is how you replace WHOOP, not another score. Do not trade it for features.

2. **Whiteboard still prints 0–21 Strain, not TRIMP.** P1.7 stored TRIMP as truth; the card still says `Strain %.1f`. Show yesterday’s TRIMP (and keep 0–21 as a parenthetical skin), or the “TRIMP is truth” work is invisible.

3. **Coach `9 / 13 / 17` from Recovery % is the last WHOOP-shaped fiction on the daily loop.** `Coach.baseStrainTarget` still maps Recovery 0–33→9, 67+→17. The ring center is still Recovery. Replace the *sentence* with the whiteboard: if HRV is below the personal band or RHR is above it, recommend a lighter day than yesterday’s TRIMP; otherwise “room to match yesterday.” Do **not** invent a new 0–21 formula. Do **not** retune 9–17.

4. **Un-fuse muscular load on the day surface.** The 45 × (score/100)^1.6 fuse is still engineering-provisional and still added into the one Strain number. Show cardio TRIMP and logged lifting work as two bars. Keep the fuse off the hero, or behind a labeled combined total. Incomplete RPE already contributes zero — keep that.

5. **Health still mounts a provisional Sleep Score and a Fitness Age card.** They are gone from the default Home glance; they still exist as WHOOP-shaped composites on Health. If the product rule is “nothing provisional,” those cards should not lead Health. Sufficiency + consistency + efficiency stay. Fitness Age can remain in Customize / a lab section.

6. **Widget / Live Activity still lead Recovery %.** Today now leads with the whiteboard; the Home Screen widget is still a Recovery gauge (`AtriaWidget.swift`). Mirror HRV / RHR / sleep-vs-need / yesterday load, or the lock screen will keep teaching the old religion.

### Still leftover, but do **not** code until you have nights

These are measurement campaigns. Writing more Swift without data would create the next provisional number.

| ID | What | Why not now |
|---|---|---|
| Sleep Need slope fit | Hours of extra sleep per unit TRIMP from *your* nights | The 37-min-at-15 mapping is labeled. Fitting without a corpus is a new invention. |
| Recovery outcome calibration (§9.12) | Does blended z predict next-day HRV / RHR / RPE? | Needs 30–90 worn days. Until then Recovery stays an index. |
| `docs/14` SpO2 + skin °C | Health Monitor tiles 4 and 5 | Hardware exists; decoder does not. Reference oximeter + skin probe. |
| GAP-10 overnight load | Real stress-during-sleep model | HR-only 0–3 chart is enough. Do not put it in Sleep Score. |
| GAP-12 stages vs PSG | REM/Deep as measured | Keep estimate labels. Do not promote. |
| GAP-11 activity type | Named sport auto-detect | IMU. Blocked by §0 until Gate 4 is sealed. |
| Smart wake | Light/awake + HR slope | UI already admits hard alarm. Do not build on HR-only stages. |

### Still bullshit if it leads the product

| Thing | Status now | Action |
|---|---|---|
| Recovery % as the day’s decision | Secondary on Today; still ring center + widget + coach target | Keep as index. Lead with whiteboard everywhere. |
| Sleep Score 50/25/15/10 | Persisted, labeled provisional, still on Health | Demote off Health hero. |
| Fitness Age / Healthspan | Off default Home; still a Health card | Hide or lab-only. |
| Coach 9–17 | Unchanged | Replace the sentence, not the kernel. |
| Muscular fuse into one 0–21 | Shipped provisional | Split the display. |
| 12.4 Atria = 12.4 WHOOP | Never claimed in code; users will still compare | Never chase. |
| All-day steps “just fix it” | Gate 4 open | **Do not touch.** |
| Stages as EEG | Honesty gates exist | Do not promote. |
| SpO2 % / °C from raw u16s | Still forbidden | Keep forbidden. |

### What replacing WHOOP still requires (no APIs, no cost)

You already have the daily loop’s **measurements**. What official WHOOP still wins on, without you copying their scores:

1. **The night never vanishes.** This is reliability, not a metric. Item 1. Highest remaining replacement value.
2. **Morning sentence + lock screen** that match the whiteboard, not a lone Recovery ring. Items 2, 3, 6 above.
3. **Health Monitor completeness** — HRV, RHR, respiration are local. SpO2 and skin deviation wait on `docs/14`.
4. **Automatic enough sleep** — you just gated auto-confirm. Let it bake on-device. Do not retune motion constants.
5. **Workout as review, not auto-typed sport.** Already correct. Do not start GAP-11.
6. **You will not replace MG ECG / BP / Healthspan on a 4.0.** Do not try.

“Nothing provisional” now means: **stop adding composites.** Ship reliability, show TRIMP, split lifting from cardio, demote the remaining Health/widget heroes, then wear the strap for `docs/14` and a Recovery outcome log. Anything else is another invented percent.
)
