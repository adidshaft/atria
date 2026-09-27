# Code review and optimisation pass — 2026-09-24

Scope: the whole app target (`Atria/Atria`, `AtriaShared`, `AtriaWidget`,
about 330k lines of Swift), reviewed at `dev` 37c88354. That commit (native
R10 step ingest and the R10 live controller) is reviewed separately in §4.

Hands-off files were reviewed but not edited. They are
`AtriaBLEManager.swift` and the other BLE transport files,
`AtriaStrapSetup.swift`, `AtriaOnboarding*.swift`, `AtriaWidget/*`,
`AtriaGlanceSettings*` and `AtriaLiveActivityCoordinator.swift`.

Findings are grouped as correctness, then performance and battery, then
maintainability. Inside each group they run from most to least impact.
**Fixed** means the fix is on this branch. **Left** means the finding is
reported only, with the reason. Line numbers refer to this branch after the
fixes.

How the findings were gathered:

- **Scanners.** Scripted scans looked for unreferenced types and unreferenced
  private members. Each dead-code candidate was then checked against
  `test_handoff_static_checks.py` and the Swift source-scan tests before it
  was deleted.
- **Targeted greps.** These covered formatter allocation, fixed 86,400-second
  day arithmetic, `uniqueKeysWithValues`, timers, polling loops and
  `ForEach` identity.
- **Hot paths read by hand.** These were the Home model's publisher fan-out,
  Today glance tiles, the diagnosis report, the HR tail facade and the
  civil-day step authority.

---

## 1. Correctness

### C1. Civil-day step totals assumed a 24-hour day — **Fixed**
`AtriaCivilDayStepAuthority.swift:181` (it used to read
`let dayEnd = day.addingTimeInterval(86_400)`).

- **Problem.** `day` is a local midnight, so the day really ends at the next
  local midnight. Where clocks change, the spring-forward day is 23 h long.
  There the fixed end read the first hour of the next day into the day's
  steps, so that hour was counted twice across the two days. The fall-back
  day is 25 h long, and its last hour belonged to no day at all.
