# Remaining WHOOP-Informed Product Gaps

Status: filtered implementation backlog  
Reviewed: 2026-08-06  
Scope: Recovery, Strain, Sleep, automatic activity/sleep detection, and the WHOOP screenshots reviewed with those systems

## Purpose

This document contains only work that remains materially incomplete in Atria.

It intentionally excludes features Atria already implements adequately, features Atria implements more transparently than the WHOOP reference, and visual clones that would add duplicate surfaces without improving the underlying decision a user can make.

The standard for keeping an item is that at least one of the following is true:

1. The current calculation can contradict another Atria surface.
2. The current name or presentation claims more than the evidence supports.
3. A core Recovery, Strain, Sleep, or detection capability is genuinely absent.
4. The missing work materially improves a user's understanding or action.
5. The work is required before Atria can make a scientifically stronger claim.

WHOOP's exact scores are proprietary. The goal is not numerical cloning. The goal is an internally consistent, evidence-qualified Atria implementation that offers comparable product utility.

## Executive decision

The remaining work is concentrated in five areas:

- Make historical Sleep Need and Sleep Consistency internally consistent.
- Correct Recovery and heart-rate-zone semantics.
- Finish the current-generation composite Sleep Score without fabricating missing inputs.
- Add muscular load and limited automatic activity classification.
- Validate research-grade sleep stages and physiological-load estimates before expanding their claims.

Everything else from the reviewed screenshots is either already implemented, already available through a stronger Atria interaction, or not valuable enough to justify another surface.

## P0 — Correctness and truthfulness

### GAP-01 — Persist each night's adaptive Sleep Need

#### Problem

The Hours vs. Need chart has the correct line-and-node interaction and weekly navigation, but its historical `Sleep needed` series is currently constructed from a constant base need. The Sleep Need ledger uses the full calculation:

```text
baseline + strain adjustment + sleep-debt adjustment - nap credit
```

The chart and ledger can therefore disagree for the same night.

#### Required implementation

- Add a frozen `sleepNeedSeconds` or equivalent value to the daily/nightly rollup schema.
- Save the exact final adaptive need used to calculate that night's Sleep Sufficiency.
- Plot that frozen value in Hours vs. Need.
- Leave old nights without a trustworthy frozen value missing. Do not recompute them using today's baseline or today's debt.
- When a sleep window is edited or merged, preserve the frozen need while atomically updating the linked achieved duration and Sufficiency. A need changes only before that physiological cycle is frozen, never because the screen was reopened later.

#### Acceptance criteria

- The need shown in the nightly ledger, Sufficiency calculation, weekly chart, day history, and accessibility text is identical.
- The need line varies when strain, debt, or naps changed across nights.
- Missing historical need produces a gap rather than a reconstructed value.
- Navigating weeks never mutates a saved historical need.

#### Evidence

- Chart: `AtriaSleepPlannerCharts.swift`, `AtriaSleepDebtChartCard`
- Need calculation: `AtriaSleepBudget.swift`
- Current rollup schema: `DailyRollupStore.swift`

---

### GAP-02 — Use one Sleep Consistency engine

#### Problem

Atria currently exposes two related but different interpretations:

- The numeric score combines duration regularity and sleep-midpoint regularity.
- The Sleep Schedule visual verdict uses bedtime and wake-time dispersion.

Those values can disagree while appearing to describe the same thing.

#### Required implementation

Define one canonical consistency result containing:

- bedtime regularity;
- wake-time regularity;
- combined percentage;
- qualification/confidence;
- typical bedtime and wake time;
- per-night deviations;
- an optional recommended bedtime/wake window from the Sleep Planner.

Use the sleep event's recorded timezone and local civil time. Travel nights must not be interpreted using the phone's current timezone.

The existing schedule visualization should remain. It is clearer than the older unlabeled bar stack and only needs to consume the canonical result.

#### Acceptance criteria

- The percentage, verdict, contributor row, trend and chart all use the same calculation.
- At least five qualified nights are required before showing a scored result.
- The latest night is visually identifiable.
- The chart shows exact latest bed/wake times and the typical or recommended window.
- A timezone change does not silently shift old nights.

