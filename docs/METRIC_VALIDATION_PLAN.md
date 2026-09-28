# Metric validation plan

Written 2026-09-27, after the step counter was validated on the iPhone
(95/100, 80/80, 107/120, 100/100 with the phone locked, about 0 false steps at
a desk). This plan does the same for every other number Atria shows: a known
truth, a controlled test, repeats, a pass bar set before the test, and a
regression check that keeps it true.

Nothing here is implemented yet. Each section says what the owner does, what
Atria records, what gets compared, and what counts as a pass.

## 1. Rules for every test

1. **Truth first.** Each test names its reference before it starts: a
   metronome, a chest strap, a stopwatch, a diary, or a second device. If there
   is no reference, the test checks behaviour ("goes up after a hard day"), and
   the metric keeps an estimate label until a reference exists.
2. **Pass bars are written before the data.** The bars in each section below
   are the ones used. Changing a bar needs a dated note saying why.
3. **Repeats and conditions.** One good run proves nothing. Each metric gets at
   least 3 repeats per condition and at least 2 conditions (for example rest
   and exercise, or phone foreground and locked).
4. **No tuning on one person's single run.** Atria ships to many users. A constant is only changed when the fix is
   physiological, or per-user and self-calibrating, and it has to hold across
   every repeat.
5. **Same pipeline as users.** Tests read what the app stores (ledger, rollups,
   archive) through the same pull used today (`devicectl device copy from`).
   No debug-only code paths.
6. **Privacy.** Raw reference data (chest-strap RR, diaries, pulls) stays on
   the Mac in `~/atria-validation/`. It is never committed: the repo is public.
   Only summary errors (MAE, bias, counts) go into issues and this file.
7. **Every pass becomes a test.** A validated behaviour gets a unit test on an
   anonymised, derived fixture (numbers only, no timestamps tied to the owner),
   so a later change cannot silently undo it.

## 2. Shared tooling to build first

| Tool | What it does | Status |
|---|---|---|
| `tools/strap-mac/metronome_track.py` | Sample-exact click track with labelled start and stop times | Done; used for steps |
| Terminal-panel runner | Plays audio from the Mac (Bash sandbox audio is silent) | Done |
| `tools/validation/pull_day.sh` | Pulls ledger, rollups, sessions and prefs from the phone into `~/atria-validation/<date>/` | To build |
| `tools/validation/ref_polar.py` | Records a Polar H10 (or any BLE chest strap) HR and RR stream to CSV on the Mac, with wall-clock time | To build; needs a chest strap |
| `tools/validation/align.py` | Aligns Atria samples and reference samples on wall time, cuts them into labelled windows | To build |
| `tools/validation/score.py` | Computes MAE, bias, limits of agreement, rank correlation and pass/fail per window, and writes a local report | To build |
| `AtriaVisualAuditUITests` | Opens screens on the phone and screenshots values | Done |
| Diary card | A quick in-app or Notes log: bedtime, wake, workout start and stop, alcohol, illness | Owner, daily |

## 3. Metrics, one by one

Each section covers the current method, the reference, the procedure, what gets
compared, the pass bar and the issue it closes. Order follows dependency: most
metrics sit on heart rate and RR intervals, so those go first.

### 3.1 Heart rate (live and history)

