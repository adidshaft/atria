# Atria — Merged Implementation Plan: Recovery, Strain, Stress, Steps, Widgets

Merged from five investigations (recovery-latency, strain-targets, stress-gaps, step-latency, widget-sync). Nothing below is new analysis; every item, constraint, and risk traces to an investigator finding. Phone runs commit `288b5c14`; all device claims were verified against that build.

---

## 1. Priority ranking (user-felt impact × risk)

| # | Item | Why this rank |
|---|------|---------------|
| 1 | Step capture loss + credit starvation (step-latency RC1/RC2) | ~13.4h/day physically unbanked (dutyCycle receipt: sync_cutover 48,079s vs armed 19,882s today) — unrecoverable data loss every day it continues; plus banked steps credit hours-to-days late |
| 2 | Dead journal-union stress replay (stress-gaps RC1) | Every journal-unioned replay produces ZERO facts since d10f1fcd (2026-08-13) — near-past chart holes never heal; device-proven (19:09 gap receipt, qualifiedAndReconciled=0 over 12h) |
| 3 | Recovery settlement race at cycle flip (recovery-latency) | Device-proven today: future-end confirm mints the frozen metric for YESTERDAY's wake day and nothing re-runs the minter; Home's provisional bridge is honest, but widgets/trend/HealthKit wait for next launch. Highest-severity fix that is wave-gated (Sessions.swift is locked by a concurrent agent) |
| 4 | Strain-target mint/delete integrity (strain-targets RC1/RC2/RC4) | Frozen daily target unmintable since 2026-07-22 (stale blob still live); scheduler can mint from unverified tiers AND erase the day's target on nil attribution (the repo's recovery-state defect class); live fallback target moves intraday |
| 5 | Widget civil-midnight blanking (widget-sync RC1/RC2) | Shifted sleeper (13:15–19:15 cycle) sees "Awaiting today's data"/"--" from 00:00 until the next full publish, while the in-app Today is still correct; background patches cannot cross the fence |

---

## 2. Concurrency ground rules (bind all waves)

- **Locked files (concurrent agents, do not touch until their branches land):**
  - Agent 1: `Sessions.swift`, `AtriaActivityMonitor`, `AtriaHistorySection`
  - Agent 2: `AtriaOverviewSections`, `AtriaTrendChart`
  - Anything touching these is scheduled Wave 3+ and requires rebase + re-verification of every line anchor cited below before applying.
