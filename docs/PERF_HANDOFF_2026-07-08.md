# Atria Performance + Architecture Handoff — 2026-07-08

**Read this first, then execute the "Stop the bleeding" fixes in order.** Self-contained
so a fresh session can continue without re-diagnosing. Root cause is confirmed in source
(high confidence).

## ✅ Progress — 2026-07-08 (session 2): "Stop the bleeding" #1–#3 SHIPPED

All three "Stop the bleeding" fixes are implemented, gated, and committed on `ui-ux-polish`
(one commit each): `f7233005` (#1), `b3b3ac35` (#2), `cfa62aca` (#3). **Do NOT re-do these.**

- **#1 — live-session bound (crash).** Implemented as a **retention-window segment-roll in
  the long-wear supervisor** (new `rollLongWearLiveSessionIfOversized`, `AtriaBLEManager.swift`;
  3h span cap → `persistFinishedSession` then `resetLiveSessionState`), **not** as the reset on
  the workout-autosave path the plan named. Two reasons the literal plan was wrong: (a) the
  autosave-persist branch only fires for a *detected workout* (`workoutReadiness.ready`), so it
  would never bound arrays during pure resting/overnight wear — the actual crash window; and
  (b) `test_long_wear_auto_save_keeps_live_session_open` deliberately pins that path as
  `snapshot_keep_live`. Decoupling into its own supervisor step bounds all wear states and keeps
  the tested autosave behavior intact. No data loss (`store.add` upserts by id; full segment
  persisted before reset) and no UI fragmentation (the day's contiguous segments re-cluster into
  one aggregate sleep/wear candidate — `sleepClusters` bridges gaps ≤2h, verified in source).
- **#2 — stress strip.** `AtriaHealthScreen.swift`: segment-aware downsample to ~110 pts
  (`reduceStressStrip`/`bucketStressSegment`, averages real activation, preserves >5min gap
  blanks), computed in `.onChange(of: history)`, Chart isolated in an `Equatable`
  `AtriaStressStripChart`. ~2880 marks → ~220.
- **#3 — latestRollup.** `AtriaHealthScreen.swift`: revision-keyed `@State` memo
  (`LatestRollupCache`) instead of threading a param through 13 properties — O(1) amortized,
  behavior-identical, no pin migration, and it also dedupes across the re-render storm.

**Gates (all green):** `test_handoff_static_checks.py` 128 OK · `AtriaTests` `** TEST SUCCEEDED **`
· Release build + install + launch-verify on device `3803F5B6` clean (`on_appear elapsed_ms=160`,
no launch freeze/crash; long-wear supervisor schedules and runs).

**Verification done (session 3):**
- **Unit tests** — `Atria/AtriaTests/AtriaPerfFixesTests.swift` (commit `def2fa4d`, 10 cases, in the
  gate): #1 roll trigger (below/at/above the 3h cap + min-samples floor + the real 20,291-sample
  session), #2 `reduceStressStrip` (downsample bound + >5min gap kept as a separate segment +
  honest mean + 1:1 small-input passthrough), #3 memo (computes once per revision incl. nil).
  Test seams only: extracted `AtriaBLEManager.shouldRollLiveSession` + widened
  `reduceStressStrip`/`StressStripPoint`/`LatestRollupCache` to internal (no gate pins touched).
- **Real-data corroboration of the crash diagnosis** — `--pull-sessions` (read-only) off device
  `3803F5B6`: 61 sessions; the largest "All-day wear" grew to **20,291 HR samples + 14,013 RR**
  (~5.6h continuous) — direct evidence of the unbounded live-array growth. 4 sessions >2h, 11 >1h;
  median ~570 pts (gaps segment most of the day). That one over-cap session is exactly what the 3h
  roll now splits.
