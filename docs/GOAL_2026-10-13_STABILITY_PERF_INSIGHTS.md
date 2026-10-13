# Goal: stable build, lower background cost, sharper insights

Written 13 October 2026 from repository state `089dd6a9` (dev) and the paired
iPhone's own crash store (build 1.0 (99), app commit `1c8b5f05`, TestFlight).
Raw reports and summaries are kept privately in
`~/atria-validation/crashlogs/2026-10-13-build99/` (device identifiers inside;
do not commit them).

## 1. Where the app actually stands

### Device evidence, 6–13 October, build 99

| Report type | Count | What it says |
|---|---|---|
| `cpu_resource_fatal` (iOS killed the backgrounded app for >80% CPU over 60 s) | 23 (about 3 per day) | 20 of 23 share one heaviest stack: a serial dispatch lane → `Atria+1288024` → `+20448804` → `+18810204` → `+18730456`. Two others are a second, different stack (`Foundation+2223836` → `Atria+16247720` → `+4844004` …). One is SwiftUI/main-thread while foreground. |
| `Atria-2026-10-10` SIGKILL `0x8BADF00D` scene-create watchdog | 1 | Background (non-UI) launch. Main thread sat in `pthread_mutex_lock` inside a Swift task while the `com.adidshaft.atria.historical-archive` queue ran (`Atria+4856544` → `+3821328` → `+18321284`). App burned 10.2 s CPU before the 10 s scene-create allowance ran out. |
| `Atria-2026-10-09` SIGABRT | 1 | `NSInternalInconsistencyException` from `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]` ← `_updateStateRestorationArchiveForBackgroundEvent` ← `_updateSnapshotAndStateRestorationWithAction` ← Atria code on `com.apple.root.user-initiated-qos.cooperative`. A UIApplication call reached UIKit off the main thread from a Swift task. Most likely an `endBackgroundTask`/state-restoration path; confirm by symbolication. |
| `diskwrites_resource` | 3 | 4.29 GB of file-backed writes in 4.6 h (259 KB/s, limit is 50 KB/s over 24 h). Heaviest stack is the same serial lane → `Atria+4856544` → `+3822872` → `+17121176` → libsqlite3. |
| HangTracer `UIKit-runloop-Atria` | 42 | All dated 27 Sep–2 Oct (older, partly Debug builds). None recorded on build 99. |

Only the UIKit/libsystem frames are symbolic. No dSYM for build 99 exists on
this Mac (`~/atria-validation/dsyms/` holds seven other UUIDs; local Xcode is
27A266a, the cloud build used 27A9275, so a local rebuild will not line up).
The build-99 UUID is `B32E27A9-89AF-3D55-BFBB-967CBD269854`.

### Code facts behind those reports

- `AtriaWhoop4HistoryAdmissionLedger` opens SQLite with `journal_mode=WAL`,
  `synchronous=FULL`, `wal_autocheckpoint=256`, `temp_store=FILE`, and every
  `prune` runs `wal_checkpoint(TRUNCATE)` plus `incremental_vacuum`. Each
  admission batch is one `BEGIN IMMEDIATE … COMMIT` with a full fsync; batch
  size is whatever one MainActor turn collected, capped at 256.
- Everything heavy runs on one `historicalArchiveQueue` (13 dispatch sites in
  `AtriaBLEManager.swift`): admission, prune, projections, warm-up. The
  background CPU duty-cycle throttle (`AtriaBackgroundProjectionThrottle`)
  covers projection only; admission and prune are unthrottled.
- 135 `UIApplication.shared` call sites; 83 `NSLock` sites; 60
  `Task.detached`; 28 `.sync {` blocks. `AtriaBLEManager` is `@MainActor`, so
  any `UIApplication` call that escapes to a cooperative thread is a bug in
  a closure or `nonisolated` path, not in the type.
- Reconnect-lease breadcrumbs are written with `defaults.set` on every stage;
  each call rewrites the whole preferences plist.
- `Sessions.swift` is 62 k lines and `AtriaBLEManager.swift` 58 k lines.

### Verification state