#### Evidence

- Current visual: `AtriaHealthScreen.swift`, `AtriaSleepConsistencyStrip`
- Current score: `Sessions.swift`, `sleepConsistencyPercent`

---

### GAP-03 — Make heart-rate zones HRR-based everywhere

#### Problem

Atria's internal load logic uses heart-rate reserve in important places, but completed-workout and user-visible zone boundaries still use percentage of maximum heart rate. That produces two definitions of intensity.

#### Canonical calculation

```text
HRR = maxHR - restingHR
zone boundary = restingHR + intensity * HRR
```

#### Required implementation

- Use the same HRR boundaries for live workouts, target selection, completed-workout distribution, daily zone minutes and explanations.
- Display the actual BPM range beside every zone.
- Freeze the max HR and resting HR inputs used for a workout, or freeze the resulting BPM boundaries, so later profile changes do not rewrite history.
- Recompute old sessions only when their raw HR samples and historical profile inputs are available.
- Mark unrecomputable aggregated sessions as legacy rather than silently changing their interpretation.

#### Acceptance criteria

- A zone has the same BPM boundaries before, during and after a workout.
- Live target haptics use those same boundaries.
- Zone percentages and durations sum to recorded evidence time.
- Sparse recordings remain explicitly incomplete.

#### Evidence

- Completed zone UI: `AtriaActivityMonitor.swift`, `workoutZoneRows`
- Strain calculation: `AtriaAnalytics.swift`

---

### GAP-04 — Remove direct nap uplift from Recovery

#### Problem

Atria can directly raise the morning Recovery score using HRV observed during a later nap. This changes the meaning of a supposedly morning-frozen score and diverges from the sleep-to-sleep cycle model.

Naps should affect future Sleep Need and can have their own observed physiological summary. They should not rewrite the day's established Recovery score.

#### Required implementation

- Remove `AtriaNapRecovery` adjustment from the displayed and persisted Recovery result.
- Keep nap duration as a credit in the following Sleep Need.
- If nap HRV is qualified, show it as a separate nap observation rather than a Recovery replacement.
- Remove `after nap` Recovery copy and related debug-only product states after migration.

#### Acceptance criteria

- One main sleep produces one immutable Recovery for the physiological cycle.
- Adding, editing or deleting a nap does not change that Recovery.
- The next Sleep Need responds to the nap exactly once.

#### Evidence

- Nap adjustment: `AtriaSleepBudget.swift`, `AtriaNapRecovery`
- Display integration: `Sessions.swift`, `napAdjustedRecovery`

---

### GAP-05 — Stop calling the HR-only overnight projection “Sleep stress”

#### Problem

The current overnight projection is derived from mean heart rate relative to resting heart rate. It deliberately does not infer HRV, yet the card title still says `Sleep stress`.

The visualization is useful, but the claim is too strong.

#### Required implementation now

- Rename the feature to `Overnight HR load` or `Elevated HR during sleep`.
- Preserve the 0–3 visualization only if the scale is explicitly described as an Atria HR-load scale.
- Keep missing-wear gaps visible.
- Continue identifying high periods and their clock ranges.
- Do not include this value in Recovery or a composite Sleep Score yet.

#### Acceptance criteria

- No production copy calls the HR-only result stress.
- The detail states the required baseline, coverage and inputs.
- The card never implies diagnosis or measured sleep stage.

#### Evidence

- Current projection and card: `AtriaHealthScreen.swift`, `AtriaSleepStressProjection` and `AtriaSleepStressCard`

## P1 — Complete product value using data Atria already records

### GAP-06 — Build the current-generation composite Atria Sleep Score

#### Problem

Atria correctly presents its current percentage as Sleep Sufficiency. It does not yet have the current-generation composite shown by WHOOP, which combines sufficiency, consistency, efficiency and overnight physiological load.

#### Required implementation

Create an Atria-specific composite with qualified components:

- **Sufficiency:** sleep achieved divided by the frozen adaptive Sleep Need.
- **Consistency:** the canonical result from GAP-02.
- **Efficiency:** only from motion-qualified sleep/wake evidence.
- **Overnight physiological load:** only after GAP-10 is validated.