- **On-device #3** — Debug build launched with `--atria-ui-screen vitals` (DEBUG-only tab force;
  the harness doesn't forward it, add it to the `devicectl … launch` args manually): Vitals rendered
  against the real 3-row `dailyRollupHistory` (`daily_rollup_persist_summary entries=3`),
  `body_eval view=AtriaHealthScreen count=1` (single clean render, no storm), zero crashes.

**⚠️ Residual (genuinely needs a live session):** the end-to-end **#1/#2** confirmation under real
continuous streaming — the 3h roll's `span` is measured from a fresh wall-clock `session.first.t`
(the 0x2A37 HR packet carries no device time), so it only fires after 3 real hours of continuous
connected wear; historical/pulled/replayed data can't reconstruct the live arrays (`--replay-log`
is a Mac-side log re-parser; journal-restore clamps to 18h and finalizes >90s-old records). Watch a
live capture for `ATRIADBG live_session_retention_roll status=rolled` (~every 3h of continuous wear)
+ no jetsam + no multi-second ATRIADBG timestamp gaps on Vitals. #3's *perf* delta is not measurable
until `dailyRollupHistory` grows toward 90–400 rows (one row/day; ~3 today).

## ✅ Progress — 2026-07-08 (session 4): "Next pass" partially shipped

- **#5 — LazyVStack scroll-in re-decode SHIPPED** (commit `92f0e469`): guarded `AtriaHistorySection.rebuild()`
  with a revision key; the pulse card's `.task` with a `hasLoadedOnce` flag; `AtriaTrendChartCard`'s
  `prepareSeries` with a `(points, metric, range, baselineRHR)` fingerprint. All behavior-identical.
  Gates green (static 128 + full AtriaTests).
- **Debug affordance SHIPPED** (commit `f6c3d9fb`): `--atria-retention-roll-seconds N` (DEBUG only) shortens
  the #1 retention cap so the roll can be verified against a live strap without waiting 3h. Production unchanged.
- **#4 — DEFERRED (obviated).** #1's retention roll already bounds the live array to ≤~3h, so the O(N)
  `snapshotSession` freeze it targeted is largely gone; the remaining win is a constant factor with a
  value-identity wrinkle (incremental stddev is only ~1e-9-identical, not bit; active-calories can't be
  incremental because it depends on the final resting-HR + retroactive excluded-intervals). User agreed to
  skip. A full, careful #4 recipe (exact-int sum-of-squares + an energy-pair accumulator with a profile-
  signature fallback) is preserved at the session workflow output if ever wanted.
- **#6 — SHIPPED** (commit `e00319a3`): memoized `AtriaPreparedMetricHistory` on its exact inputs via a
  `private static` cache INSIDE the struct's init (Swift-5 mode makes the static clean; the `self = cached.value`
  delegation keeps the pinned init call site + every `preparedHistory.X` access verbatim, so NO pin migration).
  An unchanged re-present is now a struct copy, not ~42 filter+sort+bucket passes. Correct by construction.
- **#7 — SHIPPED** (commit `db3311df`): memoized `AtriaOverviewTrendChartHost.trendEvents` (built eagerly every
  publish, consumed only by the usually-closed expanded chart) behind a workout-revision + night-count/confirmed
  signal, reference-cache in `@State`. Intentionally scoped: `WeeklyReport` is already lazy (sheet-only) and the
  sleep-percent computeds are cheap single-night math with a data-coherence contract — left as-is.
