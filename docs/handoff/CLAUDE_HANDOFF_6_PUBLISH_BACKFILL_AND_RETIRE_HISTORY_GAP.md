# Atria — Claude handoff 6: publish backfills in place, retire the zombie history gap, and close remaining sleep authority

Date: 2026-08-13 (Asia/Kolkata)  
Release branch: `dev`  
Exact pushed starting commit: `573e853399a208e94b5de1b85c45a5d24a4caa65` (`Stage HR-only nights and lead step copy with its frontier`)  
Remote parity at handoff: `HEAD...origin/dev = 0 0`  
Clean continuation source: `/private/tmp/atria-combined-successor.T76FQG/source`

## Hard cutline

This is a short closure pass, not another broad audit.

Do, in this order:

1. Make launch-time HR-only stage backfill publish in the same launch—no relaunch.
2. Make the persistent `history_sequence_gap` recovery converge to either repaired or an honest terminal gap; it must not re-arm forever or seize every fresh connection.
3. Fix the current sleep edit/day-ownership stale-publication path so a nap/main edit immediately updates the Today ring and Activity rows.
4. Wire the already-built **relative raw skin signal** only through its existing blocker-first authority, if checkpoints 1–3 are green.
5. Run focused tests and one short physical verification. Commit, push, and update the existing issues.

Timebox: approximately 3 hours implementation plus 30 minutes device verification. Stop and report a concrete blocker when the timebox is reached. Do not start a full-suite marathon, a redesign, TestFlight, or SpO₂ reverse-engineering.

## Worktree safety—mandatory

The user's main checkout at `<repo-root>` is old and intentionally dirty at `293d1a7c988bf99b6093b8529da0cf528d6e4896`. Do not edit, stash, reset, clean, stage, or commit there. It contains the user's chart work:

```text
Atria/Atria/AtriaAboutMetricSheet.swift
Atria/Atria/AtriaActivityMonitor.swift
Atria/Atria/AtriaExpandedChart.swift
Atria/Atria/AtriaGraphInspector.swift
Atria/Atria/AtriaHealthspanDetailView.swift
Atria/Atria/AtriaOverviewSections.swift
Atria/Atria/AtriaSleepPlannerCharts.swift
Atria/Atria/AtriaStepsWeekChart.swift
Atria/Atria/AtriaStrainRecoveryComboChart.swift
Atria/Atria/AtriaTrendChart.swift
Atria/Atria/AtriaVitalsCollectionSections.swift
Atria/Atria/HRV.swift
Atria/Atria/HeartRate.swift
Atria/Atria/Insights.swift
```

Continue only in `/private/tmp/atria-combined-successor.T76FQG/source`, after proving it is clean and still at exact `573e8533…`, or create a new clean detached worktree from `origin/dev`. This handoff file is coordination material; do not include it in the app commit.

## What `573e8533` already completed—do not redo

- HR-only confirmed/user-adjusted nights may generate stored `research-hr-estimate-v1-` stage segments only through explicit `allowHROnlyEstimate: true` call sites.
- Motion-backed `research-motion-v2-` semantics remain intact.
- HR-only estimate segments cannot escalate to validated stages, HealthKit stage export, recovery authority, or credited-duration reduction.
- Existing records can backfill stages while preserving `dayPrimaryChoice`.
- Step copy is frontier-led: `Counted through …`; percentage remains secondary/accessibility evidence.
- The `AtriaTests` scheme is the real test scheme. The `Atria` scheme produces “no test bundles available.”
- The 573e pass reported 512 focused tests green. Preserve its cost and authority contracts.

## Fresh physical truth from the exact installed `573e8533` build

I controlled iPhone Mirroring directly on 2026-08-13 around 01:00–01:10 IST. Synthetic taps **do route now** through `com.apple.ScreenContinuity`; the prior “Mirroring taps never land” blocker is stale. The iPhone is cabled, Mirroring is on, the strap is connected, and its displayed battery is 70%. No Passwords/Safari/Brave interaction was used.