WHOOP does not publish its weights. Atria must select and validate its own. Until then, continue showing component metrics without a composite.

#### Qualification behavior

- Do not substitute a population constant for a missing personal component inside the score.
- Do not renormalize a two-component result and present it as equivalent to the four-component score without an explicit provisional state.
- A missing component must be visible as missing.
- Store both the final score and component values used to produce it.

#### Acceptance criteria

- Tapping the score shows all components, values, qualification state and direction.
- The score is reproducible from the frozen stored inputs.
- `Sleep Sufficiency` remains the label wherever only hours-versus-need is shown.
- A component cannot influence the score unless it is independently displayable for that night.

---

### GAP-07 — Add the overnight heart-rate trace to Sleep detail

#### Problem

Atria already archives the required HR points and uses them to construct overnight HR load, but the Sleep detail does not expose the underlying HR trace.

#### Required implementation

- Add a full-width overnight HR chart using real archived points.
- Show sleep start and wake times.
- Keep missing intervals as gaps.
- Show the user's qualified overnight typical range when available.
- Overlay or mark high HR-load periods from GAP-05.
- Allow a Heart Rate / Overnight Load switch in one card rather than two duplicated cards.

#### Acceptance criteria

- The chart uses the exact sleep window and event timezone.
- A high-load period maps to the same timestamps in both modes.
- No smoothing bridges a missing-wear gap.
- Typical range requires a documented minimum number of qualified nights.

---

### GAP-08 — Add superset grouping to strength logging

#### Why this remains

The general exercise picker, search, custom exercises, set logging, RPE, rest timer, e1RM, PRs and exercise history are already implemented. Supersets are the one screenshot-visible strength workflow that is genuinely absent and materially useful for future muscular-load modeling.

#### Required implementation

- Let users group two or more selected exercises into an ordered superset.
- Preserve per-exercise sets, weights, reps and RPE.
- Track intra-superset transition time separately from between-round rest.
- Allow ungrouping without losing logged sets.
- Persist the grouping in the saved workout schema.

#### Acceptance criteria

- Reordering or ungrouping does not duplicate or delete a set.
- Rest timing remains understandable during a live session.
- Muscular-load code can distinguish ordinary sets from superset density.

## P2 — Models and validation that need new evidence

### GAP-09 — Add muscular load and combine it with cardiovascular Strain

#### Problem

Atria's 0–21 Strain is currently cardiovascular. Strength sessions can log rich work, but those inputs do not contribute a muscular component.

#### First supported scope

Calculate muscular load only for explicitly logged strength exercises using:

- exercise identity and movement class;
- body mass or effective moved mass where appropriate;
- external weight;
- repetitions;
- set duration or rep speed when available;
- RPE/proximity to failure;
- rest and superset density.

Keep cardiovascular and muscular load visible separately before combining them through a calibrated saturating function.

#### Do not do

- Do not infer precise muscular load from HR alone.
- Do not assign authoritative muscular load to an unlogged generic Strength session using only duration.
- Do not copy a proprietary WHOOP score by visual approximation.

#### Acceptance criteria

- The same saved sets deterministically reproduce the same muscular input score.
- Adding load, reps or RPE changes muscular load monotonically within sensible bounds.
- Combined Strain cannot double-count the same cardiovascular work without an explicit fusion rule.
- The UI distinguishes measured/logged, motion-estimated and unavailable muscular load.

---

### GAP-10 — Validate a real overnight physiological-load model

#### Problem

The existing HR-only projection is useful for visualization but insufficient for a stress claim or composite Sleep Score input.

#### Required evidence and model

- Five-minute HR level and slope.
- Short-window RR quality and HRV where qualified.
- Motion/wakefulness context.
- Personal overnight baseline.
- Exclusion of sensor dropout and known activity.
- Reference labels such as controlled interventions, validated questionnaires, or an external research protocol.

The 0–3 score must be calibrated and its thresholds documented. `High` should correspond to a validated threshold, not merely a convenient color boundary.