- **#6/#7 on-device/sim check:** app builds + launches + renders cleanly on the iOS-26 simulator (fixture data),
  stable across repeated screenshots (no crash from the `self = cached.value` init), and the sim log shows NO
  "Modifying state during update" (the #7 reference-cache is clean) and no fatal/exception. The metric-detail
  sheet's pixel rendering couldn't be force-opened headlessly (the fixture routes to overview segment content;
  no tap/scroll via simctl), but the change is validated end-to-end by the clean run + gates.

**Live #1 on-device verification attempted, BLOCKED (environmental):** with the strap on, two Debug runs
(`--atria-retention-roll-seconds 120` then `30`) could not accumulate the roll's ≥10-sample floor — the
strap link was too unstable (210 BLE disconnects, HR stalling after ~53s, battery 19%, thermal serious) and
the OS SIGKILL'd the foreground app before the span reached the cap. Not the fix (only ~13 samples ever
streamed). Retry when the link is stable + charged: `ATRIA_DEVICE_ID=… bash live_device_debug.sh --configuration
Debug --seconds 300 --leave-running` then relaunch with `--atria-retention-roll-seconds 120 --atria-long-wear-mode
--atria-standard-hr-only` and watch for `ATRIADBG live_session_retention_roll status=rolled`.

## Where we are
- Branch: **`ui-ux-polish`** (all pushed; `main` is behind by the perf commits — merge when green).
- User's problem: the app is **laggy while scrolling** and **crashes soon after** with the
  WHOOP strap streaming all day. Prior UI/consistency work is done + merged (PRs #14–18; see
  `docs/UI_UX_CONSISTENCY_2026-07-08.md`).
- Already shipped this session: `d269527a` — LazyVStack on `AtriaHealthScreen:47` +
  `AtriaTodayScreen` body (fixed the multi-second **tab-open** freeze). ⚠️ It also introduced a
  **scroll-in regression** (see fix #5 below).

## Confirmed root cause (device console capture + full-source audit)

### The CRASH = out-of-memory **jetsam** (high confidence)
During continuous all-day wear, **four parallel live arrays grow UNBOUNDED** in
`AtriaBLEManager`, because they are cleared ONLY by `resetLiveSessionState` (`:9560`), which
fires solely on explicit stop (`:9494`) or a ≥90s stream gap (`:9529`) — **neither happens
during continuous streaming**:
- `session: [HRSample]` (`:498`, appended `:7217`)
- `rrArchive: [RRInterval]` (`:572`, appended `:9271`)
- `sessionPointsCache: [SavedSession.Point]` (`:501`, appended `:9394`) — dup of `session`
- `rrPointsCache: [SavedSession.RRPoint]` (`:502`, appended `:9336/9400`) — dup of `rrArchive`

At ~1 Hz these reach 10⁵⁺ entries each. The long-wear autosave `runLongWearSupervisorAutoSave`
(`:4646`) **persists to disk but returns WITHOUT resetting** (`mode=snapshot_keep_live`,
`:4684-4702`) — so saving never relieves RAM. `SessionStore.sessions` (`Sessions.swift:3311`)
+ `cachedCanonicalSessions` (`:4927`) retain today's full-resolution copy again (peak 2× during
the ~15s checkpoint replace). → memory pressure → app killed to home screen.
The presentation layer is already bounded/cached (chart points windowed to 200–400, hosts
`.equatable()`, observers `[weak self]`), ruling out a per-scroll leak.

### The 3-7s FREEZES = `snapshotSession` full-rescan on `@MainActor` every ~15s
`snapshotSession` (`AtriaBLEManager.swift:9958`, `@MainActor`) rescans the whole growing array
every autosave (default 15s): `session.map(\.bpm).reduce` (`:9990`),
`standardDeviation(session.map{…})` (`:9991`), `samplesExcludingIntervals(session)` (`:10004`),
`activeCalories` (`:10006`). O(N) fresh allocations, N growing all day = the freeze that
worsens with time. **This is the user's exact "decodes and calculates every single time"
hypothesis, confirmed.**

### The SCROLL jank worst offender = the session **stress chart**
`stressStripPoints` (`AtriaHealthScreen.swift:589`) maps the full ~1440-pt 12h stress history
1:1; the `Chart` (`:611`) draws an `AreaMark` + `LineMark` per point (~2880 monotone-spline
marks), **not downsampled** (every HR chart buckets to ≤72). Re-laid-out synchronously per
body-eval — every 5s stress-timer tick (`:33/:89`), every `SessionStore` publish, and every
scroll-in (no `.equatable()` isolation).