### 1. Activity — Heart rate and Stress: PASS, with one remaining history warning

- Physiological day: `TODAY · WED, AUG 12`.
- Header still says `Strap data gap · history incomplete`.
- HR trace loads, its fill stays clipped to the plot, and the saved-activity marker band is above the plot.
- Stress trace loads, preserves real blank gaps, and uses the same marker band.
- Visible rows: Strength `10:31–10:55 PM` (23m, strain 1.0), Strength `9:53–10:15 PM` (22m, strain 1.2), main Sleep `6:15 AM–3:27 PM` (9h12), and a short record `12:58 AM–3:41 AM` still labeled **Sleep** (2h37, Confirmed).

Do not rework the chart fill or marker band. They are physically present.

### 2. Prior Strength detail: PASS

The 10:31–10:55 PM Strength record opens without a loading loop and shows:

```text
Strain 1.0
Duration 23m
Average HR 92
Peak HR 136
Calories 122
Time in heart-rate zones 23m
```

No edit was made or saved during inspection.

### 3. Trends: PASS and terminally honest

- Resting HR: 2 days, linear 61 → 54.
- Strain: 5 days; the unworn-day gap is not area-filled or bridged as a continuous run.
- HRV: `0d of data` and terminal copy `Not enough HRV yet`—no borrowed unqualified nightly value.

Do not fabricate a trend point to make the chart non-empty.

### 4. Sleep detail: renders, but is clearly an unvalidated estimate

The confirmed `6:15 AM–3:27 PM` sleep renders:

```text
9h12m
Estimated stages · HR-only
322 stored segments
Awake 0m / 0%
REM 2h24 / 26%
Light 3h00 / 33%
Deep 3h48 / 41%
RHR 52
HRV --
Respiration 9.5/min
```

The UI correctly says motion is unavailable and the boundaries are estimated from HR/breathing. Treat this as **presentation/provenance proof, not accuracy proof**. `0m awake`, `41% deep`, and rapid switching are reasons to retain low-confidence language. Do not tune ratios to resemble WHOOP without reference truth.

### 5. SpO₂: PASS—leave it alone in this pass

The card is blank and the detail says:

```text
Decoder not verified
Atria can't yet produce a validated SpO2 reading from this strap's sensor.
Rather than estimate, it leaves this blank—and tells you why.
```

This is correct. Do not add `110 - 25R`, clamp a red/IR ratio, synthesize PPG, or show an experimental percentage. Reverse-engineering remains `REFERENCE_REQUIRED` until there is a simultaneous independent oximeter corpus.

### 6. Strap steps: copy PASS; underlying gap still open

The Today card shows:

```text
Strap steps        1693
Counted through 11:29 PM
```

At inspection time it was about 01:05 AM. This is honest frontier-led copy, but the approximately 96-minute frontier lag and `history incomplete` banner prove the backlog is still live. Do not restore a leading coverage percentage and do not substitute phone/preliminary steps.

## Checkpoint 1 (P0): publish launch backfill in the same launch

### Proven defect

`SessionStore.continueDeferredLoadFollowUp` calls:

```swift
await backfillConfirmedSleepStagesFromSessions(
    reason: "deferred_session_load",
    deferDerivedPublication: true
)
```

Current anchors in `Atria/Atria/Sessions.swift`:

- `backfillConfirmedSleepStagesFromSessions`: around line 40308.
- `finishDeferredLoad`: around line 49745.
- `continueDeferredLoadFollowUp`: around line 49820; the call above is around line 49854.

The backfill durably writes the 322 segments, but the current process keeps its old sleep/dashboard snapshot. The user needed one relaunch before stages appeared.

### Required behavior