- **Fix.** A new helper, `civilDayEnd(after:calendar:)` at line 135, uses
  `calendar.date(byAdding: .day, value: 1, to:)`. The read window, the
  shard fingerprint and the exclusion fingerprint now share that end. In a
  zone without clock changes (the owner's IST), the result is
  byte-identical.
- **Test.** `testCivilDayEndFollowsLocalMidnightAcrossClockChanges` checks
  23 h, 25 h and IST 24 h.

### C2. Trend windows counted seconds, not days — **Fixed**
`AtriaTrendChart.swift:1819` (`cutoffDate`), plus the prior-period cutoffs
at lines 333 and 411.

- **Problem.** `startOfDay(now - days × 86,400)` is off by an hour when a
  clock change falls inside the window. Just after midnight, that picks the
  wrong start day. At 00:30 on the Monday after spring-forward, "Week"
  opened 8 days back. The prior-period cutoffs had the same one-hour error.
- **Fix.** Both now use calendar-day arithmetic, through the new
  `priorPeriodCutoff(before:)`. Output is unchanged outside clock-change
  weeks.
- **Test.** `testTrailingWindowCountsCalendarDaysAcrossAClockChange`.

### C3. `dailyRollupHistoryRevision` missed three reassignments — **Fixed**
`Sessions.swift:10224`.

- **Problem.** The revision is documented as bumped every time the history
  is reassigned, and Today's glance memos and the metric sheets key on it.
  Three paths reassigned the history without bumping it: the App Review
  demo seed, and both "delete all data" resets (around `Sessions.swift`
  30130 and 30190). After a reset, revision-keyed memos could keep serving
  the deleted rollups until some later write bumped the revision.
- **Fix.** The bump now lives in the property's `didSet`, placed last so
  the order of effects matches the old hand-placed bumps (and the didSet
  pin in `AtriaLearnedInsightsTests` still holds). The 8 hand-placed bumps
  were removed. Consumers compare the
  revision for equality only, so the extra bumps from `didSet` cannot hide a
  change.

### C4. Day-keyed `Dictionary(uniqueKeysWithValues:)` traps on duplicate days — **Fixed at 4 sites, 39 left for audit**

- **Problem.** `uniqueKeysWithValues` crashes the process when two elements
  share a key.
  - `Sessions.swift` already merges rollups with
    `uniquingKeysWith: { _, last in last }` (around line 9992) because
    duplicate days do occur.
  - The backup-import path carries a comment recording that this exact trap
    was once reached.
- **Fixed sites.** These now use last-wins, matching the existing merge:
  - `AtriaCivilDayStepAuthority.load(from:)`. Its own header promises "a bad
    file is an empty cache, never a throw", yet a repeated day in the
    persisted JSON crashed the app.
  - `Sessions.swift` trend summaries (two sites, `rollupsByDay`).
  - `Sessions.swift` `mergeCanonicalHistoricalRollups` (`byDay`).
- **Left.** 39 other sites, mostly keyed on in-process identifiers (chunk
  IDs, receipt IDs, enum cases). Each one is safe only if its input is unique
  by construction. A follow-up should sweep the ones fed by decoded files,
  such as the checkpoint sources around `Sessions.swift:15894` and 16145.

### C5. Features regressed out of the UI, while their code and pins stayed — **Left (owner decision)**
All of these compile, and none are mounted anywhere:

- **Strength logger surfaces.** `AtriaStrengthCatalogView`,
  `AtriaStrengthProgressView`, `AtriaStrengthRestHeartRateHost` and
  `AtriaStrengthSetTable`. They were unmounted on purpose by beaaa0ac
  (2026-09-07, "simplify gym set logging"), but the files stayed behind and
  `test_cd12_strength_log_foundation_and_pause_fields_exist` still pins the
  old call sites. That pin now fails.
- **Insights cards.** `AtriaInsightsCardHost` and `AtriaInsightsCard` in
  `AtriaOverviewSections.swift` around line 10257. A static check uses
  `struct AtriaInsightsCardHost` as a slicing anchor, so deleting it would
  break an unrelated test.
- **Impact map.** `AtriaBehaviorImpactMapRow`, whose card
  (`AtriaBehaviorImpactMapCard`) no longer exists. The two
  `BehaviorImpactDesignParityTests` pins fail.
- **Memo class.** `AtriaHealthMonitorPreparedMemo` in
  `AtriaVitalsCollectionSections.swift`.
- **Sleep debt chart.** `AtriaSleepDebtChartCard` (7-night need-vs-slept,
  `AtriaSleepPlannerCharts.swift:476`) is mounted nowhere, but
  `AtriaSleepPlannerChartsTests.testHoursVsNeedChartBindsTheAxisToTheSlotWindow`
  source-scans its body. A first pass on this branch deleted it; the full
  suite caught the pin, and the card was restored.
- **Workout-review subviews.** Twelve uncalled but pinned subviews in the
  workout-review sheet in `AtriaHomeView.swift`: `reviewPathStrip`,
  `workoutReceiptBoard`, `captureEvidenceStrip`, `reviewDecisionLens`,
  `stepIndicator`, `stepContextRail`, `suggestedTypeRunway`,
  `selectedTypeLens`, `exerciseSearchPrompt`, `exerciseCatalogPreview`,
  `summaryReceiptLens` and `makeDisconnectedHeroSnapshot`.
- **Overview members.** Seven uncalled but pinned members in
  `AtriaOverviewSections.swift`: `glanceCompactRow`, `durationProgress`, the
  glance-size helpers, `rangeLens` and `supportsGlanceTargetEditing`.

For each one the owner has two options: mount it again, or delete it and
retire its pin with a dated note. I deleted none of these, because deleting
means removing or rewriting pins, which the brief rules out.

### C6. Workout-prompt start time ignores the 24-hour setting — **Left (minor)**
`AtriaHomeView.swift:296`.

- **Problem.** The formatter uses a fixed `dateFormat = "h:mm a"` with no
  template, so users with a 24-hour setting see "2:05 PM". The start time
  also assumes one sample per second
  (`Date().addingTimeInterval(-Double(samples))`), and the copy already
  marks it as approximate with "≈".
- **Fix.** `setLocalizedDateFormatFromTemplate("jmm")`. Not applied, because
  it is a visible copy change.

---

## 2. Performance and battery

### P1. The diagnosis report is rebuilt about once a second in foreground and background — **Partly fixed**
`AtriaHomeView.swift:12449` (`publishDiagnosisReport`). It is called from the
400 ms-throttled CoreLive merge at line 12000, which `sessionSampleCount`
ticks at 1 Hz while the strap is connected, including in the background.

- **Problem.** Each call used to build 8 `DateFormatter`s and scan the whole
  rollup history 8 times for the overnight Week and Month windows. The file
  write itself is coalesced to 5 s, but building the snapshot is not.
- **Fixed.**
  - The windows are memoized on the rollup revision, the civil day and the
    time zone (`diagnosisMetricWindows(rollups:now:)`). They are pure in
    those inputs, and C3 makes the revision trustworthy.
  - `AtriaDiagnosisReport.overnightMetricWindows` now builds one formatter
    per call instead of eight.
- **Left.** Each tick still does the following work:
  - It JSON-decodes the published widget snapshot from app-group defaults,
    creating a new `UserDefaults(suiteName:)` every time
    (`AtriaAppIntents.swift:350`).
  - It computes `AtriaPhysiologicalCycle.current` twice.
  - It sorts `confirmedWorkouts`.
  - It calls `ble.retireStuckIdleWindowLeftoverIfNeeded`, which reads
    defaults.

  The right fix is to skip building the snapshot inside the 5 s coalesce
  window. That was not applied, for two reasons. The writer bypasses
  coalescing when discrepancies change, so skipping the build would delay
  discrepancy events. And the idle-window retire side effect deliberately
  rides this loop ("diagnosis is the loop that still runs"). Both need the
  owner's call.

### P2. Every `HRSample` minted a random UUID that nothing read — **Fixed**
`HeartRate.swift:10`.

- **Problem.** `struct HRSample: Identifiable { let id = UUID() ... }`. The
  `id` was never read and no generic code needs `Identifiable`: the target
  compiles with both removed. Yet the property generated a random UUID for
  every live sample (`AtriaBLEManager.session`, a full day at 1 Hz) and for
  every element of every projected session (`Sessions.swift` maps tens of
  thousands of points per projection). It also doubled the element size,
  from 16 to 32 bytes.
- **Fix.** The property and the conformance are removed.

### P3. Today's glance tiles re-sorted the rollup history for every tile, on every body evaluation — **Fixed**
`AtriaTodayScreen.swift:2676` (`glanceTrend(for:)`).

- **Problem.** Each glance card called
  `dailyRollupHistory.sorted { $0.day < $1.day }.suffix(21)`, so a
  14-card deck did 14 sorts per render.
- **Fix.** `glanceTrendHistory` (line 2722) memoizes the ascending 21-day
  slice on `dailyRollupHistoryRevision`, using the same `glanceMemo`
  pattern as the file's other memos.

### P4. A 400 ms foreground poll runs for the whole session in Release — **Left**
`AtriaHomeView.swift:1203–1213`.

- **Problem.** While the scene is active, a loop wakes every 400 ms. Each
  tick runs `drainPendingFileDeepLink()` and
  `applyOvernightHRVRestoreReceiptsIfNeeded`, which check two drop files
  (`AtriaPendingDeepLinkFile`, `AtriaOvernightHRVRestoreFile` in
  `AtriaOverviewSections.swift` around line 3933). That costs two
  `FileManager.urls` lookups, two `fileExists` checks and a Task resume, 2.5
  times a second. The drop files are devicectl tooling, and on a normal
  user's phone they never exist.
- **Fix options.** Watch the Documents directory with a
  `DispatchSource.makeFileSystemObjectSource`, poll every 2–5 s, or gate
  the loop to developer mode.
- **Why left.** It is the owner's live device-debug channel, used on
  Release builds, so changing its latency changes that workflow.

### P5. The live-presentation watchdog keeps ticking in the background — **Left (small)**
`AtriaHomeView.swift:11867`.

- **Problem.** A repeating 5 s `Timer` on the main run loop does nothing
  unless `applicationState == .active`. BLE background mode keeps the run
  loop alive, so the timer fires about 17,000 times a day in the background
  for nothing.
- **Fix.** Invalidate the timer on `didEnterBackground` and restart it on
  `didBecomeActive`. Not applied, because the watchdog exists to repair
  missed activation edges, and it needs device proof that a restart driven
  by an edge cannot itself miss.

### P6. `AtriaSyncProgressFooter` rebuilds its timer on every parent re-init — **Left (small)**
`AtriaHomeView.swift:7188`.

- **Problem.** `Timer.publish(every: 5 …).autoconnect()` is stored as an
  instance `let` on the View. Each time the parent re-initialises the view,
  a new publisher is created and `onReceive` resubscribes. That resets the
  5 s cadence, the same bug class the file already documents for its merged
  side-effect publishers. The `footer` property is also evaluated twice per
  body, with three defaults reads and two `DateFormatter` allocations in
  `syncedThroughText` (lines 6991 and 7007).
- **Fix.** `TimelineView(.periodic(from:by: 5))`, plus a single `footer`
  read.

### P7. Formatters are allocated on each call in render paths — **Left (low)**
- `AtriaTrendChart.periodLabel` runs every time the metric-detail header
  renders.
- `AtriaLearnedInsights` allocates in `ledgerRows` and in the day snapshot.
- `AtriaHomeView` allocates in `syncedThroughText`.

Each allocation is cheap on its own. None is in a loop that is large enough
to matter today.

### P8. The HR tail facade can still read whole file tails — **Left (guarded by usage)**
`HistoricalArchive.loadRecentHeartRateSamples(since:limit:)`.

- **Problem.** When the window holds fewer than `limit` rows, the loop walks
  every recent file's tail, up to 96 MB each, and parses each line with
  `JSONSerialization`. This is the same trap as in
  `atria-hr-tail-facade-cpu-trap`.
- **Current reach.** The facade is now called only as a fallback in
  `AtriaVitalsCollectionSections.swift:1409`, after the exact-window read
  fails, and from DEBUG fixtures.
- **Suggestion.** Add an assertion or a log whenever `limit` exceeds 12k.

### Checked and clean
- **Store observation.** Observation is already split into narrow stores
  (`HeroPulseStore`, `CoreLiveStore`, `StatusStore` and others). No screen
  observes `AtriaBLEManager` directly, except `AtriaStepCalibrationPlan` and
  onboarding.
- **Publisher throttling.** The BLE publisher fan-out in `AtriaHomeModel.bind()`
  is throttled per lane (400, 650, 1,200, 1,500 and 2,000 ms).
- **Memoization.** Today already memoizes its expensive derivations on
  revisions.
- **Perpetual animations.** Every `repeatForever` animation respects Reduce
  Motion. `AtriaSkeletonBlock` pulses only while a loading placeholder is
  mounted.
- **`ForEach` identity.** Every `ForEach(..., id: \.self)` iterates constants,
  enum cases or unique strings. None has duplicate-prone numeric data.
- **`GeometryReader`.** The 59 uses draw bars and rails. None of them
  feeds layout back through preferences.

---

## 3. Maintainability

### M1. Dead code — **Fixed (about 540 lines removed)**
Everything below had zero references in the app, the widget and the tests,
and no pin in `test_handoff_static_checks.py`. The removal set was re-scanned
until it reached a fixed point.

- **Unreferenced types**
  - `AtriaHeroMetricItem`
  - `MonthlyReportStore`
  - `AtriaLoadingPanel`
  - `AtriaChecklistBadgeBackground`
  - `AtriaHealthMonitorRangeStat`
  - `AtriaHistoricalGravity`
- **Unreferenced private members**
  - `AtriaActivityMonitor`: `hasWorkoutStressEvidence`,
    `completedWorkoutStepsText`
  - `AtriaHistoricalArchiveDurableStore.upsertLiveIdentityLookupBestEffort`
  - `AtriaHomeView`: `missedDataDurationText`, `catchUpProgress`
  - `AtriaJournalInsights.pearson`
  - `AtriaTodayScreen.healthValue`
  - `AtriaTrendChart.reportBar`
  - `AtriaWhoop4HistoryAdmissionLedger`: `scalarInt64`, `prefixSnapshot`
  - `AtriaWhoop4HistoryArchivePipeline`: `u32le`, `u16le`
  - `HistoricalArchive`: `writeRotationManifest`, `stddev`, `mean`,
    `percentile`, `documentsRelativePath`
  - `Sessions`: `checkpointPersistenceDelay`, `refreshBackupStatusCache`,
    `workoutOverlapRatio`, `sessionTrimmedAtWakePoint`,
    `windowOverlapsSleepCore`, `verifySessionBackup` and its five
    `total*` counters, `trendAnomalies`, `trendSummaryBlockers`,
    `iCloudSessionBackupDirectory`
  - `Sessions`: the two non-deadline wrappers `sustainedElevatedEvidence`
    and `sustainedEvidence`. The first held the file's only `try!`.

### M2. Two copies of the same rule — **Fixed by deleting the dead copy**
- **iCloud mirror.** `SessionStore.mirrorSessionBackupToICloudIfEnabled`
  (instance method, uncalled) duplicated the live
  `static mirrorToICloud` (`Sessions.swift` around line 6958), and the two
  had already drifted. The dead copy re-read the toggle itself, while the
  live path takes it from `SessionBackupWriteRequest.mirrorsToICloud`. A
  later edit to the dead copy would have silently done nothing.
- **Outlier test.** `isHighOutlier` (instance) duplicated
  `isHighOutlierSnapshot` (nonisolated static). Only the static one had
  callers.

### M3. The static-check gate no longer gates — **Left (needs a triage pass)**
- **State.** `python3 test_handoff_static_checks.py` shows 77 of 189
  failing on `dev`. This branch neither adds nor removes a failure; the set
  is identical before and after.
- **Cause.** Many failures pin features that were removed on purpose (C5).
  Others pin lines that later refactors moved. A gate with 40% red cannot
  catch a new regression.
- **Recommendation.** One dedicated pass: migrate each failing pin, or
  retire it with a dated note. After that, treat the gate as zero-failure
  again.

### M4. Production types reached only from tests — **Left**
- **Types.** `AtriaFIFOBuffer`, `LatestRollupCache`,
  `AtriaHistoricalLongTermStore`, `AtriaWhoop4FusedStepEstimator`,
  `AtriaWhoop4LiveFlushPlanner`, `AtriaNightBaseline`,
  `AtriaRecoveryHRVWindowSelection`, `TachogramChart`,
  `AtriaSleepStageCompactStrip`, `AtriaCollectionToggleCard`,
  `AtriaSleepDebtChartPresentation` and the `AtriaOverview*Presentation`
  enums.
- **Why it matters.** The tests are green while testing nothing that ships.
  This is the same trap as the deleted Vitals tree.
- **Options.** Wire each type, or move it and its tests out together.

### M5. Dead code inside hands-off files — **Left (reported to their owners)**
- **`AtriaBLEManager.swift`.** 17 uncalled private members, including:
  - the four debug watchdog wrappers `scheduleNoDataWatchdogIfNeeded`,
    `scheduleHRContinuityWatchdogIfNeeded`,
    `scheduleRRPresenceWatchdogIfNeeded` and
    `scheduleAcceptedHRWatchdogIfNeeded` (the `scheduleDebug*` bodies are
    live);
  - `persistFinishedSession`, `refreshHRVSnapshot`,
    `rebuildSessionHeartRateStats`, `parseRealtimeProprietaryPacket`,
    `beginFreshHistoryOwnerCutover`,
    `bindExactHistoricalRequestAuthorityIfAvailable` and
    `savedPeripheralForStandingConnect`;
  - the unreferenced `PendingHistoricalTransportEvent` enum.
- **`AtriaWidget.swift`.** 16 uncalled private members, for example
  `smallMetricSummary`, `flatMetricRow`, `liveActivityCaloriesText` and
  `elapsedText`.

### M6. The fixture-argument parser is copied 42 times — **Left**
The `firstIndex(of: "--atria-ui-fixture")` / next-index / compare dance
appears 42 times across 16 files. A single helper,
`AtriaLaunchArguments.value(after:)`, would remove about 200 lines. It is
DEBUG-only code, so the value is low and pins reference several copies.

---

## 4. Review of 37c88354 (native R10 step ingest and the R10 live controller)

The pure `r10LiveCommand` rule is clear and well tested. The findings below
are for the BLE owner. None of them was edited here.

1. **R10 frames now masquerade as compact 0x33 frames.**
   - **What happens.** `ingestLiveMotionFrame` schedules
     `noteLiveIMULiveness` (`AtriaBLEManager.swift` around line 43768) for
     every frame. That function sets `strapStream5NotifyConfirmed = true`
     and calls
     `shouldClearAllDayCompactIMURecoveryLeaseAfterLiveCompact(lastNotifyTypeHex: "33")`,
     with "33" hard-coded.
   - **Consequence.** Before this commit only compact frames reached that
     path. Now every native R10 frame clears the all-day compact IMU
     recovery lease and marks stream 5 as confirmed.
   - **Is it intended?** If 0x33 really cannot be recovered on this
     firmware, clearing the lease may be what you want. But it happens
     implicitly, and the diagnostics will say "compact live" when only R10
     is flowing.
   - **Fix.** Pass the real frame type through.
2. **Compact-to-R10 handover can double-count or drop a few seconds.**
   - **Double count.** The preference check reads
     `lastCompactIMUIngestUnix` before the compact frame of the same second
     is ingested. When compact resumes, the first R10 second is counted and
     then the compact second is counted too.
   - **Gap.** When compact stops, R10 frames are dropped for up to
     `compactIMUPreferenceWindow` (5 s), so those seconds are counted by
     neither source.
   - **Check.** Whether `r10MotionPipeline` de-duplicates by sample time
     decides whether the double count is real.
3. **The 3F/01 resend never gives up.**
   - **What happens.** If the strap never produces R10, 3F/01 is re-sent
     every 120 s for as long as HR is fresh, with no cap and no backoff.
   - **Why it matters.** This is the recovery-state defect shape the repo
     has hit six times. It costs a BLE write every 2 minutes all day.
   - **Fix.** Cap the attempts per connection, or back off exponentially.
4. **A 3F/00 that does not land is never retried.**
   `r10LiveOffSent` is set when the write is handed to CoreBluetooth, not
   when the strap acknowledges it.
5. **The name "R10 frames fresh" covers more than R10.**
   `r10FramesFresh` reads `lastR10MotionFrameAt`, which the compact path
   also stamps. The controller is correct, because it must not send 3F/01
   while compact is live, but the name suggests otherwise.
6. **A defaults read per frame.** `r10LiveStepsEnabled` reads
   `UserDefaults` on every R10 frame on the BLE callback lane. It is cheap,
   but it could be read once per connection like the other policy inputs.

---

## 5. Verification

- **Simulator.** iPhone 17 Pro `85C288CE-EA97-4A98-B650-44BCF49F2CA5`, with
  its own derived data at `/tmp/cr0924-dd`.
- **Baseline.** The full `AtriaTests` suite ran on dad5eaf2 before any
  change (5,870 passed, 22 failed). It could not be repeated on 37c88354,
  so the classes that commit touched were re-run separately.
- **After the changes.** The full suite ran again on this branch, and the
  failure sets were compared name by name. The final report has the
  numbers.
- **Static checks.** `test_handoff_static_checks.py` shows the same 77
  failures before and after.