### My LazyVStack fix's regression (fix #5)
Screen-level `.task/.onReceive/.onAppear` are on the outer Group (fine), but three **sections**
now reset their `@State` caches and re-run side effects on each scroll-in:
`AtriaHistorySection` `.onAppear{rebuild()}` (`:191/207`, re-does `DetectionEventLog.load()`
JSON decode + ~400 day rows), the pulse card `.task{refreshHistoricalHeartRatePoints()}`
(`AtriaVitalsCollectionSections.swift:1344`, re-reads 24h archive + flushes merge cache),
and the trend card `.onChange(of: points, initial:true)` (`AtriaTrendChart.swift:152`).

## THE PLAN — do in this order

### 🩹 Stop the bleeding (do first, this fixes crash + most lag; low blast radius)
1. **Bound the live session — STOPS THE CRASH.** In `runLongWearSupervisorAutoSave`
   (`AtriaBLEManager.swift:4646`), when `persistFinishedSession` succeeds (`:4684`), call
   `resetLiveSessionState(start: now)` before returning — the same clean segment-roll the
   ≥90s-gap path already does at `:9548`. Full record stays on disk. *(Alt: rolling cap via
   `removeFirst` down to ~2h @1Hz at the four append sites — but segment-roll is safer because
   it atomically resets every derived counter.)* **Risk:** must keep enough tail for the live
   HR chart + HRV/RR window (~2h); don't cap smaller.