1. Keep stage generation off MainActor and preserve `allowHROnlyEstimate` opt-in/cost gates.
2. Have the backfill return a typed result containing at least `changed`, affected confirmed-sleep IDs/cycle days, and the committed confirmed-sleep revision.
3. After the confirmed-sleep save is durably complete, schedule exactly one current-generation derived publication for only the affected sleep/day surfaces.
4. Recheck canonical-session revision, confirmed-sleep revision, recovered ticket/generation, scene authority, and UIKit active state immediately before publication.
5. A stale completion publishes nothing. A newer user sleep edit wins.
6. Do not call broad archive recovery, restart BLE history, or synchronously rebuild the whole dashboard on MainActor.
7. `resumeDeferredLaunchCardSettlementIfNeeded` must not race and publish a pre-backfill snapshot. Either include the backfill commit in its exact fence or order the narrow republish after settlement with a newer revision.

### Required tests

- Start with a persisted confirmed main sleep with dense HR and `stageSegments == nil`.
- Run the real deferred-load follow-up once; without relaunch, assert stored stages, `sleepHistorySnapshot`, Today sleep detail/ring authority, and Activity sleep row all expose the same new revision.
- Count exactly one terminal publication and no publication from a stale generation.
- Race a user nap/main edit during the off-main stage build; the user edit survives and the stale backfill cannot overwrite its type, bounds, or `dayPrimaryChoice`.
- Re-run follow-up with no changes; assert no save loop and no extra publication.

## Checkpoint 2 (P0): make the Aug-6 range-loss ticket converge

### Proven defect

The durable gap has been re-arming since Aug 6 with reasons such as:

```text
history_sequence_gap_unconfirmed_previous_…_received_…
history_sequence_gap_replay_mismatch_expected_…_received_…
```

Source anchors:

- `Atria/Atria/AtriaWhoop4HistoryDrainState.swift`, sequence-gap reducers around lines 403 and 457.
- `Atria/Atria/AtriaBLEManager.swift`, range-loss state/timers around lines 2053–2111.
- `Atria/Atria/AtriaBLEHistoricalRecoveryPolicy.swift`, `rangeLossBackfillCanClear` around lines 1436–1455.
- Existing state tests: `AtriaWhoop4HistoryDrainStateTests`, `AtriaBLERecoveryCadenceTests`, `AtriaBackgroundDrainBacklogTests`, and `AtriaBLEHistoricalRecoveryPolicyStructureTests`.

`7b651294` allowed a workout requalifier to preempt the zombie drain; it did not retire or repair the zombie itself.

### Required state-machine outcome

For one exact missing range/boundary, the durable ticket must reach one of two outcomes:

1. **Repaired:** exact sequence continuity, archive persistence, ACK boundary, and live restoration are proven; then clear the ticket.
2. **Terminal unresolved gap:** after a bounded number of attempts with the same immutable source frontier and the same mismatch, persist the unavailable sequence interval/reason, release connection/drain ownership, and stop timer re-arm. UI copy must say that a historical interval is unavailable; it must not say fully synced.

New strap evidence or a materially newer source frontier may mint a fresh attempt. A minute ticker, relaunch, charging edge, or unchanged replay may not.

### Safety invariants

- Never delete or rewrite a valid durable prefix/suffix to make sequence numbers look contiguous.
- Never clear `rangeLossBackfillPending` merely because a command failed or the strap disconnected.
- Never let the zombie owner block current live HR/RR, an exact workout motion requalifier, or a fresh compact-motion drain.
- Keep stale ACK/generation rejection, prefix-only retirement, one history owner, and live HR continuity.
- A terminal gap remains visible as data-quality truth and is excluded from “Synced.”

### Required tests

- Reproduce one exact `history_sequence_gap` across multiple retry ticks and at least two simulated relaunches. Assert one bounded attempt budget and a terminal unresolved record, not perpetual re-arm.
- Prove a newer source frontier mints one new attempt; unchanged evidence does not.
- Prove valid rows on both sides remain byte-identical and stale/wrong-generation ACKs cannot clear the gap.
- Prove live HR and a workout R10 qualification request remain admissible while the terminal gap is parked.
- Prove the top banner and step-detail copy distinguish `repairing`, `terminal unavailable interval`, and actually `synced`.

