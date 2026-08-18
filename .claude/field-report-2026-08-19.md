# Atria field-report loop — 2026-08-19

User ran the shipped build 3–4 days and filed 15 items. This is the working ledger.
**Every loop iteration: read this first, pick the next NEXT item, update before the turn ends.**

Device: Aman's iPhone `3803F5B6-1666-56D3-A71A-62F131F6CE3B`, bundle `com.adidshaft.atria`.
Branch: `codex/whoop-remaining-product-gaps`.

---

## Device evidence captured 2026-08-19 01:57 IST (scratchpad `.../scratchpad/pull/`)

### A. LIVE STALL — root cause of items 1, 2, 3 (and starves 6, 7, 10)

Defaults timeline from `com.adidshaft.atria.plist`:

| when | key | value |
|---|---|---|
| 08-18 21:22:38 | `offlineSync.drainedThroughUnix.v1` | **this is the "9:22pm" the user sees** |
| 08-18 21:42:07 | `offlineSync.handshakeStatus.v1` | `history_first_frame_received` |
| 08-18 21:42:50 | `activeJournal.lastClose.reason` | `workout_start_boundary` (the Strength workout) |
| 08-18 21:56:24 | `rangeLossBackfillStartedAt` | reason `long_wear_range_loss` |
| 08-18 21:56:32 | `sample.lastRawNotificationAt` | **LAST HR SAMPLE — 4.0 h before now** |
| 08-18 21:56:33 | `offlineSync.backgroundLeaseStatus.v1` | `terminal_fresh_accepted_hr_ble_disconnect` |
| now (01:57) | `watchdog.lastRawGap` | **14474.9 s = 4.02 h**, `lastStatus=stale` |
| now | `keepalive.lastStatus` / `lastRawNotificationDelta` | `silent` / `0` |
| now | `keepalive.stallReconnects` | **323** |
| now | `link.lastStatus` | `connecting` |
| now | `link.lastDisconnectCause` | `atria_cancel:hr_continuity_background_all_gatt_silent_rebuild` |
| now | `keepalive.lastAction` | `rediscover_2a37_service` |
| now | `ble.lastConnectedDuration` | 92.75 s |

`persistedDrainRearmDiagnostic = link=1 fresh=0 workout=0 sync=0 materializing=0 authority=gapResolvedConsumersPending defer=0`

**Diagnosis:** the link reconnects fine (link=1, ~92 s per attempt) but **no GATT notification ever
arrives after the rebuild** (fresh=0, delta=0). The app detects "all gatt silent", cancels, rebuilds —
323 times over 4 h — and never recovers on its own. Everything downstream (HR freshness, sync clock,
workout HR, step/motion offload, nap+stage inputs) is starved by this one loop.

Also pending, older: `lastDrainFailure.v1 = protocolViolation("history_sequence_gap_replay_mismatch_expected_44057_received_57618")` (08-18 02:08),
`lastStatus = gap_retained_transaction_unverified`, `terminalArchiveFailureDiagnostic.v1 = …publicationCheckpointMissing` (08-14).

### B. STORAGE — item 12 CONFIRMED and precisely attributed

Container total **5.45 GB / 3048 files**. Data spans **2026-07-12 → 08-18 (5+ weeks, not 4–5 days)**.

| MB | files | path | note |
|---|---|---|---|
| 2986.5 | 686 | `atria-historical/segments/raw-*.jsonl` | **UNCOMPRESSED**, 32 MB each, 07-19→08-18, never pruned |
| 1290.2 | 1 | `atria-historical/historical-archive.identity.jsonl` | single unbounded dedupe ledger |
| 839.7 | 1 | `…identity.lookup-v1.sqlite` | index over the same |
| 128.0 | 1 | `atria-historical/historical-archive.jsonl` | |
| 92.9 | 227 | `aggregates-v2` | insight-tier — keep |
| 33.2 | 321 | `full-fidelity-cold-sessions-v1` | already `.gz` |
| 32.7 | 351 | `hr-index-v1` | |
| 13.5 | 1 | `Documents/sessions.json` | |
| 11.4 | 3 | `atria-backups/*.gz` | 3.8 MB × 3 |
| 17.0 | ~15 | `Documents/atria-memprobe*.log` + `tmp/*.png|html|gpx` | debug/share leftovers, never cleaned |

**≈ 4.3 GB (79 %) is raw + dedupe bookkeeping.** Insight tier (`aggregates-v2` + rollups + daily-metrics)
is only ~93 MB — so raw-tier retention can be cut hard without touching what the user reads.

`historical-archive.manifest.json` says `rotationThresholdBytes: 134217728` (128 MB) but raw files rotate at 32 MB.

---

## Item status