2. **Downsample + Equatable-isolate the stress chart** (`AtriaHealthScreen.swift:589/611`):
   bucket per-segment to ~100–120 display pts (reuse the HR chart's bucketing; **preserve the
   >5min segment gaps** so real blanks aren't interpolated — honesty contract), compute once
   into `@State` via `.onChange(of: stressMonitorStore.history)`, extract the `Chart` into an
   `Equatable` subview keyed on the reduced array.
3. **Resolve `latestRollup` once per eval** (`AtriaHealthScreen.swift:458`): it's an `O(n)
   .max(by:)` read ~13× per `healthMonitorCard` eval (its own comment says so). Compute
   `let latest = latestRollup` once, thread it through. Behavior-identical, near-zero risk.

### 🔧 Next pass (belt-and-suspenders + the scroll-in regression)
4. **Make `snapshotSession` incremental** (`:9958`): maintain running sum-of-squares +
   incremental active-cal/active-sample accumulators (seed in `resetLiveSessionState`, update
   at the HR append gate); compute avg/stddev/calories from O(1) state. **Verify identical
   values vs the current rescan on a captured session before shipping.**
5. **Stop LazyVStack sections re-decoding on scroll-in:** guard `AtriaHistorySection.rebuild()`
   with a `builtRevision` (reuse the `rollup/workout/detection` revisions its `onChange` already
   uses, `:192-194`); guard the pulse `.task` with a `hasLoadedOnce` flag or hoist
   `historicalHeartRatePoints` to a shared object; skip trend `prepareSeries` when a points
   fingerprint is unchanged.
6. **Metric-detail prepared history** (`AtriaOverviewSections.swift:6736`): the sheet init loops
   ALL 6 `AtriaTrendRange` × ~7 metrics (filter+sort+bucket, ~42 passes, `:10052`) on-main, and
   re-runs every ~700ms while presented. Build the selected range only (memoize per-range), or
   precompute off-main into an `@Published preparedMetricHistory` on `SessionStore` keyed to
   `dailyRollupHistoryRevision` (same pattern as `overviewTrendPoints`).
7. **Memoize the rest** behind existing revisions: `trendEvents` (`AtriaTrendChart.swift:2294`,
   only used by the hidden expanded chart), `WeeklyReport(rollups:)` (`AtriaTodayScreen.swift:1178`),
   `sleepPerformancePercent/sleepNeedHoursValue` (`AtriaTodayScreen.swift:870/904`).

### 🏛 Architecture (later, deliberate — NOT before the above ships)
The 10 principles correctly diagnose the disease: a **17,198-line `@MainActor SessionStore`**
(`Sessions.swift:3178`; 353 funcs / 25 `@Published` / 189 computed) fuses ingestion-coordination
+ metric engine + raw store + view model into one god object on the main actor.
- **Adopt now (these ARE the fixes above):** #10 Performance-as-a-feature, #7 central engine /
  UI renders prepared state, #5 event-driven not sample-driven tick.
- **Adopt later:** #1 layer split (high effort), #3 unified `MetricValue<source,confidence,
  freshness,validation>`, #8 active-explanation layer.
- **Already sufficient:** #2 store-raw-first (`rawPayloadHex` + `appendUndecodable`), #4 offline
  sync ledger (real backfill), #6 fail-closed (no fabrication — core law).
- **Skip:** #9 capability-based device support (Atria is single-device WHOOP today; premature).

## How to build / install / verify (this environment)
- Device (Aman's iPhone): `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B bash live_device_debug.sh --release --seconds 10 --leave-running` (builds Release + installs + launch-verifies).
- Debug telemetry: add any `--log-*` flag (e.g. `--log-daily-rollups`) to enable `ATRIADBG` +
  `body_eval` logs. `body_eval view=X count=N` climbing = re-render storm. **Multi-second gaps
  in the ATRIADBG timestamp stream = main-thread freezes.**
- Gates before commit: `python3 test_handoff_static_checks.py` (migrate pins with dated notes)
  + full unit suite (`AtriaTests` scheme, grep `"** TEST SUCCEEDED **"`).
- **Gotchas:** the iOS **simulator is chronically unstable** (shuts down mid-run; `clean test`
  re-clones it and breaks the destination — use a standalone `clean build` then plain `test`).
  Crash-report pull via `sysdiagnose`/`devicectl` is **blocked** (needs on-device consent); use
  console captures. The app binary is `Atria.app/Atria.debug.dylib` (grep that, not `/Atria`).
- Full raw workflow findings (if needed): journal at
  `.../subagents/workflows/wf_b9c8f9e6-0ea/journal.jsonl` (this session only).

## Start here (new thread)
> Continue Atria perf work on branch `ui-ux-polish`. Read `docs/PERF_HANDOFF_2026-07-08.md`.
> Execute "Stop the bleeding" fixes #1–#3 (bound the live session via segment-roll, downsample+
> isolate the stress chart, resolve latestRollup once), gate + install to device 3803F5B6 + verify
> the freeze/crash is gone, commit each. Then the "Next pass" fixes. Honesty is LAW; keep the
> stress-chart segment gaps.

## 2026-07-09 — device P0 triage ("not working / laggy / no detection"), strap connected

Fresh Debug build + 120s telemetry capture on device `3803F5B6` (strap connected). **The app is not
fundamentally broken:** launches in 5ms, HR decodes fine (`hr_accepted=147334`, `hr_zero=10`), render
is clean (`body_eval count=1`, no storm — the memo fixes hold), rollups + widget snapshots keep saving,
`strain_validation` computes (`samples=61007 stream_coverage=99% trimp=130.88 strain=8.56`). No launch
crash ("signal 2" was the capture teardown).

**Confounds in that capture (do not diagnose RR/detection from it):** the script defaulted
`--atria-standard-hr-only` (`radio_mode=standard_hr_only reason=launch_arg`), suppressing RR/HRV
(`gate_b_current_rr_ready=0`), AND the **strap battery was ~7%** (`battery=7`, an `atria.battery.low`
notification that then got canceled), which alone explains most of the flapping (`ble_link disconnects=213`,
`hr_sample_last_status=zero_contact`, watchdog recoveries in the hundreds/thousands). Re-verify detection on a
CHARGED strap in full-protocol (no `--standard-hr-only`).

### ✅ SHIPPED — workout under-detection (real, battery-independent logic bug)
`AtriaWorkoutPromptEvaluator`: `minimumSustainedSamples = 480` was used BOTH as the sustained-window
length in seconds (`sustainedStart`) AND as the required elevated-sample COUNT (`elevatedSamples >= 480`).
At ~1 Hz an 8-min window holds ≤480 samples, so it demanded ~100% elevated with zero packet loss — the
sustained path never fired on real (dropout-prone) data, so only hard zone-3+ efforts were auto-detected
(moderate walks/cardio/strength missed). Fix: decoupled the count into `minimumSustainedElevatedSamples = 300`
(~5 min of elevation, dropout-tolerant, still fail-closed). Pin migrated (test_handoff:229); 2 new tests
(fires-with-dropout at 360 samples, rejects-brief at 180). Confirmed by low-zone strap data (`z3=26s z4=0`).

### ⚠️ CONFIRMED-BUT-NOT-YET-FIXED — the lag/OOM root cause (needs a careful, detection-safe pass)
The `#1` retention roll (`rollLongWearLiveSessionIfOversized`, :9625) AND the whole long-wear supervisor
checkpoint loop (:4458) are gated on `guard longWearModeEnabled, standardHROnlyMode`. `standardHROnlyMode`
defaults **false** (:959) and full-protocol is preserved across the **entire 21:00–11:00 sleep window**
(`preserve_rr_sleep_window window=21_11`). So during full-protocol/overnight wear the four live arrays
(`session`/`rrArchive`/`sessionPointsCache`/`rrPointsCache`) are NOT bounded, and the DEFERRED `#4`
`snapshotSession` O(N) `@MainActor` rescan grows unbounded → progressive multi-second freeze + eventual
OOM jetsam. **This means `#1` (the crash fix) is effectively inert for the common overnight case.**
DO NOT just drop the `standardHROnlyMode` clause: rolling during full-protocol fragments the overnight
night into ~3h `SavedSession`s, which breaks the `sessions == 1` unambiguous sleep gate
(`isUnambiguousHROnlyMainSleepCandidate`, Sessions.swift) and the single-session wake-boundary anchor
(`evaluateWakeBoundarySleepIfUseful` uses `nightSessions.max(by:start)`) → sleep detection regresses.
Careful-pass options (design + adversarial review + CHARGED-strap verification required):
  (a) Make memory bounding mode-independent WITHOUT segment fragmentation — e.g. land `#4` (incremental
      or off-`@MainActor` `snapshotSession`) so an unbounded array no longer freezes the main thread; and/or
  (b) An unconditional trailing hard-cap on the four arrays that preserves derived counters, coordinated so
      the sleep detectors treat contiguous roll segments (≈1s gap, same wear) as one night, and the roll is
      suppressed inside the learned sleep window.
Verify by watching for `ATRIADBG live_session_retention_roll status=rolled` + no jetsam + no multi-second
ATRIADBG timestamp gaps across a real overnight on a charged strap.

### Also flagged (lower priority, from the diagnosis workflow wf_55bdefcc)
- Sleep detection currently gated (`candidates=2 ready_candidates=0 blocker=sleep_low_confidence_threshold`) —
  honesty-correct fail-closed, but partly starved by the hr-only capture confound; re-check on charged/full-protocol.
- `upsertSession` does `remove(at:)` then `insert(...)` = two `@Published sessions` mutations per checkpoint
  (Sessions.swift ~5404) → double didSet recompute + re-render; low-risk in-place-mutate win.
- Sleep foreground auto-confirm fallback only fires inside the 09:00–11:00 core when the duty-cycle window
  is unlearned (n<3 overnights) — a user checking outside that slot sees "no detection" though it's working-as-designed.