## Checkpoint 3 (P0/P1): make nap/main edits atomically update ownership and presentation

### Physical symptom

Activity still shows the short `12:58–3:41` record as `Sleep · Confirmed` beside the `6:15–15:27` main sleep. The user had explicitly changed the earlier short episode to a nap. Earlier, the main ring did not update, Activity stayed at `Loading activity…`, and the two records moved to the wrong day in opposite directions.

Do not infer from labels. Pull the exact current confirmed-sleep records and identify their IDs, `source`, bounds, `dayPrimaryChoice`, event timezone, canonical day, and revision. Never silently delete a user record.

### Required behavior

- A user type change (main sleep ↔ nap) is one transaction: durable record, day ownership, cycle selector, Today ring, sleep snapshot, and Activity row all commit to the same revision.
- A nap follows the existing calendar-day nap ownership rule. A chosen main sleep anchors only the main physiological cycle; it must not mutate a nap back into generic `Sleep`.
- `dayPrimaryChoice` survives evidence/stage refresh and never overwrites an explicit nap classification.
- The prior presentation remains until the new revision is ready; no indefinite `Loading activity…` state.
- If two records genuinely conflict, show one review/conflict prompt. Do not auto-delete or double-count ring/recovery/daily hours.

### Required tests

- Seed the exact shape: short early episode plus later 9h12 main on the same civil date.
- Edit the short episode to nap while a stage backfill and Activity-day load are in flight.
- Assert the nap and main land on their correct days, Today ring reflects only the correct main authority, Activity reaches a terminal row set, and neither record is lost.
- Relaunch and assert identical ownership—no reversion from backfill.

## Checkpoint 4 (P1, only after 1–3): wire the existing relative skin signal honestly

The pure implementation already exists and is tested:

- `Atria/Atria/AtriaRelativeSkinSignal.swift`
- `Atria/AtriaTests/AtriaRelativeSkinSignalTests.swift`

Do not create an absolute Celsius/Fahrenheit decoder. Wire the existing raw-scale result to a separate experimental presentation authority:

```text
Relative skin signal
Higher / within / lower than your usual raw baseline
```

Contract:

- Same exact strap/layout/payload/offset/algorithm authority.
- Confirmed main-sleep samples only.
- Per-minute median → nightly median; 7 prior qualified nights minimum; maximum 30.
- If the archive is incomplete (as it is now), publish `.incompleteArchive`, not a number.
- If motion is absent, keep reduced confidence and never claim stillness.
- Show a raw directional delta/index only; no degree symbol, fever/recovery claim, cross-device comparison, widget/HealthKit/report export, or use in recovery/strain.
- Keep the validated `skinTemperatureDeviationCelsius` lane separate and unavailable.

The current physical card says `Skin temp -- · Decoder not verified`. A blocker-first relative card may replace that only when its provenance wording cannot be confused with temperature. Otherwise leave the existing card unchanged and report the blocker.

## Optional checkpoint 5 (P2): SWS-HRV wiring, motion authority only

The pure selector exists at `Atria/Atria/HRV.swift` around line 213 as `AtriaRecoveryHRVWindowSelection`, but production has no call site.

Only if checkpoints 1–4 are green:

- Route qualified saved RR windows through it when the stage set has complete `research-motion-v2-` provenance and passes integrity/motion validation.
- Never use `research-hr-estimate-v1-` stage segments to choose the HRV window; that would make one HR-derived estimate select another HR-derived biomarker circularly.
- Preserve the existing fallback and readiness gates (`kept >= 240`, ~5-minute window, RR gap ≤3s, confidence/successive-difference gates).
- Add a motion-authorized deep-window test, an HR-only-estimate fallback test, and a no-qualified-deep-window fallback test.

Do not make this optional work block checkpoints 1–4.

## HR-only stage calibration rule