Tracking issue: [#51](https://github.com/adidshaft/atria/issues/51) — anyone with the reference device can run it.

- **Method now.** Standard 2A37 heart rate, plus heart rate from history
  records.
- **Reference.** A chest strap (Polar H10 or similar) worn at the same time.
  An Apple Watch works as a weaker second reference.
- **Procedure (about 25 min, 3 sessions on different days).**
  1. 5 min seated rest.
  2. 5 min walking at the 100/min metronome.
  3. 3 min stairs or a brisk jog.
  4. 3 sets of a strength exercise with 90 s rests.
  5. 5 min seated recovery.

  Wrist placement stays the same each session. One session repeats with the
  strap one finger looser.
- **Compare.** Second-by-second HR after alignment. Per phase: MAE, bias, and %
  of seconds within 5 bpm. Also lag at the step changes.
- **Pass.** Rest MAE ≤ 2 bpm. Walking MAE ≤ 4 bpm. Jog and strength MAE ≤ 6 bpm,
  with ≥ 85% of seconds within 5 bpm. Lag ≤ 5 s.
- **Also checks.** Artifact rejection (sudden spikes held rather than shown),
  and whether history heart rate matches live heart rate for the same minutes.
- **Closes or advances.** #3 (Gate D, HR part).

### 3.2 RR intervals and HRV (RMSSD)

Tracking issue: [#52](https://github.com/adidshaft/atria/issues/52) — anyone with the reference device can run it.

- **Method now.** RMSSD over RR intervals inside the confirmed main sleep,
  reported as the morning HRV. #47 is still open on whether WHOOP 4 RR units
  need source-specific scaling.
- **Reference.** Chest-strap RR, recorded at the same time.
- **Procedure.**
  1. **Morning, 7 days.** 5 min lying still after waking, both devices on,
     metronome breathing at 6/min for the last 2 min (a large, known RSA).
  2. **Overnight, 3 nights.** Chest strap on for the whole night.
- **Compare.**
  - RR intervals beat by beat: match rate, and timing error for matched beats.
    This settles #47 directly.
  - RMSSD per 5-min window: bias, limits of agreement, correlation.
  - The nightly HRV Atria reports against RMSSD from the chest strap over the
    same window.
- **Pass.**
  - ≥ 90% of beats matched within 20 ms.
  - RMSSD bias ≤ 3 ms, with limits of agreement ±10 ms at rest.
  - Nightly HRV within 10% on all 3 nights.
- **Closes or advances.** #47, #2 (Gate C, HRV part), #6 (HealthKit HRV export
  stays off until this passes).

### 3.3 Resting heart rate

Tracking issue: [#53](https://github.com/adidshaft/atria/issues/53) — anyone with the reference device can run it.

- **Method now.** Overnight resting value from the confirmed main sleep.
- **Reference.** The lowest 5-min average of chest-strap HR in the same sleep
  window (the same definition, from better data). An Apple Watch resting HR is a
  sanity check only, because it uses a different definition.
- **Procedure.** The same 3 overnight chest-strap nights as 3.2, plus 7 normal
  nights compared against the Apple Watch if one is worn.
- **Pass.** ±2 bpm on every chest-strap night.
- **Closes or advances.** #2, #50 (baselines from per-minute data).

### 3.4 Respiratory rate

Tracking issue: [#54](https://github.com/adidshaft/atria/issues/54) — anyone with the reference device can run it.

- **Method now.** Breathing rate estimated from how heart rate rises and falls
  with each breath, during sleep.
- **Reference.** Paced breathing to a metronome. The rate is known exactly.
- **Procedure.**
  1. Lie still, 4 min each at 6, 10 and 15 breaths per minute (breath clicks
     from `metronome_track.py` at a slow rate).
  2. Repeat on 3 days.
  3. Overnight, compare against the Apple Watch sleep breathing rate if
     available.
- **Pass.** Paced blocks within ±1 breath/min. Overnight within ±1.5 of the
  Apple Watch, with no drift over nights.
- **Note.** The app only shows respiratory rate for sleep today. This test also
  shows whether a 5-min daytime reading is honest enough to offer.
- **Closes or advances.** #34 (five-biomarker nightly panel).

### 3.5 Sleep detection: onset, wake and duration

Tracking issue: [#55](https://github.com/adidshaft/atria/issues/55) — anyone with the reference device can run it.

- **Method now.** HR/RR windows plus the motion tick rate from the strap (asleep
  0.05–0.8 ticks per minute, awake 8–12), and review cards for anything not
  certain. Known failure: history not yet drained leaves holes that split a
  night into pieces.
- **Reference.** A diary (lights-out and final wake, to 5 min), plus phone
  screen-off and screen-on times, plus an Apple Watch if one is worn. The
  schedule shifts (main sleep around 13:15–19:15 IST on some days), and the
  tests must include those days.
- **Procedure.**
  - 14 consecutive days of normal life, including at least 3 shifted days,
    2 naps, 1 night with the strap charging mid-sleep, and 1 night with
    Bluetooth off at bedtime so the night only arrives through history.
  - Every morning: a diary line, and a pull of the stored night.
- **Compare.** Per night:
  - Onset and wake errors against the diary.
  - Duration error.
  - Whether the night was confirmed automatically, sent for review, or missed.
  - Whether a nap was kept separate from the main sleep.
- **Pass.**
  - Onset and wake within ±15 min on ≥ 12 of 14 nights.
  - Duration within ±20 min.
  - Zero missed nights when strap coverage is ≥ 80%.
  - Zero naps merged into the main sleep.
  - The Bluetooth-off night lands within 1 h of reconnecting.
- **Closes or advances.** #25, #50, and the drain work in #46.

### 3.6 Sleep stages

Tracking issue: [#56](https://github.com/adidshaft/atria/issues/56) — anyone with the reference device can run it.

- **Method now.** Stages estimated from heart rate and motion, labelled
  "Estimated" on HR-only nights.
- **Reality.** Only a sleep lab (polysomnography) gives true stages. An Apple
  Watch is itself an estimate.
- **Procedure.** 10 nights with the Apple Watch worn on the other wrist.
  30-second epochs aligned.
- **Compare.** Epoch agreement and Cohen's kappa, plus total minutes per stage.
  Reported, not tuned against.
- **Pass (as an agreement check, not accuracy).**
  - Kappa ≥ 0.4 against the Apple Watch.
  - Deep and REM totals within ±25 min on 8 of 10 nights.

  If it misses, the stage view keeps its estimate label and the numbers stay
  off Recovery.
- **Optional.** If the owner can access one home sleep test, one PSG-scored
  night is worth more than every Watch night combined.

### 3.7 Sleep need, performance and consistency

Tracking issue: [#57](https://github.com/adidshaft/atria/issues/57) — anyone with the reference device can run it.

- **Method now.** Arithmetic on validated inputs: need from baseline plus
  strain plus debt; performance = slept ÷ need; consistency uses the circular
  centre of bedtimes (#41 fixed).
- **Reference.** Recomputed by hand in `score.py` from the diary and the stored
  night.
- **Pass.** Exact match, to the minute and the percent, on all 14 nights of 3.5.
  Any difference is a code bug, not a tuning question.

### 3.8 Recovery

Tracking issue: [#58](https://github.com/adidshaft/atria/issues/58) — anyone with the reference device can run it.

- **Method now.** A logistic score from HRV, resting HR and sleep, each compared
  with the person's own baseline. Resting HR is weighted 0.20 when HRV is
  missing.
- **Reality.** Recovery has no ground truth. It is validated on behaviour.
- **Reference.**
  - **Known perturbations with a clear direction.** A hard workout day, a short
    night (under 5 h), alcohol, a normal rest day, and a sick day if one happens.
  - **The WHOOP app's recovery for the same days**, if the membership is still
    active. Caveat: Atria acknowledging (consuming) strap history can starve the
    WHOOP app of the same records. It needs alternating days, or a
    history-read-only mode for the test period.
- **Procedure.** 21 days, with each perturbation logged in the diary and at
  least 2 of each.
- **Compare.**
  - The direction of change the next morning against the owner's baseline.
  - Rank correlation with WHOOP recovery.
- **Pass.**
  - The correct direction on ≥ 80% of perturbation mornings.
  - Rank correlation with WHOOP ≥ 0.6, if available.
  - No morning score from fewer than the required baseline nights.
- **Closes or advances.** #2 (Gate C).

### 3.9 Strain, heart-rate zones and max HR

Tracking issue: [#59](https://github.com/adidshaft/atria/issues/59) — anyone with the reference device can run it.

- **Method now.** Banister TRIMP on heart rate reserve, mapped to a 0–21 day
  strain. Zones are % of max HR. Max HR is from age until a sustained peak
  suggests an update.
- **Reference.** Chest-strap HR for the same sessions, fed through the same
  strain formula. That isolates sensor error from formula choice. The WHOOP
  app's strain is a second check if available.
- **Procedure.**
  - 10 logged workouts: 4 cardio, 3 strength, 2 intervals, 1 walk.
  - One optional max-HR test: a 20-min warm-up, then 3 × 3-min hard efforts on
    a bike or hill. Skip it if unwell.
- **Compare.**
  - Workout strain, Atria against the chest strap.
  - Minutes per zone.
  - Day strain on the same days.
  - Suggested max HR against the tested max.
- **Pass.**
  - Workout strain within ±1.0 on 9 of 10.
  - Zone minutes within ±3 min per zone.
  - Max HR within ±4 bpm of the tested value.
- **Closes or advances.** #3 (Gate D).

### 3.10 Stress

Tracking issue: [#60](https://github.com/adidshaft/atria/issues/60) — anyone with the reference device can run it.

- **Method now.** A versioned physiological scorer from heart rate (and RR when
  present), 0–3, with 5-min estimates.
- **Reference.** A labelled lab-style session plus a free-living tag log.
- **Procedure (about 30 min, 3 days).**
  1. 5 min calm reading.
  2. 5 min paced breathing at 6/min.
  3. 5 min mental arithmetic under time pressure (serial 7s aloud, with a
     timer).
  4. 5 min of the owner's own stressful task (email, a meeting).
  5. 5 min recovery.

  Then 7 days of free-living tags ("calm", "stressed", "exercise") as they
  happen.
- **Compare.** Stress per block and per tag. Recorded movement is excluded, so
  exercise is not called stress.
- **Pass.**
  - Arithmetic higher than calm reading on 3 of 3 days.
  - Paced breathing lowest on 3 of 3.
  - Free-living tags separate (the "stressed" median above the "calm" median)
    over 7 days.
  - Walking does not read as high stress.
- **Closes or advances.** #32, #30.

### 3.11 Skin temperature (relative)

Tracking issue: [#61](https://github.com/adidshaft/atria/issues/61) — anyone with the reference device can run it.

- **Method now.** Offset 68 of the history record, reported as the change from
  the strap's own sleep baseline (turned on 2026-09-27). No absolute values.
- **Reference.** Direction checks, plus the Apple Watch wrist temperature
  deviation if worn.
- **Procedure.**
  - 14 nights for the baseline plus comparison.
  - Log known shifters in the diary: a warm or cold bedroom, alcohol, late
    heavy exercise, illness.
  - One controlled night: bedroom about 3 °C warmer than usual.
- **Pass.**
  - Nightly deviation correlates with the Apple Watch deviation (r ≥ 0.6 over
    14 nights).
  - The warm-room night shows a positive deviation.
  - No value appears before 3 baseline nights.
- **Closes or advances.** #31 (skin part), #34.

### 3.12 Blood oxygen (research only; stays hidden)

Tracking issue: [#62](https://github.com/adidshaft/atria/issues/62) — anyone with the reference device can run it.

- **Status.** The red and IR bytes are DC levels. A ratio built from them is a
  constant, about 80%. SpO2 stays off.
- **Lead worth testing.** A history stream type `0x19`, about 400 records a day
  and not yet decoded, may carry an SpO2 value computed by the strap itself.
- **Procedure.**
  - 5 nights with a fingertip pulse oximeter that logs overnight.
  - Capture every `0x19` record.
  - Look for a field that tracks the oximeter (normal nights sit around 94–99%).
  - No breath-hold experiments.
- **Pass to enable.** A field within ±2% of the oximeter on ≥ 90% of minutes,
  on all 5 nights. Otherwise SpO2 stays off.
- **Closes or advances.** #31 (SpO2 part).

### 3.13 VO2max

Tracking issue: [#63](https://github.com/adidshaft/atria/issues/63) — anyone with the reference device can run it.

- **Method now.** The heart-rate-ratio method (max HR ÷ resting HR), so it
  inherits every error in those two.
- **Reference.** The Apple Watch Cardio Fitness value if available, or a lab
  test. The simplest field check is a Cooper 12-min run on a flat track.
- **Pass.** Within ±10% of the reference, and only after 3.3 and 3.9 pass.
- **Closes or advances.** #5 (trend confidence).

### 3.14 Active calories

Tracking issue: [#64](https://github.com/adidshaft/atria/issues/64) — anyone with the reference device can run it.

- **Method now.** Keytel heart-rate equation from profile weight, age and sex.
- **Reference.** The Apple Watch active energy. It is itself only about ±20%,
  so this is a sanity band, not accuracy.
- **Procedure.** The 10 workouts from 3.9, plus 7 whole days.
- **Pass.** Within ±20% of the Watch on workouts. The "Estimate" wording stays
  on the tile regardless.

### 3.15 Detected workouts

Tracking issue: [#65](https://github.com/adidshaft/atria/issues/65) — anyone with the reference device can run it.

- **Method now.** Sustained raised heart rate, with motion hints when present.
  Shown as "Possible workout" until the user adds it.
- **Reference.** A diary of every real workout (start and stop, to the minute)
  plus 7 rest days.
- **Procedure.** 14 days that include at least 8 real workouts: 3 of them short
  (under 15 min), 2 strength, 1 with the phone left at home.
- **Compare.** Precision (possible workouts that were real), recall (real
  workouts that were caught), and start and end error.
- **Pass.**
  - Recall ≥ 90% for workouts of 15 min or more.
  - Precision ≥ 80%.
  - Start and end within ±3 min.
  - The phone-at-home workout appears after reconnecting.

### 3.16 Steps (remaining piece)

Tracking issue: [#21](https://github.com/adidshaft/atria/issues/21) — anyone with the reference device can run it.

- **Done.** The walks above, and background counting with the phone locked.
- **Left.** Whole-day totals against the history drained for the same day, and
  against the phone's own pedometer as a sanity band, over 7 normal days.
- **Pass.** Within ±10% of the pedometer on 6 of 7 days, with no double
  counting where live and history overlap.
- **Closes.** #21.

## 4. Order and timing

| Week | Work | Owner time |
|---|---|---|
| 0 | Build `pull_day.sh`, `ref_polar.py`, `align.py`, `score.py`; a dry run on one hour of data | none |
| 1 | HR sessions (3.1), morning RR/HRV (3.2), paced breathing (3.4), stress sessions (3.10) | about 40 min a day for 3 days |
| 1–2 | 3 overnight chest-strap nights (3.2, 3.3); sleep diary starts (3.5) | a diary line each morning |
| 2–3 | Workouts with the chest strap (3.9, 3.14, 3.15); perturbation days (3.8) | normal training, logged |
| 3–4 | Remaining sleep nights, stages (3.6), skin-temp nights (3.11), steps days (3.16) | a diary line each morning |
| any | SpO2 oximeter nights (3.12) | wearing the oximeter |

After each metric passes: add the regression test, drop any estimate label the
pass earns, update the issue, and re-run that metric's check on the phone after
every change that touches it.

## 5. What the owner needs to provide or decide

**Answered 2026-09-28: the maintainer has none of the reference equipment and
will not keep the diary.** Each item below is therefore an open call for
contributors: chest strap [#66](https://github.com/adidshaft/atria/issues/66),
watch or ring [#67](https://github.com/adidshaft/atria/issues/67), WHOOP
membership [#68](https://github.com/adidshaft/atria/issues/68), overnight
oximeter [#69](https://github.com/adidshaft/atria/issues/69), diary
[#70](https://github.com/adidshaft/atria/issues/70). What the maintainer can
still run alone: the metronome step walks (done), paced-breathing respiratory
rate (3.4), the labelled stress session (3.10) and the arithmetic checks (3.7).

Original list:

1. **A chest strap that exposes RR intervals** (Polar H10 is the reference
   standard). It is the single most useful piece of equipment: it unlocks
   3.1, 3.2, 3.3 and 3.9.
2. **Whether an Apple Watch can be worn on the other wrist** for 2–3 weeks
   (3.5, 3.6, 3.11, 3.13, 3.14).
3. **Whether the WHOOP membership and app are still active.** Recovery and
   strain have no better reference. It needs a plan so Atria and the WHOOP app
   do not fight over the strap's history.
4. **A fingertip pulse oximeter that logs overnight**, only if SpO2 matters
   (3.12).
5. **A daily diary habit** for 3–4 weeks: bedtime, wake, workouts, alcohol,
   illness. One line each.
6. **Consent to keep raw reference data on the Mac only**, outside the repo.