- `python3 test_handoff_static_checks.py`: 189 tests, 81 failures + 1 error.
  This matches the pre-existing ~82 baseline; it is not a regression, but
  the gate cannot catch one either (#44).
- Open issues that this plan touches: #38 (day browsing O(1)), #44 (gate),
  #45 (runtime surfaces), #48 (UI/insights), #50 (night timeline from real
  per-minute data), #5 (trend confidence), #25 (sleep review).

## 2. Workstreams, in order

### W0 — Symbolicate before fixing (half a day)

1. Get the build-99 dSYM: Xcode → Organizer → Crashes auto-downloads it for
   TestFlight builds, or App Store Connect → TestFlight → build 99 → download
   dSYM, or the ASC API (`~/.appstoreconnect/private_keys/` has two keys; the
   issuer ID is not on disk). Archive it under
   `~/atria-validation/dsyms/B32E27A9-89AF-3D55-BFBB-967CBD269854/`.
2. `atos -o Atria.app.dSYM/Contents/Resources/DWARF/Atria -arch arm64 -l <base> <addr>`
   for the four offsets in the dominant CPU stack, the three in the disk-write
   stack, the second CPU stack, and all Atria frames in both crashes.
3. Record the symbolicated stacks in the private crash folder and in the
   memory file. Everything in W1 is ranked on these names.
4. Add a `pull_crashlogs.sh` (devicectl `--domain-type systemCrashLogs`) and
   a dSYM-by-UUID archive step to the release checklist so this never blocks
   again.

### W1 — Crash and kill elimination (highest value)

Acceptance for the whole workstream: a 48 h soak on the physical iPhone
with the strap worn, phone locked most of the time, one gym gap, one charge
window, then `pull_crashlogs.sh` shows **zero** `cpu_resource_fatal`,
`0x8BADF00D`, SIGABRT, or `diskwrites_resource` reports for the new build.

1. **Off-main UIApplication call (SIGABRT, Oct 9).**
   Audit every `UIApplication.shared` site reachable from
   `historicalArchiveQueue` completions, `Task.detached`, and `nonisolated`
   methods. Route all background-task begin/end through one `@MainActor`
   lease owner (the pattern `AtriaWorkoutRouteBackgroundLease` already uses).
   Add `MainActor.assertIsolated()` in Debug at each lease end, plus a static
   check that no `UIApplication.shared` appears inside a `Task.detached` or
   queue `.async` closure.

2. **Scene-create watchdog (Oct 10).**
   Find the `NSLock` the main thread waits on during a background launch
   while the archive queue holds it (symbolication names it). Rule: the main
   thread never blocks on an archive-side lock; it reads a published
   immutable snapshot, or `try`-locks and falls back to the last snapshot.
   Move the background-launch bootstrap (ledger open, catalog load, first
   projection) entirely off the main thread and make `scene(_:willConnectTo:)`
   finish in under 1 s of CPU. Regression test: a background launch with a
   100 MB archive completes scene setup without touching the archive lock.

3. **Background CPU budget (23 kills).**
   One background work scheduler for drain admission, prune, projections,
   rollups, HealthKit export and motion replay, sharing a single CPU token
   with a duty cycle that keeps the process under ~50% CPU averaged over
   60 s while backgrounded. Admission pages yield between batches; prune never
   runs inside a drain slice; the second stack (Foundation-thread based) gets
   its own cap once named. Instrument with `os_signpost` and the existing
   `history_flush_timing` log so the soak can prove the budget.

4. **Disk writes (4.3 GB / 4.6 h).**
   In the ledger: keep WAL, move to `synchronous=NORMAL` (crash-safe for app
   crashes; only a power loss can lose the last un-checkpointed commits, and
   un-ACKed records are re-served by the strap), raise
   `wal_autocheckpoint` to ~4096 pages, use `PASSIVE` checkpoints in prune
   and reserve `TRUNCATE` + `incremental_vacuum` for the once-a-day
   charging-window maintenance. Batch admissions to at least 64 frames when
   the drain is in catch-up. Move reconnect-lease breadcrumbs out of
   `UserDefaults` into the existing breadcrumb file writer. Target: under
   40 KB/s averaged over a day with a 1 Hz drain running.

5. **Hang guard on Release.** Build 99 shows no HangTracer entries; keep it
   that way with an `AtriaMainThreadWatchdog` (Debug/TestFlight) that logs any
   main-thread stall over 250 ms with a stack, so a regression shows up in
   the soak log instead of in a user's hand.