- **`AtriaHomeView.swift` is contended by three workstreams** (stress: ~11504–11531; widget: 3461–3536; strain: 12121–12293 and 12199–12224). Exactly one AtriaHomeView-touching workstream per wave.
- **Global test rules (flagged in every investigation):** scheme `AtriaTests` (never `Atria`); suites share process/defaults, so use per-test isolated `UserDefaults` suites and avoid multi-save integration tests (zombie-store clobbering); anchor fixtures after 2026-08-06 (host's persisted device-use journal contaminates time-anchored windows).
- **Device rules:** announce each device action before running it (keep-user-in-loop); defaults pulls (`defaults-s16.plist` channel) are the ground truth; before suspecting a new-build regression, run the install-collateral checklist (battery latch, consumer re-proof, etc.).
- **Never re-enable automatic full-drain recovery** (WHOOP4 replays oldest-first at 1x realtime, no seek) — binds every step/stress item.

---

## 3. Wave 1 — start now (three parallel agents, disjoint file sets, no locked files)

### W1-A: Step capture and credit (step-latency, Steps 1, 2, 4, 5)

**Files:** `AtriaBLEManager.swift`, `AtriaBLEHistoricalRecoveryPolicy.swift` (+ `AtriaBLELiveContinuityPolicyTests`)

**Exact changes:**
1. **Unify the "raw lane actively owns radio" predicate; fix the offload-lane asymmetry.** Extract the arm path's idle test (AtriaBLEManager.swift:28386–28391: continuationPending AND next evaluation sooner than rawSliceIdleWindow=60s) into a pure nonisolated static on `AtriaBLEHistoricalRecoveryPolicy` (beside `historicalMotionBankRearmBlockedByRawOwnership`, line 1162). Replace the three bare `connectedRawHistoryCatchUpContinuationPending` guards with it: `resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded` (30220–30226), accepted-HR hot-path offload gate (25548–25551), hourly-checkpoint gate (25573–25576). Effect: closed directOffload tickets drain during any >=60s idle raw gap instead of waiting for full backlog convergence; serve cutover still reclaims transport.
2. **Bounded capture-share during sustained catch-up.** In `connectedRawHistoryCatchUpContinuationDisposition` (AtriaBLEHistoricalRecoveryPolicy.swift:1186–1207) add a coarse periodic capture-window leg: after ~N productive slices (~25–30 min of drain), return a pause of 90–120s (>= rawSliceIdleWindow + margin). Existing arm path opens 0x69 during the pause with no new arming code; next slice's serve cutover closes it into honest coverage. Constants as defaulted parameters (pure-function testability); DEBUG launch-arg override mirroring `--atria-gate4-daily-checkpoint-seconds` (AtriaBLEManager.swift:3393–3403). Cost: two WWR commands/cycle, ~6–7% drain throughput at 120s/30min — conservative, tunable.
3. **Steady-state polish.** Lower `workoutHistoricalMotionBankGlanceMinimumOpenSeconds` 600→300 (AtriaBLEManager.swift:3351–3352); keep the 10-min glance spacing (3353–3354) and hourly background checkpoint at 3600s.
4. **Observability.** New duty-cycle-style counter distinguishing offload deferrals (`deferred_raw_active` vs `admitted_raw_idle`) next to `noteMotionBankDutyCycle` (28351–28363).

**Tests:** New pure-predicate cases in `AtriaBLELiveContinuityPolicyTests`: pending+idle=admit, pending+active=defer, no-continuation=admit. Capture-window disposition cases via the defaulted-parameter pure function. All pure-policy; no multi-save integration tests.

**Device verification:** After one real day: `atria.debug.motionBankDutyCycle.v1` shows sync_cutover reduced by roughly the scheduled capture share with `armed` growing correspondingly; a glance while backlog is pending credits banked steps within ~1–2 minutes (`ATRIADBG workout_motion_bank` / `whoop4_daily_steps` log lines are ground truth); one defaults pull of the new deferral counter proves Step 1.

**Risks/constraints (all binding):**
- Never re-enable automatic full-drain recovery; every fix is slice/pause scheduling, never a new drain mode.
- Do not recreate the physically-rejected v5 flow: 69/01 must never reopen INSIDE a raw continuation episode faster than read_cursor converges (comment at AtriaBLEManager.swift:28404–28407); the capture window is a scheduled pause, not an interleave; cadence stays coarse (>=25 min).
- Fail-closed step provenance stays: coverage ledger remains the only bank authority (Sessions.swift:11631 `no_bank_coverage` skip; qualification gates AtriaWhoop4MotionTickCompactStore.swift:1794–1863); unbanked hours stay visibly missing ("N% tracked"), never estimated (08-02 device-definitive finding rejected formula fixes).
- `AtriaWhoop4DailyMotionBankRearmPolicy` attestation chain (full-drain 0x16/0x00 owner path) untouched; do not weaken its cancel/defer gates (battery, cutoverActive, terminalObserved).
- Battery invariants stay: `batteryAllowsRearm`, checkpoint battery gate (>=10% or charging, 28712–28713), H13's 25% motion-attempt precondition; strap-power-constrained cadence stretching (policy 1203–1206) must also stretch the capture cadence.
- Ledger budgets: maximumPendingOffloads=128 / maximumClosedIntervals=512; ~48 new tickets/day is within budget but monitor so churn never evicts honest missing-coverage records (provenance relocates, never disappears).
- No `Sessions.swift` receipt-code edits in this pass (locked).
- `wwr_backpressure` and `await_fresh_hr` buckets: the latter (7,954s on 08-19) gets its own diagnostic pull before any fix — not addressed in this wave.

### W1-B: Stress replay and live scoring (stress-gaps, fixes 1–5)

**Files:** `AtriaHomeView.swift` (11504–11531 region only), `AtriaStressMonitor.swift`

**Exact changes:**
1. **Restore the journal-union replay lane (highest yield).** In `scheduleHistoricalStressReplay` (AtriaHomeView.swift:11504–11508) replace `sourceSessions.append(journal)` with an order-preserving insert at the FRONT of the newest-first list (`sourceSessions.insert(journal, at: 0)`) after the `removeAll(id==journal.id)` dedupe. If journal.start is unexpectedly older than the current head's start, drop the journal for that run (fail closed, matches today's no-journal behavior). Do NOT add sorting inside `AtriaHistoricalStressReplay.evaluate` — the refusal to sort (2463–2485) is a deliberate overlap-provenance guard.
2. **Stop pruning live evidence before it is scored.** `hrWindowSeconds`: windowDuration → windowDuration + evaluationCadence (300→360) at AtriaStressMonitor.swift:2986. Kernel already filters to [end-300, end] (AtriaPhysiologicalStressModel.swift:400–403), so no scoring-semantics change.
3. **Bounded retroactive catch-up for tick-starved minutes.** In `update()` after the `lastEvaluatedMinute` guard (4178–4182): when the new minute is more than one cadence ahead, evaluate skipped minute boundaries oldest-first (bounded to windowDuration/evaluationCadence = 5) with `WindowInput(end: skippedMinute)` from the retained buffer, chaining `previousMinuteFact` in order, preserving decline-resets-EMA (4264). `hasActiveSleepEvidence` computed per skipped minute via `hasQualifiedActiveSleepEvidence(at: skippedMinute)`; motion context fails closed to `.unavailable`. Only windows passing UNCHANGED gates produce facts.
4. **Honest abort receipts.** Thread an explicit abort marker from the replay worker (AtriaHomeView.swift:11519–11531) into `finalizeGapReceipts` (AtriaStressMonitor.swift:1916–1968) when evaluate returns `.empty` for a structurally-rejected non-empty source — record e.g. `replay_aborted_session_order`, not per-minute `kernel_declined` for a kernel that never ran. Fix the missingMinutes cap to retain the NEWEST 96 entries per the documented "newest last, capped" contract (1804–1805, 1963–1965).