Do not spend this pass hand-tuning stage percentages. If a tiny bounded change remains after P0 work, add only a typed estimate-quality receipt and copy such as `Low-confidence HR-only estimate` for degenerate outputs (for example no estimated awake time plus high transition churn). Do not suppress measured sleep hours, relabel the estimate as validated, or force WHOOP-like stage ratios.

## Focused validation

Use the `AtriaTests` scheme, one simulator worker, parallel testing off. Start with changed suites plus these adjacent contracts:

```text
AtriaSleepImmediateProjectionTests
AtriaSleepStageIntegrityTests
AtriaSleepStageFallbackPerformanceTests
AtriaSleepActivityConsistencyTests
AtriaSleepEstimateReconcileTests
AtriaWhoop4HistoryDrainStateTests
AtriaBLERecoveryCadenceTests
AtriaBackgroundDrainBacklogTests
AtriaBLEHistoricalRecoveryPolicyStructureTests
AtriaDailyStepPresentationTests
AtriaRelativeSkinSignalTests              # only if checkpoint 4 changes
AtriaHRVQualificationTests                # only if checkpoint 5 changes
```

Use a guarded temporary symlink to the canonical `<repo-root>/evidence` only for tests that require the gitignored evidence corpus. Hash a null-delimited evidence manifest before/after and remove the exact symlink with a trap. Do not modify evidence.

Then run changed-file Swift parse and `git diff --check`. Do not weaken tests to clear source-scan drift; update a structural assertion only when runtime semantics are independently covered.

## Short physical acceptance

Build/install the exact final commit in place, verify provenance and migrated data, then use Computer Use with iPhone Mirroring (`com.apple.ScreenContinuity`) yourself. Do not claim taps are blocked without retrying; coordinate clicks worked in this handoff.

Verify:

1. No second launch is needed after a stage backfill; the open Sleep detail and Today ring update once.
2. Activity HR and Stress reach terminal charts; marker band stays above the plot.
3. The edited nap/main records appear on their correct days immediately and after relaunch.
4. Trends remain honest: no unqualified HRV point and no line/fill over a data gap.
5. SpO₂ remains blank with the decoder blocker.
6. Strap steps remain frontier-led; record current time/frontier and the exact history-gap state.
7. Process remains stable for 5–10 minutes: no crash, jetsam, watchdog, reconnect storm, or live-HR regression.

### Optional motion attempt

Only while the user is wearing the connected >70% strap near the cabled iPhone: start one short Strength workout, move for 3–5 minutes, end it, and relaunch once. Record whether protected-R10/v24 motion frames advance and whether qualification becomes live. Do not repeatedly churn radio modes if one exact attempt fails; preserve the evidence and report the blocker.

## Commit / push / issues

- Author and committer: `adidshaft <adidshaft@gmail.com>`.
- No Claude/Codex/AI trailer.
- Commit only files from the clean continuation worktree.
- Push a clean fast-forward to `origin/dev`.
- Update existing issues with exact commit/test/device evidence:
  - #5 Activity terminal charts/marker band and nap-row closure.
  - #21 history-gap terminal state, step frontier, and optional motion attempt.
  - #25 same-launch stage publication, nap/main ownership, and estimate-quality truth.
  - #31 relative skin only if checkpoint 4 ships.
  - #33 exact installed-build stability/provenance.
  - #34 SpO₂ remains reference-blocked; relative skin authority if shipped.

Do not close #21 while the Aug-6 gap remains re-arming or motion remains unqualified. Do not close #25 until stage backfill is visible without relaunch and the edited nap/main day ownership is device-verified.

## Definition of done

Done means:

- launch backfill is visible in the same process exactly once;
- the zombie sequence-gap ticket is repaired or parked as a truthful terminal unavailable interval, not endlessly re-armed;
- nap/main edits update storage, ring, and Activity atomically with no loading loop;
- relative skin is either blocker-first and raw-relative only, or explicitly deferred with its exact archive blocker;
- focused tests pass; the installed exact build remains stable; six target surfaces are physically checked;
- one clean commit is pushed and issues are updated.

Anything beyond that is the next pass.