#### Acceptance criteria

- Held-out validation is performed at the participant level.
- HR-only fallback is labeled separately and cannot silently enter the validated score.
- Coverage and uncertainty are stored with the result.
- Only the validated result can contribute to the composite Sleep Score.

---

### GAP-11 — Train a limited automatic activity-type classifier

#### Problem

Atria already detects generic sustained-exertion candidates and offers 77 manual activity types. It cannot reliably infer a type from HR alone.

#### Recommended first scope

Train only a small distinguishable set:

- walking;
- running;
- cycling;
- strength training;
- other workout.

Use synchronized accelerometer/gyro windows, cadence, orientation, HR response, duration and user-confirmed labels. Run the model on-device where practical.

#### Product behavior

- High confidence: preselect one suggestion for review.
- Medium confidence: show up to three suggestions.
- Low confidence: ask the user to choose without pretending to know.
- Corrections become future labels only with appropriate consent.

#### Acceptance criteria

- Evaluation uses participant-separated validation.
- The generic detector remains independent from the type classifier.
- A wrong type prediction cannot automatically overwrite or save a workout without review until accuracy is demonstrated.
- Per-class precision and recall are documented.

---

### GAP-12 — Validate sleep staging against a reference dataset

#### Problem

Atria correctly suppresses HR-only hypnograms and shows stages only with trusted motion evidence. `Motion validated` does not mean the stage classifier itself has been validated against polysomnography.

#### Required implementation program

- Gather synchronized PSG or another defensible labeled reference dataset.
- Train/test using HR, RR-derived features, respiration and motion.
- Split training and evaluation by participant, not by epoch.
- Report sleep/wake performance separately from REM/Light/Deep classification.
- Store model version and per-night confidence.

Stage typical ranges and stage-weighted Recovery must remain blocked until this work is complete.

#### Acceptance criteria

- The app distinguishes sensor-evidence qualification from model validation.
- Low-confidence nights retain duration and vitals without a stage timeline.
- Typical stage ranges require enough qualified nights from a validated model.
- No stage is described as measured EEG.

---

### GAP-13 — Calibrate the end-to-end Recovery model

#### Problem

Atria's Recovery model is transparent and useful, but its weights and logistic mapping are engineering assumptions rather than a validated readiness model.

#### Required implementation program

- Preserve the existing model as a versioned baseline.
- Evaluate a robust rolling personal baseline, including a 30-day comparison horizon while retaining a minimum recent-night qualification rule.
- Freeze every nightly input and model version with the result.
- Validate against held-out outcomes such as next-day HRV/RHR, reported fatigue and standardized workout performance.
- Test missing-input behavior independently.
- Do not add sleep stages, SpO2, temperature or cycle phase merely because WHOOP lists them.

#### Acceptance criteria

- Calibration and discrimination metrics are documented on held-out users.
- Score revisions create a new model version rather than rewriting historical scores.
- The contributor display exactly reconciles with the stored calculation.
- Unsupported sensor inputs remain absent, not neutral placeholders.

---

### GAP-14 — Keep temperature and SpO2 behind decoder-validation gates

#### Problem

WHOOP uses skin temperature and SpO2 in parts of its physiological system. Atria has candidate/research paths but no validated production decoder for either signal.

#### Required work before product integration

- Establish packet semantics against an independent reference device.
- Validate units, range, placement effects, dropout behavior and calibration.
- Define quality flags and missing-data semantics.
- Complete the existing protocol-validation runbook.
- Only then consider contribution to Recovery or Health Monitor.

#### Acceptance criteria

- No percentage or temperature is displayed from candidate frames alone.
- Validation includes repeated participants and reference-device comparison.
- A failed or low-quality reading remains missing.
- Recovery does not renormalize unsupported inputs as if they were observed.

#### Evidence

- Existing validation plan: `docs/14-spo2-skin-temperature-decoder-validation.md`

## Explicitly excluded from the backlog

The following reviewed features should not be recreated as new work items:

- **Recovery ring, contributors and red/yellow/green weekly bars:** already implemented.
- **Another Recovery/HRV/RHR carousel:** Atria's scrub companions, baseline bands and separate metric details provide stronger context.
- **Peak / Perform / Get By Sleep Planner:** already implemented, including learned efficiency and Smart Wake.
- **Another Hours vs. Need visualization:** the interaction already exists; only the historical need data must be corrected by GAP-01.
- **Sleep Need ledger:** already itemizes baseline, strain, debt and nap credit.
- **A second Sleep Consistency chart:** retain and repair the existing schedule view through GAP-02.
- **A less-qualified hypnogram:** Atria's evidence gating is better than always drawing a confident stage chart.
- **Workout HR/Stress trace and zone distribution:** already implemented.
- **A larger manual activity catalog:** 77 categorized activity types already exist. The remaining need is classification, not more names.
- **A replacement exercise picker:** search, groups, custom exercises, set logging, RPE, history, e1RM and PRs already exist.
- **A Strain / Avg HR / Calories tab clone:** these metrics do not need to share one carousel; calories are estimates and Atria's contextual companion charts are more useful.
- **Another weekly bar screen:** Atria's weekly report already uses semantically colored bars.
- **Another Daily Outlook card:** Today highlights, Today's Plan, Journal and weekly plans already cover the jobs. A new summary would likely repeat Recovery, Strain, Sleep and Stress.
- **Duplicate Add Activity and Start Activity controls on Home:** both workflows already exist; adjacency is not worth additional home-screen density.
- **A new customizable dashboard:** Atria already supports metric visibility, ordering, sizing and grid/list layout.
- **A new Health Monitor or Stress Monitor:** both already exist.
- **A replacement Journal impact system:** Atria already provides statistically gated, explicitly associative behavior insights.
- **A new generic sleep or exertion detector:** both candidate systems already exist and use conservative review gates. Only automatic activity-type classification remains.
- **Cycle-phase adjustment copied directly into Recovery:** Atria already presents opt-in cycle/recovery patterns. A score modifier should remain a non-goal until separately validated.
- **Exercise demonstration media:** useful content, but not required for Recovery, Strain, Sleep or detection correctness.
- **A universal “typical workout HR” band:** misleading without normalization for activity type, duration and workout intent. The overnight typical range in GAP-07 is better defined.

## Recommended execution order

1. GAP-01 — frozen adaptive Sleep Need.
2. GAP-02 — canonical Sleep Consistency.
3. GAP-03 — HRR zone unification.
4. GAP-04 — remove nap Recovery uplift.
5. GAP-05 — truthful overnight HR-load naming.
6. GAP-07 — overnight HR/load chart.
7. GAP-08 — superset schema and workflow.
8. GAP-10 — validate overnight physiological load.
9. GAP-06 — composite Sleep Score after all required components are qualified.
10. GAP-09 — muscular load and cardiovascular/muscular fusion.
11. GAP-11 and GAP-12 — labeled-data programs for activity classification and sleep stages.
12. GAP-13 — Recovery calibration.
13. GAP-14 — sensor-decoder validation when reference captures are available.

## Research basis

- [WHOOP Recovery](https://support.whoop.com/s/article/WHOOP-Recovery?language=en_US)
- [WHOOP Strain](https://support.whoop.com/s/article/WHOOP-Strain?language=en_US)
- [WHOOP Sleep](https://support.whoop.com/s/article/WHOOP-Sleep?language=en_US)
- [Automatic and Manual Activity Detection](https://support.whoop.com/s/article/Automatic-and-Manual-Activity-Detection?language=en_US)
- [Strain and Recovery Details](https://support.whoop.com/s/article/Strain-and-Recovery-Details-Screens)
- [WHOOP Recovery Insights](https://support.whoop.com/s/article/Recovery-Insights)
- [WHOOP Calibration Timeline](https://support.whoop.com/s/article/Calibration-Timeline)
- [WHOOP Cycles](https://support.whoop.com/s/article/WHOOP-Cycles)

## Product rule

When a WHOOP-inspired feature is considered in the future, first ask:

> Does this add a trustworthy new decision, or only another way to display a number Atria already explains?

If it is only another display, do not add it.