**Tests (AtriaTests scheme, fixtures post-2026-08-06):**
- 3-session newest-first savedSessions + newer journal session → snapshot+evaluate produces facts for journal-covered minutes (currently `.empty`).
- Pin the defect shape: journal appended at END → evaluate returns `.empty` (documents the ordering contract).
- `.empty` carries no managedRanges (failed replay never deletes facts).
- 1Hz `update()` with a 20s stall starting <10s before a minute boundary → boundary minute now produces a fact; assert pre-fix baseline declined it.
- 70s tick outage spanning a full wall minute, stall began <10s before boundary → leading skipped minute scores retroactively; subsequent minutes stay declined by the 60s gap rule.
- Receipts from an ordering-aborted replay contain no `kernel_declined`.

**Device verification (announce each action first):** After install, re-pull `atria.debug.stressGapReceipts.v1` and stress-minute-v3 shards; expect (a) journal-unioned replays with qualifiedAndReconciled > 0, (b) 18:12–18:16-shaped near-past holes back-filled within one 750ms-debounced replay of rows becoming journal-resident, (c) single-minute holes reduced to genuine >=10s trailing-absence declines only, (d) each remaining hole carrying a truthful receipt class.

**Risks/constraints (all binding):**
- Never interpolate; remaining single-minute holes are honest declines and the chart must keep breaking there. Do not widen `maximumFactContinuityGap=90` (AtriaPhysiologicalStressModel.swift:35).
- Pinned fail-closed model gates stay: minimumQualifiedHRSpan=290, maximumRawHeartRateGap=60, minimumQualifiedHRSamples=5 (model :31, 39–40).
- Live facts are immutable; replay may only fill holes or replace replay per `mergeHistoricalReplay` non-regression rules (AtriaStressMonitor.swift:3233–3298); exact-clock collision authority must not weaken.
- `.empty` stays destruction-free (no managedRanges, 1488–1491); the ordering fix must not convert an abort into a managed-range publication.
- No sorting inside `AtriaHistoricalStressReplay.evaluate`; fix the caller's insertion only.
- EMA honesty: catch-up evaluates minutes strictly in order; declined minute clears the EMA seed (4264; replay mirror 1974–1975) — no fact smooths across a telemetry gap.
- Context skew in catch-up bounded to 5 minutes; sleep evidence computed at the skipped minute, not the current tick.
- No `Sessions.swift` edits needed or permitted here.
- 300s warm-up after relaunch is by design; install-window minutes with no phone-side rows (16:18–16:19 on 08-20) remain honest gaps until a strap-flash drain reaches them — never chase them with the full drain.

### W1-C: Strain-target mint authority (strain-targets, fixes 1, 3, 4 — the non-AtriaHomeView subset)

**Files:** `Dashboard.swift`, `LocalNotificationScheduler.swift`

