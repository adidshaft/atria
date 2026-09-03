# Atria next handoff — exact checkpoints after `422add5`

Date: 2026-08-10

Repository: `/Users/amanpandey/projects/atria`

Branch: `dev`

Remote HEAD: `422add5c74558f9f97ba1862069372f53d761262`

Issue: [#33](https://github.com/adidshaft/atria/issues/33) — keep open

TestFlight: **not authorized**

## Current verdict

The Bluetooth/defaults deadlock fix is code-complete, focused-test green, clean-build/provenance bound, and proven in ordinary live HR plus saved-device CoreBluetooth restoration. Do not redesign those accepted paths.

The branch is **not fully product-complete yet**. The remaining work is:

1. correct one definite graph-truth defect (live Heart-rate connects observations across a multi-hour hole);
2. make sparse Stress/Trend/Sleep charts readable without fabricating measurements;
3. finish the normal motion-publication path so retained motion can feed the prior-cycle receipt, sleep-stage backfill, and saved-window HR/Stress evidence;
4. optionally seal one controlled central-rebuild physical proof, but only with explicit permission because it terminates/relaunches and backgrounds the app;
5. keep #33 open because TestFlight is still intentionally unperformed.

Use the status label **“BLE fix accepted; motion/UI truth completion pending.”**

## Already accepted — do not redo or weaken

- Git authorship cleanup and pushed parity at `422add5` (`0 0`).
- Defaults observer deadlock fix (`queue: nil`, synchronous main-thread keyed-write suppression, off-main MainActor hop, existing equality/5-second coalescing retained).
- Crash-consistent A/B central restore-slot ordering.
- Focused BLE/default tests: 492 passed, 0 failed.
- Exact signed clean build/provenance at `422add5`.
- Ordinary 420-second HR smoke: one PID, one namespace, dense 2A37 ingress, no watchdog/false-off/churn.
- Saved-device restoration: restored process reclaimed the persisted namespace, one session, dense GATT, no reap or HR-CCCD disable.
- Latest narrowed status is recorded in [issue comment 5240027444](https://github.com/adidshaft/atria/issues/33#issuecomment-5240027444).
- No TestFlight upload.

## Checkpoint 0 — preserve the user worktree

The main worktree intentionally contains 14 unrelated user-owned chart edits. Never stash, reset, checkout, stage, overwrite, or reformat them as a group:

```text
AtriaAboutMetricSheet.swift
AtriaActivityMonitor.swift
AtriaExpandedChart.swift
AtriaGraphInspector.swift
AtriaHealthspanDetailView.swift
AtriaOverviewSections.swift
AtriaSleepPlannerCharts.swift
AtriaStepsWeekChart.swift
AtriaStrainRecoveryComboChart.swift
AtriaTrendChart.swift
AtriaVitalsCollectionSections.swift
HRV.swift
HeartRate.swift
Insights.swift
```

Three files required by the visual work are in that list: `AtriaActivityMonitor.swift`, `AtriaTrendChart.swift`, and `AtriaVitalsCollectionSections.swift`. Implement their changes first in a clean detached worktree at `422add5`, commit only the intended hunks, then integrate those exact hunks while preserving the user's current diffs. Do not blanket-copy whole files back into the main worktree.

The two handoff documents are intentionally untracked. Do not stage them unless the user explicitly asks.

## Screenshot audit — what is actually wrong

| Screenshot | Classification | Finding |
|---|---|---|
| 1 — Live Stress | Presentation defect; gaps are honest | Blank runs are correct. The line is visually noisy and sleep/activity context is drawn as one narrow rectangle per minute, creating barcode stripes. Coalesce contiguous context intervals; never bridge a missing Stress fact. |
| 2 — Live Heart rate | **Graph-truth defect** | The chart draws a long diagonal from noon to late afternoon through a real telemetry hole. Empty smoothing buckets are discarded and the remaining marks share one series. The trailing y-axis is also clipped at the top/right edge. |
| 3 — Sleep detail | Data-authority gap, not permission to invent stages | The stage UI already supports Awake/Light/REM/SWS/Deep, but `displayStageSegments` is empty. HR alone cannot identify stages. Stages may appear only after qualified motion/recovered-session evidence passes integrity checks. The oversized unavailable card can be compacted. |
| 4 — Resting-HR Trend | Sparse-series rendering defect | “2d of data” can consist of two singleton segments separated by a missing day. Only the latest global point is marked, so the earlier singleton becomes invisible. |
| 5 — Strain Trend | Sparse-series presentation defect | Four real points rendered as a tall filled polygon exaggerate movement. Values may be correct; the chart grammar is wrong for a tiny sample. |
| 6 — HRV Trend | Sparse-series presentation defect | Three observations rendered as a filled V-shape overstate certainty. Use observed points first; reserve an area trend for enough contiguous days. |
| 7 — Saved-day Heart rate | Upstream history completeness + sparse-state defect | One observed point is honestly shown, but an 8-hour confirmed sleep should not look like a complete timeline. Rehydrate exact-window measured HR from canonical sessions/archive, or label the card “1 measured sample · incomplete.” |
| 8 — Saved-day Stress | Mostly honest gaps; upstream replay completeness | Segmented gaps are correct. Confirm whether retained Stress facts were replayed for the saved window; never connect the fragments or synthesize missing scores. |

## Checkpoint 1 — fix live Heart-rate gap truth first (release essential)

Primary source:

- `Atria/Atria/AtriaVitalsCollectionSections.swift`
  - `AtriaHeartRateChartSeries.smoothedBuckets`
  - `AtriaHeartRateAxisChart`
  - `AtriaHeartRateTimelineCard`

Root cause:

- `smoothedBuckets` creates time buckets but `compactMap` removes empty buckets;
- `AtriaHeartRateAxisChart` then draws all surviving buckets/points as one LineMark/AreaMark series;
- Swift Charts connects the observations on either side of the empty span.

Required implementation:

1. Give every raw point and display bucket a stable run/segment ID.
2. Start a new segment at a material HR gap (use the existing Activity timeline's 2-minute honesty threshold or a single shared policy; do not invent a new permissive multi-hour threshold).
3. Preserve empty bucket boundaries instead of letting compaction merge the observations on either side.
4. Pass the segment as Swift Charts' `series` value for both line and fill.
5. Draw a PointMark for each singleton segment so real isolated readings remain visible.
6. Keep selection/nearest-point behavior limited to real points.
7. Add a real trailing-axis gutter (or stop the right-side negative bleed) so the top/right y-axis labels are never clipped.

Must-pass tests in `AtriaHeartRateTimelineWindowTests`:

- dense points before and after a multi-hour hole produce two segments;
- smoothed buckets do not connect across an empty interval;
- a singleton run remains visible by policy;
- downsampling preserves the gap boundary and first/last real observations;
- no synthetic point or timestamp is introduced;
- source structure includes a segment series for both raw and bucket paths.

Physical/UI acceptance:

- reproduce screenshot 2's time span;
- the noon-to-afternoon hole is blank, not a diagonal;
- current/average/peak/resting numbers remain unchanged;
- 120/top y-axis text is fully visible.

## Checkpoint 2 — calm the Stress card without falsifying it

Primary source:

- `Atria/Atria/AtriaVitalsCollectionSections.swift`
  - `AtriaVitalsStressTimelineChart`
- `Atria/Atria/AtriaStressDetailView.swift`
  - `AtriaStressTimelinePoint.segment`

The current Stress gap segmentation is correct. Preserve it.

Required implementation:

1. Convert consecutive `.asleep` minute facts into bounded sleep intervals before rendering context.
2. Convert consecutive qualified `.activity` minute facts into bounded activity intervals.
3. End an interval on a missing fact, unqualified context, context-kind change, or continuity-gap break.
4. Draw one background RectangleMark per interval, not one per minute.
5. Keep the measured Stress trace segmented at `maximumFactContinuityGap`.
6. If further smoothing is desired, use a documented observed 5-minute display bucket inside each continuous run only. Never smooth across a gap and never replace the inspectable raw fact.
7. Keep HR-only confidence and “gaps remain blank” copy visible.

Tests:

- `AtriaVitalsProjectionStoreTests`: contiguous context coalesces; gaps and unqualified facts split; Stress run IDs are unchanged.
- `AtriaStressDetailViewTests`: no cross-gap line and no fabricated sleep/activity overlay.

Acceptance:

- screenshot 1 no longer looks like a barcode;
- every blank run stays blank;
- measured scores and current `0–3` reading do not change.

## Checkpoint 3 — make sleep distribution data-driven, never fabricated

Primary sources:

- `Atria/Atria/AtriaHealthScreen.swift`
  - `sleepDetailCard`
  - `AtriaSleepStressArchiveProjection`
- `Atria/Atria/AtriaVitalsCollectionSections.swift`
  - `AtriaSleepStageSummary`
  - `AtriaSleepStageBuildingSummary`
- `Atria/Atria/Sessions.swift`
  - `rebuildConfirmedSleepRecoveredMotionProvenance`
  - `backfillConfirmedSleepStagesFromSessions`
  - `sleepStageResearchSegments`

Important truth rule: the app already has the REM/Deep/SWS/Light/Awake UI. It is absent because this night has no qualified `displayStageSegments`. Do **not** manufacture stages from clock time, aggregate HR, an 8-hour duration, or a confirmed flag.

Required sequence:

1. Allow one normal app-owned motion offload/compact checkpoint to finish.
2. Materialize the recovered motion epochs into canonical sessions.
3. Rebuild the confirmed sleep's recovered-motion provenance.
4. Run the existing stage backfill for the exact sleep window.
5. Publish stages only when coverage/integrity validates and the motion authority is qualified.
6. If the legacy night truly has no recoverable motion, retain the honest unavailable state. Make it compact and say exactly what remains available (duration/RHR/HRV/respiration), but do not draw a fake distribution.

Must-pass tests:

- `AtriaSleepStageIntegrityTests`
- `AtriaSleepHypnogramPresentationTests`
- `AtriaSleepAuditRegressionTests`
- recovered motion covering a confirmed night produces a persisted, relaunch-stable stage distribution;
- an HR-only/manual/partial-motion night produces no REM/Deep/SWS segments;
- stage durations never exceed the observed sleep duration and awake gaps are not credited as sleep.

Acceptance:

- with qualified motion: stage rail + numeric distribution appears and survives relaunch;
- without qualified motion: honest compact unavailable state, no colored zero bars and no inferred stages.

## Checkpoint 4 — restore exact-window HR and Stress for saved sleep/day cards

Primary sources:

- `Atria/Atria/AtriaActivityMonitor.swift`
  - `readTimelineHeartRate`
  - `AtriaActivityTimelineSignalProjection`
  - `heartRateTimelineChart` / `stressTimelineChart`
- `Atria/Atria/AtriaHealthScreen.swift`
  - `AtriaSleepStressArchiveProjection.load`

Required implementation/audit:

1. Fix the current Activity HR consumer first. `AtriaStressMonitorStore.heartRateHistory` already retains the real HR used by successful minute facts, but `readTimelineHeartRate` currently ignores it and relies on resident sessions + recent archive + a live tail. The tail only appends on BPM change and can stay at one point during a stable live feed. Capture `heartRateHistory` with `historyRevision`, merge its exact observed timestamps/BPM into the current physiological window, and deduplicate it with the other sources.
2. Build one shared exact-window measured-HR projection from:
   - overlapping canonical `SavedSession.points`; and
   - exact `HistoricalArchive.metricHeartRatePoints` rows.
3. Deduplicate identical observations and preserve source timestamps.
4. Keep gaps segmented; no interpolation across missing archive coverage.
5. Use the shared projection for both saved-day Heart rate and Overnight HR load so the two screens cannot disagree about the same sleep window.
6. If only one/few samples exist after a successful read, show the points plus explicit measured count/coverage (“1 measured sample · incomplete”), not a timeline that appears complete.
7. Distinguish unreadable archive, readable-but-insufficient wear, and still-loading history. Screenshot 3's exact `.unavailable` state means the exact-window archive read returned nil; it is not the same as a successful empty/insufficient-wear read. Preserve that distinction and add enough diagnostic provenance to identify missing descriptor, incomplete scan, or overflow.
8. Trigger a refresh when canonical history/compact materialization or Stress `historyRevision` publishes; a saved/current day must not remain permanently stuck on its first sparse read.
9. Stress history remains limited by its real retention window. Outside retention, say so; never rebuild fake scores from HR under the label “Stress.”

Tests:

- `AtriaActivitySectionsCacheTests`: canonical + archive + observed `heartRateHistory` union, dedupe, exact-window bounds, singleton state, refresh after history authority changes. With an empty archive and six observed Stress-HR minutes, Activity HR must show more than one exact real point.
- archive-unavailable and insufficient-wear states remain distinct.
- a multi-hour HR gap and every Stress gap remain separate segments.

Acceptance:

- screenshot 7 either gains the real measured overnight runs or clearly says the evidence is incomplete;
- screenshot 8 retains real gaps and gains only facts that genuinely exist;
- screenshot 3's Overnight HR card uses the same exact-window evidence.

## Checkpoint 5 — use a sparse-series grammar for Trends

Primary source:

- `Atria/Atria/AtriaTrendChart.swift`
  - `AtriaTrendChartCard.coreChart`
  - `AtriaTrendGapPolicy`

This file has user-owned dirty chart hunks. Work in isolation and integrate only narrow hunks.

Required policy:

- 0 observations: compact honest empty state.
- 1 observation: one PointMark + value/date; no line or area.
- 2–4 observations: PointMark for **every** observed day; optional thin line only inside a contiguous segment; no AreaMark.
- 5+ observations: line is allowed inside each segment; area fill only when the sample count/coverage threshold is explicitly met.
- every singleton segment gets a PointMark, not only `prepared.series.last`.
- missing civil days remain separate segments under `AtriaTrendGapPolicy`.
- shrink sparse/empty chart height so two data points do not occupy a 210-point card.
- keep the `Nd of data` subtitle metric-specific and equal to the visible observed-point count.

Tests in `AtriaTrendProjectionStoreTests`:

- two observations separated by a missing day render two visible singleton points;
- 1/2/3/4-point policies contain no area fill;
- 5+ contiguous points may use the full trend grammar;
- missing days never share a series ID;
- sparse card count and accessibility copy equal visible observations.

Acceptance:

- screenshots 4–6 read as sparse evidence, not dramatic filled mountains;
- all real points remain visible;
- no missing day is connected.

## Checkpoint 6 — physical motion/receipt proof (release essential for motion completeness)

The retained immediately-prior receipt is still unproven because the accepted smoke was standard-HR-only and no motion compact publication occurred.

Do not key this check to `array[0]` or only to the older receipt hash. The physiological boundary has moved. At the latest read-only audit, the exact immediately-prior target was:

```text
windowStart: 808030481.691886
windowEnd:   808035902.041524
local time:  2026-08-10 10:24:41–11:55:02 IST
baseline exact-window receipt: absent
eligible closed/pending coverage intervals: 7
relevant compact bucket: 20675
```

Procedure:

1. Capture the exact current/immediately-prior cycle plan, receipt array, compact bucket size/hash, decoded coverage ledger, FIFO owner, PID, and frontier. Recompute the target from the current confirmed-sleep authority; do not assume the numeric window above is still current.
2. Wait until history/live restoration is fully released and the all-day motion bank has been factually armed for at least 10 minutes. Do not send ad hoc BLE writes or allow `0x69` while history FIFO owns transport.
3. Use the one normal app-owned “drain on glance” edge: background then foreground Atria exactly once. `handleInteractiveForeground` must give the qualified motion bank first refusal. Do not use cadence/coexistence debug flags.
4. Require exactly one log chain:
   - `workout_motion_bank status=glance_checkpoint_due ... action=async_close_and_offload`;
   - `status=stopped cmd=6900 ... action=async_offload`;
   - one `workout_motion_bank_offload status=started|cutover_pending ... reason=workout_motion_bank_glance_checkpoint_scene_active`;
   - `historyCheckpoint status=durable`;
   - terminal `motion_bank_compact_offload` with live restored;
   - `whoop4_daily_steps status=receipt_refresh_complete ... window=immediately_prior changed=1`.
5. Prove bucket `20675` (or the newly resolved target bucket) appended durably: size/hash advance while the old byte prefix remains identical.
6. Query the receipt by exact `windowStart` + `windowEnd` + strap identity. For a new row require `capturedThrough > windowStart`; for an existing row require strict strengthening. `decodedRows` and `knownCoverageSeconds` must not decrease, and `missingCoverageSeconds` must not increase. Steps can legitimately move either direction as coverage is re-evaluated.
7. Stop after the one terminal offload. Do not foreground again and do not drain every pending ticket merely to obtain a pass.
8. Motion completion may make sleep/session recovery **eligible**, but it is not automatic proof. If relevant raw HR/RR was recovered, separately require `recovered_projection status=applied`, persisted recovered-current-cycle output, and fail-closed `sleep_stage_backfill ... status=updated` before calling stages/overnight traces fixed. Compact-only motion finalization intentionally does not mint all five full-drain consumer receipts.
9. If no eligible compact append occurs, report **NOT EXERCISED**, not PASS. If compact evidence advances but the exact prior receipt does not, capture the candidate/save decision and stop before editing.

Abort without retry on PID/watchdog change, a second glance/offload, power-pressure park, deferred stop, compact flush failure, receipt-save failure, or a terminal offload that appended no relevant evidence.

## Checkpoint 7 — central rebuild proof (optional until explicitly authorized)

Saved-device restoration is already proven. Natural `repair_central_rebuild` trails exist on the installed `422add5`, followed by powered-on/connect/fresh-HR and no new crash report, but the evidence set does not bind every transition to an exact same-PID monitor row. Treat that as strong supporting evidence, not a reason to force device state silently.

If the user explicitly authorizes the controlled proof:

1. Launch the exact installed build with the existing one-shot:

```text
--atria-force-hr-continuity-watchdog-after 120
```

2. Confirm live `standardHR` first, then background Atria before the deadline; the foreground path normally only observes/rediscoveries.
3. Require exactly one `post_connect_repair=action_central_rebuild`, one restore-slot flip, same PID survival, replacement central/session, and raw==accepted recovery for at least 60 seconds.
4. Stop on wrong watchdog action, PID turnover/watchdog, no replacement within ~10 seconds, duplicate/reaped namespace, more than one rebuild, false-off, or HR not resuming.
5. Avoid the wrapper's `--console` stop path because SIGINT is forwarded to the app.

Do not repeat the already-green restoration smoke unless the product acceptance definition explicitly requires rebuild-then-restoration in one sequence.

## Checkpoint 8 — focused validation and visual fixtures

Run serially, one simulator worker:

```text
AtriaHeartRateTimelineWindowTests
AtriaVitalsProjectionStoreTests
AtriaStressDetailViewTests
AtriaActivitySectionsCacheTests
AtriaTrendProjectionStoreTests
AtriaSleepHypnogramPresentationTests
AtriaSleepStageIntegrityTests
AtriaSleepAuditRegressionTests
AtriaWhoop4MotionTickDailyStoreTests
```

Also require:

- production/test files parse;
- `git diff --check` clean;
- app target build succeeds from the isolated candidate tree;
- visual fixtures for live HR with a multi-hour gap, Stress with context spans, 1/2/4-point Trends, sleep with qualified stages, and sleep with honest unavailable stages;
- no test changes that merely loosen source assertions without preserving semantics.

## Checkpoint 9 — commit/push/issue hygiene

1. Stage only the intended isolated hunks and tests; keep all unrelated user chart edits untouched.
2. Author and committer must be `adidshaft <adidshaft@gmail.com>` with no Codex/Claude/co-author trailer.
3. Push `dev` and require upstream parity `0 0`.
4. Update issue #33 with:
   - exact new SHA/provenance;
   - HR gap-truth and sparse UI evidence;
   - motion receipt/stage result as PASS or NOT EXERCISED;
   - central rebuild as PASS/supporting-only/pending permission;
   - explicit “no TestFlight.”
5. Keep #33 open until its TestFlight acceptance is performed or the user revises the issue's acceptance text.

## Hard stop conditions

Stop and report evidence before further edits if any of these occurs:

- a graph connects across a known telemetry gap;
- REM/Deep/SWS is produced without qualified motion/stage evidence;
- raw/accepted HR freezes or diverges;
- watchdog/PID turnover, duplicate CoreBluetooth namespaces, session reap, false Bluetooth-off, or churn returns;
- eligible prior-cycle compact evidence advances but the receipt does not;
- integrating a fix would overwrite any of the 14 user-owned dirty files;
- TestFlight, Bluetooth toggling, forget/re-pair, or process termination would be required without explicit user authorization.

## Compact prompt for Claude

> Read `docs/CLAUDE_FINAL_ACCEPTANCE_CHECKLIST.md` completely. Start from clean commit `422add5`; preserve the 14 dirty user chart files by implementing overlapping UI changes in an isolated worktree and integrating only narrow hunks. Fix live HR gap bridging first. Then coalesce Stress context spans, add a truthful sparse-series Trend grammar, and make saved sleep/day HR and Stress refresh from exact measured canonical/archive evidence. REM/Deep/SWS may appear only from qualified motion evidence that passes the existing integrity gate. Run the listed focused suites and visual fixtures. Exercise the normal motion compact-publication/receipt path without ad hoc BLE commands. Do not force a central rebuild, terminate the app, toggle Bluetooth, forget/re-pair, upload TestFlight, or close issue #33 without explicit authorization.