| # | Item | Status | Note |
|---|---|---|---|
| 1 | HR lags, catches up on foreground | **FIX WRITTEN** (C) | silent-GATT rebuild loop |
| 2 | Stuck "waiting", last sync 9:22pm | **FIX WRITTEN** (C) | needs device soak to prove |
| 3 | Workout HR not syncing | **FIX WRITTEN** (C) | journal closed at `workout_start_boundary` 21:42, stall began 21:56 |
| 4 | Rings vanish at midnight | TODO | want: hold prior physiological day until night sleep completes |
| 5 | Duplicate sleep recommendation after stop/save | TODO | |
| 6 | Nap detection dead (2–3 h evening nap missed) | TODO | starved by A? verify independently |
| 7 | Steps distrust | TODO | |
| 8 | Stress reads low | TODO | |
| 9 | Sleep-view stress vs general stress disagree (pinned 3/high) | TODO | |
| 10 | Sleep stages not working | TODO | |
| 11 | Notifications never fire at the right moment | TODO | `notification.sleepEvent.lastKind=morning_summary`, `lastDay=2026-08-18` |
| 12 | 5 GB+ data size, need raw/insight retention tiers | **DIAGNOSED** (B) | |
| 13 | Insight→suggestion engine | TODO | |
| 14 | Rings cropped in scroll-up floating overlay | **FIXED** (D) | |
| 15 | Anything else | ongoing | |

---

## C. Items 1/2/3 root cause — the silent-stream central-rebuild latch self-locks

`AtriaBLEManager.forceHardReconnectForPacketStall` guarded the wedged-session escape with a
**boolean latch** `silentStreamCentralRebuildIssued`, set when a replacement central was issued and
cleared in exactly one place — `completePostReconnectStreamRecoveryIfNeeded()`, i.e. **only on a fresh
accepted HR sample.**

A wedged bluetoothd session is precisely the state in which no accepted sample can arrive. So the
first replacement that fails to revive the stream latches the permit ON forever, and every later
request hits `status=central_rebuild_coalesced action=await_fresh_hr` and returns — a total no-op that
also skips `lastStallHardReconnectAt` and `preserveLongWearRangeLossRecovery`. The soft
cancel/reissue lane keeps running (that is the 323 `stallReconnects`, ~92 s of connection each) but the
one recovery that actually clears a wedged XPC session is permanently suppressed. Hence 4.0 h silent.

This is the *same* self-lock class the code comment at `AtriaBLEManager.swift:4550` documents and fixes
for the repair **budget** (`shouldRestoreSilentStreamRepairBudget`, rate-limited refill). The latch was
simply never given the same treatment.

**Fix (applied):** replaced the boolean with `silentStreamCentralRebuildIssuedAt: Date?` plus
`shouldReissueSilentStreamCentralRebuild(lastIssuedAt:now:retryInterval:)`, mirroring the budget
predicate. Coalescing still absorbs the burst of watchdog ticks right after one replacement — the only
thing it was ever needed for — but a genuinely quiet interval re-arms the permit.
`silentStreamCentralRebuildRetryInterval = 10 min` (heavier than the 5-min budget refill; the guard only
applies while the peripheral reads `.connected`, so it cannot spin against ordinary out-of-range).
Fails open on a backwards clock.

Files: `Atria/Atria/AtriaBLEManager.swift` (decl ~4898, guard ~19062, issue ~19085, clear ~24216),
test `Atria/AtriaTests/AtriaBLERecoveryCadenceTests.swift` (source-pin updated + new behavioural test
`testSilentStreamCentralRebuildPermitReArmsAfterAQuietInterval`).

## D. Item 14 — cropped rings in the floating overlay

`AtriaTodayCompactTriRing` (AtriaTodayScreen.swift): `Circle()` inscribes in the 64×64 frame and
`.stroke(lineWidth: 5)` straddles the path, so 2.5 pt falls outside the frame. The hero ring gets away
with it (SwiftUI does not clip to bounds) but this rail rasterizes through `.drawingGroup()`, whose
offscreen buffer is exactly the view's bounds — the outermost ring lost its outer 2.5 pt. Fixed by
insetting every ring by half the line width.

---

## Done this loop
- **C**: silent-stream central-rebuild latch → interval-bounded permit (items 1/2/3). Test added.
- **D**: compact tri-ring stroke inset (item 14).
- Ledger + full device evidence capture.
- *(uncommitted; focused test run in flight)*

## NEXT
1. Confirm the focused test run is green, then commit C + D.
2. Item 12 retention tiers — raw `segments/raw-*.jsonl` are uncompressed and never pruned (2.99 GB),
   and `identity.jsonl` + its sqlite are 2.13 GB of unbounded dedupe bookkeeping. Insight tier is only
   ~93 MB, so a raw-retention window + compaction is safe. Also: `atria-memprobe*.log` (17 MB) and
   `tmp/*.png|html` share leftovers are never cleaned.
3. Item 6 nap detection — verify independently of the stall (the evening nap fell inside the 4 h dead
   window, so it may be starved rather than broken; prove which).
4. Items 8/9 stress, 10 stages, 5 duplicate sleep prompt, 11 notification timing, 4 midnight rings.

## Standing note
`offlineSync.rangeLossBackfillPending = true` since **2026-08-06** (13 days).
`scheduleStaleArmedRangeLossBackfillReconciliation` only clears statuses in
`["armed","archived","archive_metric_ready","throttled","no_rows"]`, but the live status is
`gap_retained_transaction_unverified` — so the reconciliation can never fire. Separate defect, worth
its own pass.