### W2 — Performance the user feels

1. **#38 Today day browsing O(1).** Leaf owner for the selected day, keyed by
   civil-day identity, resolved from `DailyRollupStore.rollup(for:)`; per-day
   persisted presentation records instead of the whole-array JSON rewrite.
   Acceptance is the issue's own: p95 ≤ 50 ms per day change, ten rapid taps
   move exactly ten days.
2. **Tab switch and detail-sheet open p95 ≤ 100 ms** on a 30-day populated
   device. Extend the "skip rebuild when no input changed" rule from Home
   (`540b30bd`) to Vitals, Sleep and Activity screens; content-keyed memos
   for chart series.
3. **Storage stays bounded.** Verify on device that compaction is no longer
   `lease_denied exact_recovery` after `636099ab`; Documents size, ledger size
   and WAL size pulled before and after the soak must be flat.
4. **Build and test speed.** Extract pure reducers from `Sessions.swift` into
   their own files (no behaviour change) so unit targets compile and run in
   minutes, not tens of minutes. Only after W1 lands.

### W3 — Better insights (what the user reads every morning)

Rules that stay: hue only for data/state; fewer words, never fewer charts;
one Ready / Calculating / Syncing status; no "low confidence" labels; n=1
labelled as personal baseline; nothing shown as a fact that the data cannot
support.