**Exact changes:**
1. **Unify mint authority — one honesty standard for one durable write (P0).** Extract the mint-authority decision into `AtriaDailyStrainTargetStore` (e.g. `static func mintAuthority(recoveryConfidence:)` in Dashboard.swift) and use it from BOTH writers. In LocalNotificationScheduler.swift:1350–1356 pass `mutationAuthority: attributedRecovery == nil ? .preserveExisting : (confidence-gated .canonical)`, mirroring AtriaHomeView.swift:12283–12293. Stops the scheduler minting from unverified tiers and stops delete-on-nil-attribution erasure (Dashboard.swift:80–85 becomes reachable only from a genuinely canonical caller asserting a reclassified sleep).
2. **load_learning_at_mint upgrade (P1).** In `resolve` (Dashboard.swift:86–97): when the existing same-cycle snapshot has `loadProvenance == "load_learning_at_mint"` and the caller now supplies a prepared non-learning load, re-mint once with the same recovery and the real adjustment; keep the old provenance string inside the new one (e.g. `load_high_upgraded_from_learning`) — provenance relocates, never disappears. At most one upgrade per cycle.
3. **Stale-blob hygiene (P1).** On any resolve where the stored day predates the current cycle by more than one full cycle, rewrite the blob to a dated audit key (e.g. `atria.coach.frozenDailyStrainTarget.last`) instead of leaving it under the live key — keeps evidence, empties the live slot; never silently deleted, never returned.

**Tests (isolated UserDefaults suites; resolve already takes `defaults:`):**
- Scheduler-shaped call with nil recovery must NOT remove the stored snapshot.
- Unverified-tier recovery must not mint via either caller shape.
- Source-pin / shared-helper test that Home and the scheduler cannot drift again.
- Mint under learning load, then resolve with ratio 1.4 → single re-mint to target−2; third resolve is a no-op.
- Stale blob is relocated, not returned, not silently deleted.

**Device verification:** Defaults pull of `atria.coach.frozenDailyStrainTarget.v1` — confirm the July-22 blob is relocated to the audit key without a spurious delete-then-mint churn on first launch, and (after Wave 3's fix 2 lands) that a fresh mint appears on the next wake cycle.

**Risks/constraints (all binding):**
- Honesty rules: never fabricate a recovery percent or target; the pending-sleep-review presentation estimate (Sessions.swift:24028–24059) is display-only and must NEVER mint durable state; fail-closed gates (learning → nil target) stay.
- `.validated` is RESERVED for a held-out outcome study (AtriaAnalytics.swift:1458–1465) — no fix treats reference-validated HRV as tier-upgrading.
- Frozen-day invariant: "A daily goal must not move backward as the user makes progress" (Dashboard.swift:162–168) — the load-upgrade re-mint can lower the target by 2 exactly once, disclosed in provenance; if product rejects any intraday movement, ship as mint-deferral instead.
- No Sessions.swift or AtriaOverviewSections changes in this workstream; zone-chip labeling coordination deferred to Wave 4.
- Pinned: DisplayCalibration constants (21.0/150.0) and the strain score curve are byte-identical-pinned (293d1a7c) — untouched.
- Device state respected: user-edited `atria.target.strain.yellowBand = 2.0` survives untouched.
- Deletion semantics of Dashboard.swift:80–85 exist for a real case (deleted/reclassified sleep must not leave a stale target) — narrow WHO may assert it; do not remove the path.

---

## 4. Wave 2 — after Wave 1 merges (AtriaHomeView freed by W1-B)

### W2-A: Widget sync (widget-sync, fixes 1–6)

**Files:** `WidgetSnapshot.swift`, `AtriaWidget/AtriaWidget.swift`, `AtriaApp.swift`, `AtriaAppIntents.swift`, `AtriaHomeView.swift` (3461–3536 region only). `AtriaOverviewSections.swift:6300` and `Sessions.swift` are read-only references here.

**Exact changes:**
1. **Civil-day-rollover republish trigger (RC1).** In AtriaApp init next to `durableStepReceiptObserver` (AtriaApp.swift:186–198), observe `.NSCalendarDayChanged` (plus the existing scene-foreground path as backstop) and call `WidgetSnapshotPublisher.schedulePublish(store:ble:reason:"civil_day_rollover")`. `publish()` already resolves prior-vs-current identity honestly via AtriaCurrentDayPresentation (WidgetSnapshot.swift:1610–1649); must go through `schedulePublish` so it inherits the `shouldPersistSnapshot` launch fence (1928–1936, gate use 1830–1845) — never a direct defaults write.
2. **Split the extension's day fence (RC1/RC2).** In `atriaEnforceCurrentDayIdentity` (AtriaWidget.swift:242–306): on day-key mismatch, stop nil-ing steps (275–283) and strain (270–274) when their own publisher-persisted `stepsCycleExpiresAt`/`strainCycleExpiresAt` fences (WidgetSnapshot.swift:2198–2218) are still in the future; keep recovery/sleep/biomarker/whiteboard blanking exactly as-is (H10 civil-day identity). Tiles keep "counted through HH:MM"/partial disclosures. Extract the enforcement function into a file compiled by both targets (or mirror it) so it gets the unit coverage `AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay` already has (AtriaCurrentDayPresentationTests.swift:285–346). Absent fence fields → blank as today (legacy payloads keep failing closed).
3. **Fix the stale-disclosure clock (RC3).** Add additive optional `stableEvidenceRefreshedAt` to WidgetSnapshot + AtriaWidgetSnapshot, set ONLY in full `publish()` (~1655), carried unchanged by `snapshotCarryingStablePresentation` (1176–1196) so all three patch lanes and `invalidateBatteryProjection` preserve it; key `atriaSnapshotIsStale`/`atriaSnapshotAgeMinutes` (AtriaWidget.swift:35–41) and the footer (1334–1341) to it, with createdAt fallback for legacy payloads.
4. **Close the RC4 class with the proven §13.6 pre-render pattern.** Extend the snapshot with app-rendered display strings for the step tile (`stepsValueText`, `stepsStatusText`) and strain value (`strainValueText`), computed by the same models the in-app card uses; extension prefers them, current derivations become legacy fallback; add the new strings to `timelineTransitionFingerprint` (WidgetSnapshot.swift:2037–2104); same for AtriaAppIntents `strainCompact`/`strainSpoken`.
5. **Align live-source step value window with its status line (RC5).** In AtriaWidget.swift make `value()` fail to "--" (or append the frontier) at the same boundary `statusText` uses — either drop `atriaStaticStepFreshness` for the numeric value toward the app's 15–20s claim window, or keep 90s solely as delivery slack but render the "last HH:MM" qualifier on the value line once age exceeds `liveEvidenceMaximumAge`. Verify the expiry-boundary timeline entry (385–394) still lands. Canonical (cycle-bound) rows untouched.
6. **Reload-ledger truthfulness (RC6).** Route `invalidateBatteryProjection`'s reload through the coalescer's `deliverTimelineReload` (WidgetSnapshot.swift:2157–2162) instead of the raw WidgetCenter call at 1332, so `lastTimelineReloadSnapshot`/`Date` stay truthful.

**Tests:** Observer-wiring unit test in the existing durable-step-observer style; day-fence fixture (snapshot published 23:50, cycle expiry 19:15 next day → 00:10 entry keeps steps/strain with frontier text, blanks recovery/sleep; entry past 19:15 blanks everything); AtriaWidgetBatteryInvalidationTests injected-defaults style: durable step patch at hour 7 must not clear the stale line, a full publish must; battery-invalidation test asserting the reload ledger updates. Pure-function tests for the extracted day fence (AtriaPerfFixesTests precedent).

**Device verification:** ATRIADBG `widget_snapshot reason=civil_day_rollover` after a post-midnight background BLE wake; widget proof sheet (`widgetProofSnapshot`, AtriaHomeView.swift:2875) plus Mirroring screenshots after a forced post-midnight window; diff against the installed build and run the install-collateral checklist before suspecting new-build regressions.

**Risks/constraints (all binding):**
- No fabricated values; fail-closed gates stay; provenance relocates, never disappears. Fix 2 must not let recovery/sleep/biomarker survive civil midnight — only steps/strain, only while their physiological fences are in the future.
- Do NOT touch the step-authority merge lattice: `durableStepPatchedSnapshot` (531–727), `snapshotPreservingFresherStepAuthority` (751–1001), `liveWorkoutPatchedSnapshot`'s `acceptsIncomingSteps` ordering (1027–1065) — every new field is display-only, zero authority semantics.
- Schema changes additive-optional only; installed extensions keep decoding schema-4; never rename/repurpose keys; keep JSON coders iso8601+sortedKeys (2369–2387).
- Recovery-state defect class guard: the fence must not be clearable only by the success it blocks — rollover republish needs launch-independent triggers (NSCalendarDayChanged AND scene foreground), and the fence-split must work even when no republish ever fires.
- Strain honesty pin: `publish()` withholds `strainCapturedAt`/`strainCycleStart` when strain is not credible (1673–1675); widget fails closed on missing cycle fields (86–99); a live patch cannot reinstate a withheld credibility clock.
- WidgetKit reload budget: keep 60s sensor lane / 15min max coalescing; rollover adds exactly one republish per midnight; `forceImmediateTimelineReload` stays reserved for scene-background and BG-task edges.
- Static HR 65s vs in-app 6s is a documented, disclosed design divergence — do not "fix" it; only the step value/status inconsistency (RC5) is a defect.

### W2-B (no code, parallel): step-latency Step 3 device experiment

Announce first, then run the device experiment: confirm whether `AtriaBLEHistoryExactRequestPolicy` exact wall-clock requests return banked v24 rows for a just-closed window (physically proven for the Jul-24 gap windows, unproven for this path). If the read_cursor-forward constraint noted at AtriaWhoop4MotionBankCoverageLedger.swift:55–58 holds, the Wave-4 sub-step is DROPPED (accept frontier credit for cutover closes) — never assumed.

---

## 5. Wave 3 — gated on Agent 1 releasing `Sessions.swift` (rebase + re-verify all line anchors first)

### W3-A: Recovery settlement at the cycle flip (recovery-latency P0-1..P0-4, P1-1)

**Files:** `Sessions.swift` (11466–11475, 41482–41498, 52286+), DailyRollupStore pin test only (no DailyRollupStore.swift source change)

**Exact changes:**
1. **Arm the settlement at the confirmed sleep's end (P0-1).** In `prepareConfirmedSleepSave` (41482–41498): when the newest settled sleep's end > preparationNow, return `nextRolloverBoundary = min(existing nextNoSleepRollover, newestSleep.end + 1s)`. The existing `schedulePhysiologicalCycleRolloverCheck(at:now:reason:)` timer (11436–11464) wakes at end+1s — no new machinery.
2. **Make the rollover handler settle, not just refresh steps (P0-2).** Extend `handlePhysiologicalCycleRollover` (11466–11475): after `refreshCurrentCycleStrapStepReceipt`, resolve `latestCompletedMainSleep(now:)`; if its wake-day frozen metric is missing or fails `deferredLaunchCardSettlementMatches` (same check as 52147), call `settleConfirmedMorningAuthority(reason: "cycle_rollover_settlement")` and `publishDashboardRevision` on success. Bounded by design (minter never reads live journal or historical archive, 52282–52284); closes BOTH the future-end race and the background-deferred-confirm window (`deferDerivedPublication: true` paths, e.g. 17488/17794, guard at 41723) with one edge.
3. **Belt-and-braces in the minter (P0-3).** In `settleConfirmedMorningAuthority` (52286+): when the newest confirmed sleep ends in the near future (now < end <= now + a few minutes), schedule a one-shot retry at end+1s instead of silently settling the previous wake day. `makeMorningFrozenDailyMetric`'s completedBy:now gate (22550–22554) untouched — the fix re-runs the minter when its precondition becomes true; it never mints from an unfinished night.

**Tests (P0-4, AtriaTests, pure-level per repo rules; no multi-save integration tests):**
- `prepareConfirmedSleepSave` fixture with end = now+6min asserts `nextRolloverBoundary == end+1s`.
- Rollover-handler test: `settleConfirmedMorningAuthority` invoked when the wake-day metric is absent; NOT invoked when `deferredLaunchCardSettlementMatches` passes.
- DailyRecoveryResolver pin: between confirm and freeze, the anchored-cycle summary stays nil (provisional shown) — pin the existing contract at DailyRollupStore.swift:468–485 against regression.

**Device verification (P1-1 + ground-truth channel):** After the next future-end confirm on device, pull defaults and confirm the frozen daily metric exists for the NEW wake day at end+1s (same `defaults-s16.plist` channel used for diagnosis); verify `WidgetSnapshot.publish` runs on the same rollover edge and frozen-first `canonicalRecovery` (WidgetSnapshot.swift:1375–1380) picks up the new freeze in the same pass (`refreshCurrentCycleStrapStepReceipt` already posts a Home/widget invalidation — confirm it).

**Risks/constraints (all binding):**
- Never mint/freeze recovery from a sleep whose end is in the future — completedBy:now (22550–22554) and the end<=now filter in `boundaryEligibleMainSleeps` (284) are honesty gates; re-trigger the minter, never loosen them.
- Frozen-first contract survives: `metricMatchesConfirmedNight` (DailyRollupStore.swift:608–620) intentionally rejects stale same-civil-day metrics during the confirm→freeze handoff; add NO tolerance — the provisional projection is the designed bridge.
- RecoveryProjectionCache autoclosure contract is pinned by counter tests (Sessions.swift:23878–23880): frozen checked before Recovery v2 evaluates; any new call site preserves lazy semantics.
- HR-only honesty rules bind: no HRV promotion from HR-only data; minimumQualifiedHRVWindows=3 stays; mainSleep-cycle HRV substitution stays forbidden (23763–23773); pending-review preview stays day-one-only and .unverified-capped (24028–24059).
- `settleConfirmedMorningAuthority` bails under `canonicalMutationAllowed==false` or an active recovered-data ticket (52296–52305) — the rollover-edge call must tolerate a bail and rely on the existing launch-repair path; never force a write through the mutation fence.
- MainActor: the minter is bounded but percentileHR/TRIMP scans are O(n); if profiling shows jank, route through the existing cancellable `shouldContinue` variant rather than skipping the settle.
- Do not change (P2-2): the 30-min closed-candidate settle delay (37675–37681, resumed-fragment protection), the 30-min foreground rate limit, the 4h provisional TTL, the exact-input `metricMatchesConfirmedNight` resolver — documented honesty/cost invariants, none is the bottleneck once P0 lands.

### W3-B: Strain provisional mint + prior-cycle disclosure (strain-targets fixes 2, 5) — disjoint from W3-A

**Files:** `Dashboard.swift`, `AtriaHomeView.swift` (12121–12127 and 12199–12224), `AtriaMetricTargets.swift` (labels only)

**Exact changes:**
1. **Make a stable daily target reachable WITHOUT weakening fail-closed gates (fix 2, P0).** Allow minting from a NUMERIC AUTHORITATIVE recovery of tier `.unverified` — never from the pending-review presentation preview (Sessions.swift:24028 boundary stays intact; read-only reference). Add `recoveryConfidence` to `AtriaFrozenDailyStrainTarget` (Dashboard.swift:3–48, schemaVersion 2, decodeIfPresent-defaulted so the on-device v1 blob — day/recovery/target only — still decodes). Change `recoveryAuthorizedForStrainTarget` (AtriaHomeView.swift:12121–12127) to return (percent, tier); `resolve` stores the tier as provenance; surfaces label "provisional" when confidence < personalBaseline via the existing targetSummary/sourceLabel plumbing (AtriaMetricTargets.swift:109–140). Extend the recovery-changed re-mint check (Dashboard.swift:92) so a TIER upgrade with the same percent re-mints exactly once (provenance upgrade, value may move once, disclosed).
2. **Shifted-sleeper presentation continuity (fix 5, P2).** During the post-wake window where the cycle has flipped but recovery is not yet canonical (target nil), surface the PRIOR cycle's frozen target as a dated disclosure using the existing AtriaCurrentDayPresentation/AtriaPriorCycleDisclosure pattern (AtriaHomeView.swift:12199–12224) — no fabricated value: the real prior target with its real date.

**Tests:** Mint from unverified numeric recovery records the tier; tier upgrade re-mints exactly once; personalBaseline behavior byte-identical to today; schemaVersion-2 decoder accepts the on-device v1 blob; fixture with cycleStart 19:15 IST and unverified recovery → guidance shows dated prior target, zone chip stays absent.

**Device verification:** Defaults pull confirming `atria.coach.frozenDailyStrainTarget.v1` re-mints on the next wake cycle (the ground-truth channel used for the diagnosis), with tier provenance recorded.

**Risks/constraints:** Same seven strain-targets risk bullets as W1-C apply in full (honesty/never-mint-from-preview, `.validated` reserved, frozen-day no-backward invariant, no AtriaOverviewSections/Sessions edits, DisplayCalibration pinned, device blob/tunable respected, deletion-path preserved). Additionally: schemaVersion 2 must keep decoding the v1 blob (established decodeIfPresent migration pattern, Dashboard.swift:37–47).

---

## 6. Wave 4 — coordinate-first / experiment-gated

### W4-A: Shifted-sleep review-card latency (recovery-latency P2-1)

**Files:** `Sessions.swift` (38714–38716). **Gate:** explicit coordination with the sleep-day-grouping owners — this is their domain; larger change.

**Exact change:** Let the REVIEW tier only (not auto-persist) use the learned duty-cycle window core instead of the fixed 00:00–06:00 core in `isDegradedHROnlyOvernightSleepCandidate`'s `sleepCoreOverlapFraction` gate, so a 13:15–19:15 sleeper gets a review card promptly at wake and manual confirm happens minutes, not hours, after wake. Do NOT touch the auto-persist tiers' gates (`isStrongAutoConfirmableSleepCandidate` 38582–38617, `isHighSpecificityFragmentedHROnlyMainSleepCandidate` 38646–38673, `isUnambiguousHROnlyMainSleepCandidate` 38675–38699).

**Tests:** Review-tier candidate fixture with a daytime sleep passing the learned-core overlap; auto-persist tier gates pinned unchanged. **Device verification:** review card appears at wake on the next shifted-sleep day. **Risks:** all recovery-latency risk bullets above; plus this remains latency mitigation — the structural pre-confirm latency finding stands (auto-confirm tiers are dead for daytime sleep by design; the unambiguous tier has never fired on this device — all 40 persisted sleeps since 07-08 are manual/user_adjusted/user_confirmed).

### W4-B: Exact-window credit for cutover-closed banks (step-latency Step 3) — ONLY if the W2-B experiment proved it

**Files:** `AtriaBLEManager.swift`, `AtriaWhoop4MotionBankCoverageLedger.swift` (read: 44–65, 422, 561, 636, 666, 873–891)

**Exact change:** During the Step-2 pause, when foreground/glance conditions hold, close via the explicit 69/00 path (`stopWorkoutHistoricalMotionBankIfPossible`, 29179 — mints a directOffload ticket) and let Step 1's now-schedulable exact-window offload run inside the same pause (a 2-min window is seconds of transfer). Separately, let a cutover-closed window mint `.directOffload` when its interval is recent and exact wall-clock serving is device-proven. **If the read_cursor-forward constraint holds, this sub-step is dropped, not assumed** — frontier credit stands for cutover closes.

**Tests/verification:** device-experiment first (W2-B); then glance-credit latency check per Step 5 acceptance. **Risks:** all W1-A risk bullets, especially the physically-derived firmware constraint and the ban on recreating the v5 flow.

### W4-C: Zone-chip "provisional" labeling — gated on Agent 2 releasing `AtriaOverviewSections`

**Files:** `AtriaOverviewSections.swift` (zone-chip labeling only; the four strainZone call sites already apply the user tunables consistently — greenBand 1.5 / user-edited yellowBand 2.0 at 2121–2122 survive untouched). Coordinate before touching; carry the W3-B "provisional" label through the Overview chip. Note from the investigation: `TargetZones.strain` returns nil when target is nil (AtriaAnalytics.swift:217) and the chip correctly vanishes — that fail-closed behavior stays.

---

## 7. Consolidated do-not-change list (invariants every wave must respect)

- Recovery: completedBy:now and end<=now honesty gates; `metricMatchesConfirmedNight` exact-input identity; RecoveryProjectionCache lazy/frozen-first contract; HRV rules (min 3 windows, no substitution, no HR-only promotion); pending-review preview day-one-only + .unverified-capped; 30-min settle delay; 30-min foreground rate limit; 4h provisional TTL; the canonicalMutationAllowed fence.
- Strain: DisplayCalibration (21.0/150.0) byte-identical; `.validated` reserved for the held-out study; frozen-day no-backward-movement; presentation preview never mints; Dashboard.swift:80–85 deletion path preserved (narrowed, not removed); user tunables untouched.
- Stress: 290s span / 60s gap / 5-sample kernel gates; maximumFactContinuityGap=90; live-fact immutability + mergeHistoricalReplay non-regression; `.empty` destruction-free; no sorting inside evaluate; decline-resets-EMA; 300s warm-up by design.
- Steps: no automatic full drain, ever; no v5-style 69/01 interleave inside a continuation episode; coverage-ledger-only step provenance, no estimates for unbanked hours; rearm attestation chain untouched; battery gates (10% checkpoint, 25% motion attempt, power-constrained stretching) stay.
- Widgets: step-authority merge lattice untouched; additive-optional schema only; recovery/sleep/biomarker/whiteboard never survive civil midnight; strain credibility-clock withholding preserved; reload budget/coalescing preserved; schedulePublish launch fence always used; static HR 65s divergence is by design.
- Process: AtriaTests scheme; isolated per-test defaults suites; no multi-save integration tests; fixtures post-2026-08-06; rebase + re-verify all line anchors for Wave 3+ (Sessions.swift edits land on top of the sleep-day-grouping branch); announce device actions; install-collateral checklist before blaming new builds; device baseline is commit 288b5c14.