1. **Recovery drivers.** Under the recovery ring, one line per driver
   (HRV, resting HR, sleep hours, sleep consistency, yesterday's strain) with
   its deviation from the personal 28-day baseline and an arrow. Tap → the
   existing provenance card. This is the "why" behind the number, not a new
   number.
2. **Trend change detection (#5).** 7-day vs 28-day shift test (Welch, same
   gate as the tag insights) for HRV, resting HR, respiratory rate, sleep
   hours. Surfaces only when it passes; says "Resting HR up 4 bpm this week"
   and nothing more.
3. **Sleep debt and tonight's window.** Use the shifted schedule (circular
   bedtime stats from #41) to show sleep debt over 7 days and a one-line
   bedtime window that respects the user's own typical bedtime, not the clock.
4. **Strain remaining.** "Strain 9.1 of 13 target, usually reached by 21:30"
   using the cycle's own pacing history; replaces guesswork about the
   target notch.
5. **Weekly report upgrade.** The three tag effects that survived correction
   this week, the drivers above, and the week's sleep debt. Same deck
   component as Learnings; no new surface.
6. **Night timeline from real per-minute data (#50).** Feed the hypnogram and
   baselines from the minute builder rather than summaries, so the morning
   detail agrees with the chart.

### W4 — Features worth adding now

1. **Sync & storage health screen.** The diagnosis JSON from #45 becomes a
   user-visible page: strap link state, drain backlog in hours, last sync,
   storage used vs ceiling, last background run, and the last kill reason if
   any. This is the self-diagnosis the app owes the user and the first thing
   support will ask for.
2. **Sleep review flow (#25).** Confirm / Adjust / Dismiss on the review row,
   with the persisted state matching the surface; late resumed sleep shown.
3. **HealthKit writes for sleep and workouts** (HRV stays gated by #6).
   Export is already coalesced; add the two sample types and a readback
   check in Settings.
4. **Journal tags with `expectedEffect`**: caffeine after 14:00, late screen,
   sauna, cold exposure, illness. Each new tag gets its effect class and the
   pinned test.
5. **Shortcuts / App Intents**: "What's my recovery", "Start walk", "Log
   tag" — the intents file exists; expose the three the Today deck already
   computes.

### W5 — Verification that can catch regressions (#44)

1. Classify the 82 static-gate failures: stale pins (update), dead checks
   (delete), real defects (fix). Target: 0 failures on dev, then the gate
   becomes required for the dev → main PR.
2. Keep the 290 focused unit/regression tests green; add the W1 regression
   tests to the gate.
3. Every release build: dSYM archived by UUID, crash logs pulled after each
   soak, summary appended to the private crash folder.

## 3. What not to do

- No new strap opcode or alternate `6A` start TX; compact IMU recovery stays
  closed (GROK plan, decision M).
- Steps stay strap-only; no iPhone pedometer fallback.
- No confidence labels, no owner-only constants, no prose added to charts.
- No distribution archive from a beta macOS build machine.
- Announce each device action before running it; one device task at a time.

## 4. Goal prompt (paste into the next session)

```
You are continuing Atria (iOS, WHOOP 4.0 strap over BLE, SwiftUI, repo /Users/amanpandey/projects/atria, branch dev).
Goal: make the app stop crashing and getting killed, cut its background cost, and make the morning insights sharper. Work through docs/GOAL_2026-10-13_STABILITY_PERF_INSIGHTS.md in order W0 → W1 → W2 → W3 → W4 → W5. Do not skip W0.

Ground truth first. The paired iPhone (devicectl id in $ATRIA_DEVICE_ID) holds the evidence: build 1.0 (99), UUID B32E27A9-89AF-3D55-BFBB-967CBD269854, produced 23 cpu_resource_fatal kills, one 0x8BADF00D scene-create watchdog (main thread blocked on a mutex while the historical-archive queue ran), one SIGABRT (UIApplication reached off the main thread from a Swift task), and three diskwrites_resource reports (4.3 GB in 4.6 h, SQLite on the archive queue) between 6 and 13 October. Copies and summaries are in ~/atria-validation/crashlogs/2026-10-13-build99/. No dSYM for build 99 is on this Mac. Obtain it (Xcode Organizer → Crashes, or App Store Connect → TestFlight → build 99), archive it under ~/atria-validation/dsyms/<UUID>/, symbolicate every Atria frame in those reports with atos, and write the named stacks down before changing code. If you cannot get the dSYM, say so and ask the owner for the App Store Connect issuer ID; do not guess function names from offsets.

Then fix in this order, each with a regression test and a device-verified receipt:
1. Off-main UIApplication calls: one @MainActor lease owner for every beginBackgroundTask/endBackgroundTask; MainActor.assertIsolated in Debug; a static check that no UIApplication.shared sits inside Task.detached or queue .async closures.
2. Scene-create watchdog: the main thread never blocks on a lock the historical-archive queue can hold; background-launch bootstrap runs entirely off the main thread; scene setup finishes under 1 s CPU on a 100 MB archive.
3. Background CPU: one scheduler and one CPU token for admission, prune, projections, rollups, export and motion replay; under ~50% CPU averaged over 60 s while backgrounded; os_signpost instrumentation so the soak proves it.
4. Disk writes: ledger to synchronous=NORMAL with WAL, wal_autocheckpoint ~4096, PASSIVE checkpoints in prune, TRUNCATE + incremental_vacuum only in the daily charging-window maintenance, admission batches ≥64 frames during catch-up, reconnect breadcrumbs out of UserDefaults. Target under 40 KB/s averaged over a day.
5. A main-thread watchdog that logs any stall over 250 ms with a stack in Debug/TestFlight builds.

Acceptance for W1 is a 48 h worn soak (locked phone most of the time, one gym gap, one charge window) after which a fresh crash-log pull shows zero cpu_resource_fatal, 0x8BADF00D, SIGABRT or diskwrites_resource for the new build, and Documents/ledger/WAL sizes are flat. Only then start W2 (#38 day browsing O(1), tab-switch p95 ≤ 100 ms, bounded storage), W3 (recovery drivers, trend change detection, sleep debt with the shifted schedule, strain remaining, weekly report, #50 night timeline), W4 (sync & storage health screen, #25 sleep review, HealthKit sleep/workout writes, new journal tags with expectedEffect, three App Intents) and W5 (bring the static gate to 0 failures and make it required).

Rules that do not bend: hue only for data and state; fewer words, never fewer charts; one Ready/Calculating/Syncing status everywhere; no confidence labels; personal baseline labelled as n=1, no owner-only constants; steps are strap-only; no new strap opcode or 6A start TX; no distribution archive from a beta macOS machine; announce every device action before running it and run one at a time; commit only when asked. Run the focused unit tests and python3 test_handoff_static_checks.py before every device install and diff the failure set against the ~82 baseline; a new failure is yours. Keep a dated memory note of what the symbolicated stacks named and what each fix proved on device.
```
