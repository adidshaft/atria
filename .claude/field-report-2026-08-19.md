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
| 4 | Rings vanish at midnight | **FIXED** (N) | `7bd0dabd`; 18 h waking hold, incident fixture still refused |
| 5 | Duplicate sleep recommendation after stop/save | **FIXED** (R + S) | notification cap per episode; confirmed nights no longer extendable |
| 6 | Nap detection dead (2–3 h evening nap missed) | **STRUCTURAL FIX PROVEN, STILL BLOCKED** (I + U) | passive requalify now fires (proven 04:04); strap fails `clean_owner_proof_disconnect` in 5 s, imu still 0 |
| 7 | Steps distrust | **FIXED** | app dropped the `≥` the widget still showed; restored |
| 8 | Stress reads low | **FIXED** (W) | `6bb48d8b`; scoring v4 anchors on the learned awake reference; simulated 65.6/29.6/4.9 over 130k real samples |
| 9 | Sleep-view stress vs general stress disagree (pinned 3/high) | **FIXED** | full scale was rest+14 vs a SLEEPING baseline; rebanded |
| 10 | Sleep stages not working | **PARTLY FIXED, STILL BLOCKED** (I + gate B + U) | gate B fixed; motion retry now fires but proof still disconnects — stages stay fail-closed |
| 11 | Notifications never fire at the right moment | **4 of 5 FIXED** (T+Z+AF+AG) | workout un-silenced, background discovery, redundant-banner suppression, event-bound review delivery; only (5) nap push open (blocked on motion) |
| 12 | 5 GB+ data size, need raw/insight retention tiers | **PARTS 1 + 3 FIXED** (L + Y) | 2.13 GB dedupe tier (`32f4e598`); fence lifted + 30-day raw horizon; part 2 (compression) DROPPED on evidence (P) |
| 13 | Insight→suggestion engine | **INPUT FIXED + FIRST ENGINE UNBLOCKED** (AB + AH) | restingHR no longer erased; whiteboard coach now guides from a mature resting band instead of waiting forever on HRV |
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

## E. LIVE RE-CHECK 02:06 IST — stall still running, and it confirms C exactly

Re-pulled the defaults 9 minutes after the first capture. `lastRawNotificationAt` is **unchanged**
(08-18 21:56:32, now 4.17 h), `watchdog.lastRawGap` grew 14474 → **15006 s**, `stallReconnects` 323 →
**328**, `lastRawNotificationDelta` still **0**. Crucially:

- `link.lastStatus = connected` — the peripheral really is `.connected`
- `watchdog.lastAction = rebuild_all_gatt_silent` — the watchdog **is** requesting the replacement

So `replaceWedgedSession = immediateConnectedRebuild && target.state == .connected` evaluates **true**
on every tick, the request reaches the latch, and the latch swallows it. That is the C mechanism
observed live rather than inferred. The shipped build cannot escape this state on its own.

## F. Installed 47538c32 to the phone at 02:11 — and an honesty caveat about what that proves

Device Release built clean (0 errors) and installed. Binary proof the fix is really in it (guards
against the known stale-incremental-build trap): the mangled symbol
`_$s5Atria0A10BLEManagerC34silentStreamCentralRebuildIssuedAt…10Foundation4DateVSgvp` is present, and
`strings` finds the new `ATRIADBG ble_link status=central_rebuild_coalesced reason=%@ issued_age_s=%.0f`
log line. The old boolean is gone.

**Caveat — the relaunch is NOT proof of the fix.** `silentStreamCentralRebuildIssuedAt` (like the
boolean before it) is a process-local `var`, not persisted. So *any* process death clears it, and the
install necessarily killed the stuck process. Tonight's recovery would therefore have happened on the
old build too. What the 4 h stall actually proves is that the app survived 4 h *without* dying — which
is the normal case — and could not self-heal in that whole window.

The real acceptance evidence is a **future** connected-and-silent episode that self-recovers within
~10 min with no relaunch: look for `central_rebuild_coalesced … issued_age_s=` followed by a
`post_connect_repair=action_central_rebuild` at age >= 600, and `sample.lastRawNotificationAt`
advancing afterwards. Do not mark items 1/2/3 accepted before that trace appears.

## G. Recovery confirmed 02:14 — plus two measurements that matter for other items

After the install+launch, HR resumed immediately and `stallReconnects` froze at 331 (no more thrash):

```
02:14:00  lastHR=02:13:44  keepalive=history_transport_owned  drainedThrough=08-18 21:22
02:19:04  lastHR=02:18:28  keepalive=history_transport_owned  drainedThrough=08-18 21:34
```

**G1 — measured drain rate. CORRECTED at 02:57: the sustained rate is 1.53x, not 2.37x.** The first
5 min after relaunch advanced 12 min of history (2.37x) — a transient burst. Over the following
38 min the frontier moved 21:34 -> 22:32, i.e. 58 min of history in 38 min of wall clock = **1.53x**,
which matches the prior CP2 convergence figure (1.148x). Net closure is therefore only
**0.55 min/min**, and the 4.4 h backlog converges around **10:54**, not 05:47.  is the hard consequence of the WHOOP 4 having no seek: at 1.53x, **every hour of outage costs
~1.9 h of catch-up.** That is the real, measurable content of item 1 ("catches up eventually") and it is also
why items 6/7/10 look dead during and after any outage — their inputs are simply behind the frontier.
Any retention or drain work should treat 2.37x as the budget.

**G2 — RR IS present. Do not chase an "RR absent" theory.** The poll printed
`watchdog.lastAction = observe_active_2a37_rr_absent`, but that is the *shared* watchdog-recovery key,
last written by the rr-presence lane during the reconnect. The RR-specific record, stamped 02:18:34
once the link was healthy, says the opposite:

```
rrPresence.status               = rr_present
rrPresence.action               = observe_real_rr_0x2A37
rrPresence.lastPacketRRFlagPresent = True
rrPresence.rrValues             = 211      rrGap = 5.98 s
rrPresence.lastPacketContactSupported = False
```

So the strap does deliver RR on a healthy link. Items 8/9/10 must be explained by something
downstream of RR capture, **not** by missing RR. Worth reconciling against `hrv.lastReadyAnalysisAt`
being stuck at 2026-08-11 (8 days) while RR is flowing — that gap is itself a lead, and it now points
at the HRV *analysis* gate rather than at the sensor.

## H. USER DECISIONS (asked 2026-08-19, answered)

1. **HR-only estimates for naps/stages: NO — "investigate why motion is dead first."**
   Do not flip `allowHROnlyEstimate` on by default. Treat pure-HR mode as the bug. (Done — see I.)
2. **Retention: "Full tiering — prune raw past 30 days."** Lift the release fence, bound the dedupe
   ledger, compress raw, retire raw older than 30 days once aggregates/hr-index are sealed.

## I. WHY MOTION IS DEAD — the real cause of items 6 and 10

Motion died **2026-08-13 07:10:09** and never came back. 5.8 days later `protocol.imuFrames = 0`,
`protectedR10.cleanOwnerState = fallback_active`, `cleanOwner = pure_hr_v8`, `streamSuppressed = true`,
`cleanOwnerFailureReason = clean_owner_proof_disconnect`.

The chain:

1. 08-13 06:22:16 `requalifyAttemptAt` -> 06:22:45 `activationSentAt` -> **07:10:09 `fallbackAt`**.
   The clean-owner proof disconnected, so R10 fell back to pure-HR. That part is by design.
2. The ONLY escape is `prepareProtectedR10CleanOwnerAtLaunch(allowFallbackRequalification:)`, and the
   sole production caller (AtriaBLEManager.swift:5784) passes `explicitWorkoutNeedsMotion`. In Release
   `gate4StationaryQualificationRequested` is hard-`false` (`#else` branch), so that reduces to
   `explicitWorkoutIntentActive` — **an explicit manual workout intent that must already be active at
   process launch.**
3. Ordinary all-day wear never sets it. So a pure-HR fallback is **terminal for passive use**, despite
   the v10 branch's own comment calling it "a recoverable degradation".
4. `requalifyAttemptAt` still read **2026-08-13 06:22 — 48 minutes BEFORE the fallback**. Not one
   requalification attempt in 5.8 days, against 548 `workoutMotion.activationAttempts`.
5. The one workout the user did start (08-18 Strength) could not rescue it either:
   `workoutMotion.status = r10_step_lease_revoked_history_owner` — the single shared BLE transport was
   held by the chronically backlogged history drain.

Naps and sleep stages are both hard-gated on validated motion, so **both were structurally unreachable
for the entire usage window**. Items 6 and 10 are one upstream defect, exactly as the user suspected.

**Fix (applied):** `protectedR10FallbackShouldPassivelyRequalify(...)` +
`protectedR10PassiveRequalifyInterval = 12 h`, OR-ed into the launch gate. Keeps every safety property
the workout path relies on — still launch-only (never mutates stream-5 CCCDs on a live pure-HR link),
still demands the same prior physical-qualification credential — and only removes the requirement that
a human happen to start a workout. Bounded to one attempt per 12 h so an incapable strap never churns
the radio. Fails open on a backwards clock.

## J. Item 12 — precise mechanism for the 2.13 GB dedupe ledger (scoped, not yet fixed)

A 14-day identity retention policy already exists
(`AtriaHistoricalArchiveDurableStore.productionIdentityRetention = 14 * 24 * 60 * 60`) and
`pruneExpiredIdentitiesLocked` computes the expired set correctly. It cannot act on it:

```swift
guard fullyMaterializedIdentityIndex else {
    for key in expired { statesByKey.removeValue(forKey: key) }   // in-memory ONLY
    return max(lookupRemoved, expired.count)
}
... try rebuildDerivedIndex(with: retained.values.map(\.entry))   // the only file rewrite
```
(AtriaHistoricalArchiveDurableStore.swift:760-772)

`rebuildDerivedIndex` is the ONLY path that rewrites `identity.jsonl`, and it needs the whole index in
memory — which is precisely what the store refuses once the file is too large to materialize.
**Chicken-and-egg: the file is too big to load, so it can never be shrunk.** That is the 1.29 GB.

The 840 MB sqlite is a separate mechanism: `liveIdentityLookup.prune(observedBefore:)` IS called, but
SQLite `DELETE` only frees pages inside the file — without a `VACUUM` the file never shrinks. 840 MB
under a 14-day policy is the signature of delete-without-vacuum.

**Both fixes are independent of the archive-wide release fence:**
1. Streaming compaction of `identity.jsonl` — read line-by-line with the existing 64 KiB reader, keep
   `observedAtUnix >= cutoff`, write temp, atomic `replaceItemAt` (the same move `rebuildDerivedIndex`
   already makes). Bounded memory, so it is legal in the bounded-cold-lookup state.
2. Periodic `VACUUM` after a prune that actually removed rows.

## K. Item 12 — the release fence is NOT stale; its stated reason still holds

`shouldExecuteArchiveWideMaintenance` is `{ explicitDebugOverride }` (Sessions.swift:25645-25648) and
its comment says the graph "still contains composite readers/publishers whose individual inner loops
cannot all be revoked atomically". **Verified: `HistoricalArchive.swift` contains ZERO occurrences of
`checkpoint()`, `isCancelled`, `CooperativeDeadline` or `workCounter`** — the instrumentation exists
elsewhere in the codebase (Sessions.swift has 453 uses) but not in the retention graph. So the fence
is honest, and lifting it is gated on real work: threading a cooperative deadline through
`HistoricalArchive.compactArchiveConverging` (HistoricalArchive.swift:9835) and its inner scans.

Mitigating: interruption is not a corruption risk. `AtriaHistoricalRawRetirementExecutor` is
intent-logged with `recoverFirstPendingIntent` (HistoricalArchive.swift:9380) and a committed
`AtriaHistoricalRetentionTransaction` manifest is the only proof a raw file may be retired. The risk of
an uninstrumented lift is BGTask expiry / CPU-overrun termination, not data loss.

**Sequencing for the user's "full tiering" choice:** J1 + J2 first (2.13 GB, no fence involvement),
then raw compression, then thread the cooperative deadline, then lift the fence and prune raw > 30 d.

## L. Item 12 part 1 IMPLEMENTED — the 2.13 GB dedupe tier (no fence involvement)

Three defects, all fixed. The third was not in the workflow's findings; it fell out of reading the
prune path directly and is the reason retention never ran even BEFORE the file got too big.

**L1 — `identity.jsonl` could never shrink (1.29 GB).** `pruneExpiredIdentitiesLocked` bailed to an
in-memory-only removal whenever `!fullyMaterializedIdentityIndex`, and `rebuildDerivedIndex` — the only
path that rewrites the canonical JSONL — requires full materialization. Too big to load, therefore too
big to compact, therefore bigger still. Added
`compactIdentityIndexOutsideHorizonLocked(cutoff:protectedKeys:)`: single-pass, 64 KiB buffered,
constant memory, so it is legal in exactly the state that used to be terminal. Keeps every line at/after
the cutoff plus every key held by an open drain batch; **an unparseable line is RETAINED**, never
silently deleted by a maintenance pass. Same crash-safety contract as `rebuildDerivedIndex`
(temp -> fsync -> atomic replace -> fsync dir). No per-key dedupe on purpose: readers already resolve
duplicates by newest `observedAtUnix`, and once the file drops under the 8 MiB eager threshold the next
launch materializes and dedupes for free.

**L2 — the SQLite lookup never gave bytes back (840 MB).** `prune` issued a `DELETE` and stopped.
SQLite frees pages inside the file; without a vacuum the file never shrinks. Both siblings
(`AtriaWhoop4HistoryAdmissionLedger`, `AtriaHistoricalRetiredReplayIndex`) already handled this — this
one was missed. Added `PRAGMA auto_vacuum=INCREMENTAL` at open, plus `compact()`:
`wal_checkpoint(TRUNCATE)` + a bounded `incremental_vacuum(128)`, escalating to a one-time full `VACUUM`
when `auto_vacuum` is off and >= 25 % of pages are on the free list — the exact 840 MB case, since
`incremental_vacuum` is a no-op on a database that predates the pragma. VACUUM is a crash-safe SQLite
transaction, and this store is rebuildable and never authorizes ACK, so the worst case is wasted work.

**L3 — the retention clock measured process UPTIME, not wall clock.** `lastPruneAtUnix` was a
process-local var seeded with `now()` at construction, and the maintenance hook fires at
`now - lastPruneAtUnix >= 6 h`. iOS restarts apps far more often than every six hours, so the prune
never came due at all. **Third instance of this exact defect class today** — after the silent-stream
rebuild latch (C) and the pure-HR requalification gate (I). Now persisted to a `prune.json` sidecar and
re-seeded at init; a forward-dated marker falls back to the caller's clock so a clock correction or a
device restore cannot park retention forever.

Files: `AtriaHistoricalArchiveDurableStore.swift`, `AtriaHistoricalLiveIdentityLookup.swift`,
tests in `AtriaHistoricalArchiveDurableStoreTests.swift` + `AtriaHistoricalLiveIdentityLookupTests.swift`.

## M. Item 12 part 2 — the "compressed cutover" has NO production caller at all

`AtriaHistoricalSealedJSONLCompression` is complete and well-tested: bounded-memory deflate,
byte-preserving, with a manifest that keeps the original byte identity (used by replay and aggregate
receipts) separate from the physical compressed identity, plus catalog publication and
`verifyCompressed`. The prior work is real.

It is also entirely unreachable in production. Its single entry point is
`commit(chunkID:)` (AtriaHistoricalSealedJSONLCompression.swift:90), and across the whole repo:

```
commit(chunkID:)                          1 decl in the type itself, 3 calls — ALL in tests
AtriaHistoricalSealedJSONLCompression(…)  17 instantiations — ALL in AtriaTests/
```

Zero production files construct it or call it. That is exactly why the device holds 686 plain
`raw-*.jsonl` files totalling 2.99 GB while `compressed-raw-v1/` does not exist on the device at all
(it is absent from the 3,248-file container listing). The compression is a finished component that was
never wired to the archive lifecycle.

Wiring it is the part-2 work: seal -> compress -> publish the manifest into the catalog -> only then
remove the plain file, which is the ordering the type's own doc comment mandates
("Production callers must publish that mapping in the archive catalog before authorizing removal of
the plain file"). Note this is storage substitution, NOT retirement — it needs no retention horizon and
no release-fence lift, so it is independent of part 3.

## N. Item 4 FIXED — and the workflow's proposed fix would have reintroduced the incident

The verified root cause was right: `AtriaCurrentDayPresentation.resolve` gates on CIVIL-day equality and
never consults the `cycleEnd` it is handed (it appears only in the two identity constructors). At 00:00
the displayed civil day advances, the anchoring wake's day does not, `sourceIsToday` flips false, and
the fall-through returns terminal awaiting states — blank rings, mid-evening, with no new evidence.

**But the proposed fix — `let cycleIsLive = cycleEnd.map { now < $0 } ?? false; if cycleIsLive … return
primary` — is wrong and I did not ship it.** The Aug-12/13 incident fixture this file exists to prevent
is `now` = 14:43 the NEXT day against `cycleEnd` = wake + 24 h + 30 min, i.e. **`now < cycleEnd` is TRUE
in the incident**. That fix would have restored the exact lie (yesterday's 92 / 9h12 / 3.3 worn as
today's) that Handoff-10 CP1 was built to stop.

What actually separates the two cases is **elapsed waking time, not the rollover**:
- 00:30 after an 08:00 wake = 16.5 h awake → the night simply has not happened yet. Hold.
- 14:43 after a 15:27 wake = 23.3 h awake → the night has been and gone. Do not hold.

Shipped: new `.currentCycleAcrossMidnight` value state + `maximumWakingDayHeldAcrossMidnight = 18 h`.
The live cycle stays PRIMARY across civil midnight while `anchorSleepID != nil`, the clock runs forward,
`now < cycleEnd`, and the wearer has been awake under 18 h. Past that it falls through to exactly the
previous behaviour. The identity keeps `sourceCivilDay` on the CYCLE's day and `priorCycle` populated,
so the surface can date what it shows — the module's "never silently wear today's label" doctrine holds.
`sleepIsCurrentDayPrimary` gained the same hold (default-nil cycle params, so any unwired caller keeps
the old behaviour exactly), and both real call sites are wired: `AtriaTodayScreen.sleepMetric` and
`WidgetSnapshot`, so app and widget cannot disagree.

Tests pin the boundary from both sides and re-assert the incident fixture is still refused.

## O. Live drain frontier parked — CORRECTED: not a wedge, the archive queue is genuinely working

Sampled 02:56 -> 03:43: `drainedThroughUnix` frozen at 08-18 22:32:39 for **47 minutes** while
`flushDebtPendingRecords` climbed 154 -> 1688, with
`offlineSync.lastStatus = deferred_terminal_materialization` and `materializing=1` throughout.
I initially flagged this as a probable FOURTH instance of the process-local-recovery-state defect class
(a leaked `historicalConsumerMaterializationInFlight` with no timeout). **The device evidence says that
is wrong, and I am recording the correction rather than the guess.**

Container listing diffed 01:57 -> 03:44 (107 min):

| new files | directory |
|---|---|
| 126 | `atria-historical/aggregates-v2` |
| 126 | `atria-historical/retention-manifests-v2` |
| 29 | `atria-full-fidelity-cold-sessions-v1/chunks` |
| 26 | `atria-historical/consumer-receipts-v1` |
| 2 | `atria-historical/hr-index-v1` |

Plus `historical-archive.catalog-v2.json` rewritten and 12 segment files changed. The materialization is
doing real, productive, receipted work at ~1.2 aggregates/min. `materializing=1` is HONEST — the drain is
deferring to it by design (AtriaBLEManager.swift:10988), which is why the frontier is parked.

So the user-visible symptom ("last sync stuck") has a third cause distinct from both item 2's latch and a
leak: **the archive is simply too large for materialization to keep up.** That is item 12 restated, and it
is a direct argument for raw retention over any cleverness in the drain.

Note the container GREW 5.45 -> 5.47 GB in those 107 minutes. The identity-retention fix (`32f4e598`) is
NOT on the phone yet — only `47538c32` is installed.

## P. Item 12 part 2 — DO NOT COMPRESS. Audit found ~15 blocking sites, one destructive.

Five independent audits, each adversarially re-checked: **all five returned `blockers-found`.** The
transparent read layer (`AtriaHistoricalJSONLInput`) is real but **not universal**. The trigger is
`AtriaHistoricalArchiveCatalog.recordCompressedStorage` rewriting `chunk.relativePath` to the artifact
(AtriaHistoricalArchiveCatalog.swift:467); that path then flows through
`HistoricalArchive.catalogRawFileURLs()` (:7602) into `recentReadableFileURLs()` (:7612) and
`AtriaHistoricalArchiveDurableStore(existingArchiveURLs:)` (:2812), handing `.atria-deflate` files
verbatim to code that assumes plain JSONL.

**DESTRUCTIVE — `AtriaHistoricalArchiveDurableStore.repairTornJSONLTail` (:1019).** Opens every
registered archive `forUpdating`; if the last byte is not `0x0A` it truncates back to the last `0x0A`,
and **truncates to 0 if there is none**. DEFLATE bytes rarely end in `0x0A`, so this would irreversibly
destroy compressed chunks after their plain sources were unlinked.
(My own L1 streaming compaction calls this too, but only on `identity.jsonl`, which is never a catalog
chunk and never compressed — safe.)

**Silent data loss:** `tailContent` (:9089) does a byte-tail `seek` — meaningless in a deflate stream;
`loadGravitySamples` (:8701) `String(contentsOf:encoding:.utf8)` on DEFLATE returns `[]` per file while
still reporting `.complete`.

**Offset addressing dies:** `indexEntryMatchesRawArchive` (:1696) seeks a stored `lineOffset`; `scanArchive`
(:2049) mints physical offsets. Every `IndexEntry` and every SQLite lookup row is offset-addressed, so the
dedupe accelerator degrades permanently.

**Fails OPEN into the known memory problem:** the three sealed-bound prune predicates
(HistoricalArchive.swift:8197, :8231, :7752) compare PHYSICAL `[.size]` against LOGICAL `chunk.byteCount`
plus an mtime-vs-`sealedAt` check. Both fail for every compressed chunk, the exclusions fail open, and all
686 chunks become unconditional scan candidates for every window — re-opening the already-proven 3.4 GB
foreground memory blowup.

**Sidecars orphaned:** `heartRateSidecarURL(forChunkRelativePath:)` (:7851) derives the sidecar filename
FROM the chunk path, and `validHeartRateSidecarBinding` (:7884) requires `binding.relativePath ==
chunk.relativePath`. The rename orphans all 351 sidecars, and `backfillHeartRateSidecars` (:7977) — no byte
budget, no chunk cap, no thermal guard — fires from Sessions.swift:51310 on every deferred session load.

### THE DECIDING ONE: compression and retirement are mutually exclusive as built

`AtriaHistoricalRawRetirementExecutor.retire()` (:87) throws `compressedSourceUnsupported` whenever
`chunk.compressedStorage != nil`. So **a compressed chunk can never be retired.** Worse,
`recoverFirstPendingIntent` is the FIRST statement of every compaction pass (HistoricalArchive.swift:9380),
so a chunk compressed while holding a durable retirement intent wedges the whole pass.

Part 2 would therefore have made part 3 — the "raw kept a week or a month" the user actually asked for —
**impossible**. Doing it first was exactly the wrong order.

### Revised plan for item 12

- ~~part 2 compress raw~~ **DROPPED.** Not a quick win: ~15 blocking sites, one destructive, and it blocks
  retention. Revisit only if retention alone proves insufficient.
- **part 3 is now the whole remaining job**, and it is the better one anyway: pruning raw beyond a horizon
  DELETES the 2.99 GB outright rather than shrinking it, which is literally what the user asked for.
  Retirement is intent-logged, transaction-gated, and (per the audit) fail-closed and safe in isolation.
  Still needs the cooperative-deadline work from K before the fence can be lifted.

## Q. Defensive guard shipped for the destructive path (item 15)

Full audit persisted to `.claude/compression-readiness-audit.md` — **55 blocking / needs-change sites**,
`safeToCompress: false`.

Even though nothing compresses raw chunks today, the destructive one is worth closing now, because it is
reachable the instant anyone wires compression: `recordCompressedStorage` rewrites `chunk.relativePath`
to the artifact -> `HistoricalArchive.catalogRawFileURLs()` -> `durableStoreLocked()`'s
`existingArchiveURLs` -> `repairTornJSONLTail` runs over every one at init (:372), on the cold rebuild
(:407), in `registerArchiveIfNeeded` (:1054), and on the snapshot delta (:1160).

`repairTornJSONLTail` now refuses any `.atria-deflate` path with a new
`StoreError.compressedArtifactIsImmutable`. The guard lives at the WRITE, not only in the callers —
losing user history to a future wiring mistake is not an acceptable failure mode. Test asserts the
artifact is byte-identical after a refused repair and that plain-JSONL repair is unchanged.

The remaining 54 sites are documented but NOT fixed; they only matter if compression is ever wired, and
the current recommendation is that it should not be.

## R. Item 5 (notification half) FIXED — device ledger proved it exactly

The user: "if you leave it from saving, or even if you save it, there's another sleep recommendation
that keeps on going after it has been stopped."

The device's own `atria.notification.sleepReview.scheduleCount.*` ledger is the proof. The id is
`sleep-review-<start>-<end>-<source>`, and the SAME start appears repeatedly with a growing end:

| window start | deliveries | growth steps |
|---|---|---|
| 1785780221 | **5** | 32.0, 35.6, 31.2, 30.6 min |
| 1786906198 | 4 | 33.0, 63.5, 83.5 min |
| 1786810526 | 3 | 247.5, 30.2 min |
| 1785631538 | 3 | 55.0, 70.8 min |
| 1787007477 (08-18) | 2 | 30.2 min |

A window-start debounce already exists (`AtriaSleepReviewNotificationDebounce`, 2026-08-01) and it is
NOT broken — it was built for sub-30-minute detector jitter (the documented 04:50/04:56/04:57 triple)
and it still does that job. The problem is that it bounds how FAR a window may grow before re-firing,
never how MANY times one episode may fire. An oldest-first drain fills a night in incremental batches,
and **every one of those growth steps cleared the 30-minute bar honestly.**

`sleepReviewMaximumSchedulesPerCandidate = 2` could not catch it either: that counter is keyed on the
candidate id, which embeds the END, so each growth step minted a fresh id and reset the count to zero.

**Fix:** a companion bounded ledger `sleepReviewNotifiedCountByStartKey` ([startKey: deliveries]) capping
total deliveries per physical episode at the same 2, keyed on the START where the debounce already keys.
Pruned by exactly the starts the end-ledger retains so the two cannot drift and a pruned start cannot
resurrect a spent budget. A genuinely different night keeps its own budget.

**Still open — the other half of item 5.** The in-app review CARD (not the notification) re-mints after a
Confirm, because `reviewedSleepSource` persists the detector's own source string, which never carries the
`manual_`/`user_adjusted_` prefix `isUserAuthoredSleepSource` tests for, so `isExtendableAutoNight` still
classifies an explicitly confirmed night as auto. See item 5 finding (A) in
`.claude/field-report-root-causes.md`. Not yet fixed.

## S. Item 5 (card half) FIXED — authorship was recorded in `confidence`, not `source`

The user's other half: "even if you save it, there's another sleep recommendation that keeps on going."

The plain **Confirm** button does not rewrite the source. `reviewedSleepSource` (Sessions.swift:35127)
returns the detector's own string verbatim whenever it is in `explicitSleepSources` — `overnight_sleep`,
`aggregate_sleep`, `resumed_sleep`, `nap_candidate`, `auto_confirmed_sleep`, … — and **none of those
carry the `manual_` / `user_adjusted_` prefixes** that `isUserAuthoredSleepSource` tests for. Only the
Adjust -> Save path mints those. So `isExtendableAutoNight` classified an explicitly user-confirmed night
as an untouched auto night, the extend path kept growing it, and the review card kept coming back.

**The device quantifies it.** Of 38 records in `atria.confirmedSleeps.v1`:

| | count |
|---|---|
| user-authored SOURCE (`manual_*`, `user_adjusted_*`) | 17 |
| non-authored source **but** `confidence == user_confirmed_hr_only` | **19** |
| genuinely automatic (`sleep_review_hr_only`/`low`, `auto_confirmed_sleep`/`medium`) | 2 |

So 19 of 38 saved nights were being treated as extendable auto nights. The authorship signal was
present the whole time — in `confidence`, not `source`.

**Fix:** new `sleepRecordIsUserAuthored(_:)` combining source prefixes with
`confidence.hasPrefix("user_confirmed_")` / `"manual_"`. This is not a new idea — it is exactly the
three-clause test `explicitUserSleepCorrection` (Sessions.swift:311) and the sleep-stress context
authority (:8275) already use. `isExtendableAutoNight` and **both** companion guards
(`sleepReviewExtensionTarget` :38741, `sleepExtendReplacement` :38869) now use it; all three shared the
same source-only blind spot. The persisted source string is deliberately left alone — other code parses
it for nap/display classification, so rewriting it would be a migration with no upside.

Tests cover the four device shapes that were re-offered, assert the two genuinely-automatic records stay
extendable (the fix must not freeze the auto path it was built for), and cover the replacement guard.

## T. Item 11 defect (4) FIXED — a 13-day-stale ticket was silencing every workout notification

Item 11 decomposes into five independent defects (full detail in `.claude/field-report-root-causes.md`;
note the catch-up-marker theory I first floated was REFUTED — `catchUpMarkerFrontierKey` is read at
exactly one site and feeds only the "Catch-up complete" banner). This pass fixes (4), the one that is
device-proven, bounded, and pure loss with no tradeoff.

`reviewNotificationsProtectedByLiveCapture` returned
`status == .connected && rangeLossBackfillPending && sessionSampleCount > 0`.
`rangeLossBackfillPending` is a **durable ticket that only new rows can acknowledge** — not a statement
that anything is filling right now. On the field device it has been `true` since **2026-08-08 17:08 —
over ten days** (corrected: I originally wrote 08-06 / thirteen days; unix 1786189119 is 08-08 17:08:39), and the strap is worn/connected/streaming almost continuously, so the guard returned true
essentially always and **every** workout notification was dropped with
`reason: "live_capture_protected_range_loss_backfill"` — including around the 21:42:50
`workout_start_boundary` journal close for the Strength workout the user reported. That is item 11's
"workout detected — never shows", completely.

**Fix:** extracted a pure `reviewIsProtectedByLiveCapture(...)` that bounds the ticket's authority by its
own age (`liveCaptureProtectionTicketFreshness = 6 h`). A backfill requested six hours ago is not
evidence about the window in front of the user now. A missing or forward-dated timestamp is treated as
stale on the same principle: an unprovable claim must not win. The protection itself is unchanged for
its real purpose — a connected, streaming link with a genuinely fresh ticket still suppresses.

Also stopped the suppression path wiping `workoutReviewLastCandidateIDKey`. A suppressed decision means
"not now", not "the user has never seen this"; wiping the dedup receipt made every suppression pass
re-arm an already-delivered candidate, so the notification the user eventually got could be one already
dismissed.

**Item 11 defects still open:**
- (1) pass-bound not event-bound: `sleep_review`/`workout_review` fire `delay: 6` s after a launch/
  scene-active/BGTask PASS, never at the physiological moment.
- (2) discovery is foreground-only: `shouldEnqueueSleepReviewProjection` hard-requires
  `applicationIsActive`, so a new nap/night cannot notify until the app is opened.
- (3) fires while the user is already in the app: `schedule(...)` has no application-state guard, so the
  banner lands ~6 s AFTER foregrounding. **Deliberately not fixed yet** — suppressing it without first
  building event-time delivery would remove a badly-timed signal and replace it with nothing.
- (5) there is no "Nap detected" push at all (`scheduleSleepLogged` excludes `nap_candidate`), and the
  journal nudge is a clock alarm at median-wake + 15 min, not wake-anchored.

## U. Installed the full fix set 04:05 — the motion fix WORKS mechanically, and exposes a second, physical failure

Built clean at `4ec5096e`; binary verified to carry every fix by string literal
(`atria.notification.sleepReview.notifiedCountByStart.v1`, `issued_age_s`, `passive_requalify_due`,
`stream_compacted`, `Awaiting current sleep`, `elevated period` — all present).

**The passive requalification fired, for the first time in 5.8 days.** Proof:

| key | before | after launch |
|---|---|---|
| `protectedR10.requalifyAttemptAt` | 08-13 06:22 (stuck 5.8 d) | **08-19 04:04:48** |
| `protectedR10.activationSentAt` | 08-13 06:22 | **08-19 04:04:56** |
| `protectedR10.cleanOwner` | `pure_hr_v8` | **`pure_hr_v10`** |
| `protectedR10.passiveReprobeFailureCount` | 10 | **11** |
| `protectedR10.workoutRequalifyLeaseStartedAt` | 08-13 05:45 | **08-13 05:45 (unchanged)** |

The owner moving v8 -> v10 is the mechanical proof: `fallbackOwner` is `.pureHRV10` only when the
failing owner was `.protectedV9`, so `promoteFallbackToProtectedV9ForLaunch` genuinely ran. And the
workout lease timestamp is UNCHANGED, so this was not a workout-triggered attempt — it was the new
passive path.

**But the attempt failed, and that is a different problem.** `fallbackAt = 04:05:01`, five seconds after
the activation, with `cleanOwnerFailureReason = clean_owner_proof_disconnect`. `protocol.imuFrames` is
still 0.

So the structural defect (a fallback that could never retry) is fixed and proven, and behind it sits a
**physical** one: the strap disconnects during the clean-owner proof. That failure was invisible before
because the retry could never happen. **Items 6 and 10 are therefore NOT resolved by this fix alone** —
the passive path will now retry every 12 h, but until the proof itself succeeds there is still no motion,
so naps stay undetected and stages stay fail-closed. The ledger must not claim otherwise.

Also observed after relaunch: the drain frontier is MOVING again (22:32 -> 22:33 -> 22:35) after 47 min
parked, and `stallReconnects` held at 331 — no recurrence of the original item-1/2/3 stall.

## V. R10 proof disconnect — forensics decoded; deliberately NOT changing BLE timing on one sample

Decoded `atria.protectedR10.proofDisconnectContext.v1` from the 04:05 attempt:

```
decision                          ambient_or_unattributed
owner / ownerState                protected_redp_v9 / proving
connectedDurationSeconds          12.52        <- link was 12.5 s old
activationAgeSeconds              4.38         <- died 4.4 s after the activation
proofStartedAgeSeconds            12.34
framesAfterActivation             0
crcRejectedFrames                 0            <- not corruption; NOTHING arrived
ambientDisconnectIntervalSeconds  1777.9       <- baseline drop interval ~29.6 min
confirmedNotifyUUIDs              61080003/4/5 (all three confirmed notifying)
centralState                      5 (poweredOn)
```
`radio.passiveR10Status = subscribed_no_crc_valid_frames`,
`radio.mode = protected_r10_minimal`, `protectedR10.activationCount` 359 -> 360.

**Leading hypothesis (code-provable, not sample-dependent).** The v7 activation path
`sendProtectedR10ActivationIfReady` (AtriaBLEManager.swift:12425) deliberately waits
`protectedR10PassiveGraceDuration = 20 s` of PASSIVE observation before writing the activation, with an
explicit comment that "repeatedly writing that command was physically correlated with early
disconnects". The v9 clean-owner proof instead starts at subscription time —
`markPassiveR10SubscriptionConfirmed` calls `beginProtectedR10CleanOwnerProofIfNeeded(at: subscribedAt)`
directly (AtriaBLEManager.swift:35993) — and the device shows `activationSentAt` and
`passiveR10SubscribedAt` in the SAME millisecond (1787092496.675 / .676), on a link ~7.5 s old.

**Why I did not act on it.** One forensic sample, and the recorder's own verdict is
`ambient_or_unattributed` — it explicitly declines to blame the activation. The link's baseline drop
interval is ~30 min, so a 12.5-s-old link dying is not obviously ambient either. Changing activation
timing in a physically-coupled BLE proof on a single sample is exactly the kind of speculative fix this
report has already punished twice (the item-4 `cycleEnd` patch would have restored the August incident;
the item-9 producer swap would have emptied every historical night). The honest move is to get a second
and third sample first.

**What I shipped instead:** `protectedR10ProofDisconnectHistoryKey` — a bounded, newest-first ring of
the last 8 proof-disconnect contexts. The single-slot key is the right shape for "what just went wrong"
and the wrong shape for a failure that now retries only every 12 h, because each retry destroys the
evidence of the last. Diagnostics only; nothing reads it to make a decision.

Next retry is due ~16:05 today. With two or three records the comparison
(`activationAgeSeconds` vs `connectedDurationSeconds` vs `ambientDisconnectIntervalSeconds`) becomes
decidable.

## W. Item 8 QUANTIFIED against 130,480 real samples — High is structurally unreachable

Device evidence: `stress.awakeBaseline.v1` holds **130,480 quiet-awake HR samples over 12 days**, and
`personalBaseline.restingHR = 56.0`.

User's own quiet-awake HR distribution:
`p5=66  p25=70  p50=75  p75=81  p90=88  p95=91  p99=96  max=97`

The scorer's HR term is `h = (mean - rest)/(max - rest)`, `hrStress = sigmoid(8*(h - 0.25))`, score
`= 3 * mult * base` with `mult <= 1` always. So with rest 56 and an age-estimated max of 187:

| the user's own percentile | bpm | score |
|---|---|---|
| p5 | 66 | 0.60 |
| p50 | 75 | 0.91 |
| p90 | 88 | 1.47 |
| p95 | 91 | 1.60 |
| p99 | 96 | 1.83 |
| **observed max** | **97** | **1.87** |

**High (>= 2.0) requires >= 100.1 bpm — above this user's observed awake maximum of 97.** High is
therefore *structurally unreachable* from awake HR. The sigmoid midpoint sits at 88.7 bpm, i.e. their
**p90-p95**, so ~90 % of waking life scores below the midpoint. That is item 8 exactly: "stress reads
lesser than it is generally shown."

Root cause in one number: **the HR reserve (131 bpm) is 17x wider than this user's actual quiet-awake
spread (7.6 bpm robust).** The coordinate is simply the wrong scale for the signal.

Simulation validated against the device's own outcome: my model of the code predicts 61.7 % calm /
38.3 % medium / 0 % high over the real histogram, against the observed `stress.distribution.v3` of
73.0 / 25.2 / 1.8 (the residual is EMA smoothing, HRV when present, sleep windows and workout multipliers
— my histogram is quiet-awake only). Close enough to trust the model.

**The dead learner is the intended fix, and a naive wire-in is WRONG.** `AtriaStressMonitor` fully
computes an awake reference (device: `center 85, spread 2.97`), persists it with throttled I/O, seeds it
across launches for up to 14 days — then discards it at BOTH consumers (`_ = awakeReference` at
AtriaStressMonitor.swift:379 and :3922). But simulating the obvious swap (tanh centred on the learned
center) gives **38-43 % High**, which is the old 95 %-Medium failure in new clothes. A median-centred
scale puts half the day above the midpoint by construction.

**User decision (asked, answered): "Keep Calm-dominant, make High reachable."**

Shipped `AtriaPhysiologicalStressModel.hrStressCoordinate(...)` + `Personalization.awakeReference`:
- **No reference -> byte-identical behaviour.** The reserve coordinate is kept verbatim for anyone who
  has not accumulated a reference, and for a reference that is non-finite or below resting.
- **With a reference**, `sigmoid(ln2 * (mean - center) / zoneHalfWidth)`, so the zone edges land exactly
  at `center +/- zoneHalfWidth` (since `3*sigmoid(-ln2) = 1`, `3*sigmoid(+ln2) = 2`).
- `zoneHalfWidth = clamp(spread * 2, 6, 12)`. The learned spread is a 45-minute window and can be far
  tighter than real day-to-day variability (device: 2.97 vs a robust 12-day 7.6), so it is floored to
  stop hypersensitivity and capped so a noisy window cannot widen back toward the useless reserve.

Simulated over the same 130,480-sample histogram, `center 85 / halfWidth 6` gives
**65.6 % calm, 29.6 % moderate, 4.9 % high** — inside the requested band. Note 85 is exactly the
learned awake center already on the device, so this is anchored, not tuned. Both discard sites
(`_ = awakeReference`) are gone.

## X. Item 8 shipped as scoring **v4**, not as an edit to v3 — a failing test found the right design

First attempt edited the v3 kernel in place. `AtriaStressMonitorTests.testLegacyAwakeReferenceCannotAlterV3Kernel`
went red, and it was RIGHT: a versioned kernel must not be silently reinterpreted or persisted facts
stop meaning what they meant when written. So v3 is untouched and the recalibration ships as v4; EMA
continuity already refuses to blend across a version boundary
(`previous.scoringVersion == scoringVersion`).

Baseline discipline: ran `AtriaStressMonitorTests` at the pre-change commit and got **83/83 green**, so
both red tests were mine to migrate rather than pre-existing. Final: **86/86 green** across Monitor,
PhysiologicalModel, DailyTrend, ReadingFreshness and SessionStressContextPublication.

Also note `AtriaStressState.rawActivation` is `fact.score / 3` — a 0...1 value. Zone edges are at
**1/3 and 2/3**, not 1 and 2. My first test asserted the wrong scale.

## Y. CORRECTION to K — the release fence's stated blocker was STALE. Fence lifted (item 12 part 3)

**I was wrong in entry K.** I grepped `HistoricalArchive.swift` for `checkpoint()`, `isCancelled`,
`CooperativeDeadline` and `workCounter`, found zero, and concluded the fence's reason ("composite
readers/publishers whose inner loops cannot all be revoked atomically") still held. The grep was
accurate; the inference was not. **The file uses a different idiom — `shouldContinue`:**

```
132  shouldContinue references in HistoricalArchive.swift
20+  functions accepting it
28   `guard shouldContinue()` sites, plus inner-loop checks every 16-32 iterations
```

The token those consume is `archiveCompactionWorkerShouldContinue`, which revokes on lease expiry,
thermal pressure and Low Power Mode; `shouldContinueArchiveCompactionWork` additionally requires the app
to still be backgrounded on the current lease generation. Revocation is cooperative, threaded and deep.
The proof the fence was waiting on was already done.

**Lifted.** `shouldExecuteArchiveWideMaintenance(explicitDebugOverride:automaticAdmission:)` now admits
either authority, and the call site computes `automaticAdmission` from
`shouldAdmitAutomaticArchiveCompaction(...)` — the full environmental model that was written for exactly
this and left unreachable (BGProcessing lane only, app backgrounded, no exact-recovery or
recovered-cycle owner, thermal/Low-Power/battery admission; battery monitoring is enabled at
AtriaBLEManager.swift:5729 so the level is real, not -1). Horizon set to **30 days** per the user's
choice.

Retirement stays fail-closed independently of this gate: `AtriaHistoricalRawRetirementExecutor.retire`
unlinks a raw chunk only after proving a committed aggregate AND manifest match its `contentSHA256`,
byte count, row count and both timestamps with a semantic-parity receipt, with `shouldContinue()`
checked at every stage. So the fence controls whether the graph RUNS, never whether an unverified
deletion can happen — which is precisely the "insights derived and verified before raw is retired" model
the user asked for.

`AtriaBackgroundProjectionTests`: **77/77 green** on a clean run.

**Flake note:** `testRecoveredArchiveSortRevocationInstallsNoSnapshotOrCache` failed twice while other
xcodebuilds ran concurrently, then passed 4/4 in isolation with the same change applied. It revokes on a
sort-comparison counter, so its timing shifts under machine load. Pre-existing load-sensitive flake, NOT
a regression — I initially and wrongly called it mine.

## Z. Item 11 defect (2) FIXED — the background nap-catcher was a no-op in the exact case it was written for

`runResidentSleepReviewRefreshIfUseful` (Sessions.swift:27948) exists specifically to catch a daytime
nap while the app stays backgrounded. Its own doc comment cites the on-device evidence:

> "The net effect, verified on-device 2026-08-01, was a 14:05-16:40 nap that produced no detection at
> all while the app stayed backgrounded — the app depended on a manual foreground to do its own work."

It then routes into `scheduleSleepReviewCacheRefresh`, whose gate
(`shouldEnqueueSleepReviewProjection`) requires **both** `sleepReviewProjectionForegroundAuthority` AND
UIKit `.active`. A background checkpoint can satisfy neither, so the nap-catcher dead-ends and the
review notification cannot fire until the user opens the app. Same defect class as the rest of this
report: a discovery path whose only trigger cannot occur in the state it targets.

**Fix:** a narrow `backgroundResidentAdmission`, granted only for
`residentSleepReviewRefreshReason` and only when restore is not blocked. Both foreground gates are kept
verbatim for every UI-driven path, so the SwiftUI-scene/UIKit-state ABA race the authority was built to
close stays closed — a throttled resident checkpoint has no interleaving UI request and is not a
participant in that race. Unattended CPU stays bounded by the existing 15-minute
`shouldAttemptResidentSleepReviewRefresh` throttle plus the input-key dedupe, which tests pin as still
authoritative.

`AtriaSleepReviewCacheTests`: **57/57 green**.

**Item 11 now 2 of 5.** Still open: (1) pass-bound rather than event-bound scheduling, (3) the banner
landing ~6 s AFTER foregrounding, (5) no "Nap detected" push exists and the journal nudge is a clock
alarm at median-wake+15. Note (5)'s nap push would be inert until motion recovers (items 6/10), so it
should follow the R10 proof work rather than precede it.

## AA. Installed everything, and the device caught a flaw in MY OWN retention fix

Built clean at `73663bdb`, verified by literal (`proofDisconnectHistory.v1`, `resident_review_checkpoint`,
`currentCycleAcrossMidnight`, `notifiedCountByStart` all present), installed and launched 05:40.
Post-install state is healthy: HR live, frontier advancing (23:19 -> 23:31), `stallReconnects` still 331,
`requalifyAttemptAt` still 04:04:48 (correct — the 12 h interval puts the next R10 attempt ~16:05), and
`proofDisconnectHistory` at 0 entries (correct — no proof disconnect since the ring shipped).

**Then the device disproved half of L3.** Checking the container found **no `prune.json`** and the
identity files unchanged at 1.26 GB / 839.7 MB after two launches carrying the fix.

The mechanism: `lastPruneAtUnix` is seeded from `now()` when the sidecar is absent, but the sidecar was
only written *by a completed prune* — and a prune needs 6 h measured from that seed. So every relaunch
re-seeded the clock, the marker could never come into existence, and the interval stayed effectively
**uptime-based, exactly the bug L3 claimed to fix.** I fixed the reading and not the bootstrapping.

Fixed: stamp the marker at init when it is absent, so the clock starts at first launch and survives
every restart from then on. Test asserts a first launch creates it without waiting for a prune, and that
a relaunch three hours later inherits the ORIGINAL stamp rather than overwriting it.

`AtriaHistoricalArchiveDurableStoreTests`: **34/34 green**.

Lesson worth keeping: a fix that only ever runs after the condition it fixes is not a fix. This is the
same shape as the four recovery-state defects in this report — I reproduced it while fixing them.

## AB. Item 13 — both challengers were right to refute; the real defect DESTROYS the input

The original item-13 finding ("no engine turns measurement into a suggestion") was **refuted 2/2**, and
correctly. Their corrections converge on something concrete:

- **Challenger 1:** the measured-HR -> statement pipeline already ships end to end and needs no journal
  and no recovery — `wearRestingHR` -> `SavedDailyMetric.restingHR` -> `DailyRollupVitals.rhr`
  (trailing-28-day Welford mean/sd/n) -> `AtriaHighlights.lowerRestingHeartRate` +
  `healthDeviationDecision` (|z| >= 2 for two days) -> the already-honest `.healthDeviation` category.
  **"The defect is that its input is destroyed after it is correctly produced."**
- **Challenger 2:** "Atria has an OUTCOME and no MEASURED PREDICTORS" — every statistical predictor is
  hand-typed; and the gates are BINARY (hide everything until N) where the codebase already documents the
  better "Early estimate · day N of M" pattern at Insights.swift:302-317.

**Verified the destruction in code.** `preparedDailyMetricHistory` derives `restingHR` from
`night?.restingHR` (Sessions.swift:21553) — the confirmed main-sleep night ONLY — but appends a row for
every day carrying any session rollup. `mergeDailyMetricHistoryCancellable` then seeds `merged` from
`computed` first (21804-21808) and only lets `existing` fill days `computed` did not produce. So a
recompute that could not observe resting HR discards the existing row that held a real `wearRestingHR`.

**Measured on device:** `restingHR` present on only **27 of 43 days (63 %)**. The nil days line up
exactly with days having no confirmed sleep — and **08-19 currently carries `rhr = 68` with no sleep**,
a wear-derived value the next bulk rebuild would have erased. (`hrv` is present on just 1/43 days, a
separate and larger gap.)

**Fix:** `dailyMetricPreservingMeasuredFacts` — a rebuild that cannot OBSERVE a measured fact must not
assert its absence. It only ever fills a nil, never overwrites a value the rebuild derived, never invents
one neither row holds, and never applies to a day the caller declared authoritative.
`AtriaRecoveryFreezeTests` + `SavedDailyMetricCodableTests`: **40/40 green**.

This does not "build an insight engine" — it stops starving the one that already exists. The engine-design
half of item 13 (measured predictors, graduated rather than binary gates) remains open and is a genuine
feature, not a bug.

## AC. Installed and VERIFIED the retention clock starts; HRV investigated but deliberately NOT changed

Installed `3fcdbcf5` at 05:58 (fresh derived-data path — the earlier build failed only because two of my
own concurrent builds shared one `build.db`). **Device-verified:**
`Documents/atria-historical/historical-archive.identity.prune.json` now EXISTS, 38 bytes, stamped 05:58.
The AA bootstrap fix works: the retention clock is running for the first time. `identity.jsonl` is still
1.27 GB, as expected — the first prune comes due ~11:58, six hours after the marker.

### HRV gap — measured, partially explained, and left alone on purpose

Follow-up to the `hrv` 1/43 figure noticed in AB. Device facts:

| | |
|---|---|
| confirmed sleeps with `hrvWindowCount = 0` | **37 of 38** |
| confirmed sleeps with `respiratoryRate` | 24 of 38 |
| the one success | 08-18, `hrvWindowCount = 12`, hrv 61 |

Both metrics come from the same RR stream, so this is an internal contradiction worth chasing. The gate
chain for HRV: `hasQualifiedRRProvenance` (an `allSatisfy` over the WHOLE session — one non-2A37 /
non-verified-V24 point voids it) -> `minimumQualifiedRRBeatCount` = 0.5 beats/s x 300 s = 150 ->
segments split whenever a consecutive RR gap exceeds `HRVSnapshot.maxReadyRRGapSeconds = 3 s` -> each
segment must span >= 300 s -> **>= 3 windows** before any value is produced.

**A wrong inference of mine, corrected.** I first concluded the RR stream was too sparse, having read
`rrPresence.rrGap = 5.98 s` from an earlier snapshot — double the 3 s continuity limit. The CURRENT
device reads **`rrGap = 1.00 s` with 1143 `rrValues`**, comfortably inside the limit. So sparsity does
**not** explain the failure at present RR rates, and the line I printed claiming "nearly every
consecutive pair BREAKS the segment" was wrong.

**Nothing shipped for this.** Loosening `maxReadyRRGapSeconds` would compute RMSSD across non-adjacent
beats — fabricating HRV, a direct violation of the project's honesty rule. A gate that is clinically
correct must not be widened to make a number appear.

**Leading hypothesis for the next iteration (explicitly unproven):** the comment at the HRV producer says
"A confirmed sleep commonly spans several connection-bounded sessions", and windows must reach 300 s
*within one session*. This link drops on a ~1778 s ambient interval and logged 331 stall reconnects. If
sessions are routinely shorter than five minutes of continuous RR, no window can form regardless of RR
density — which would make HRV loss another downstream victim of the same link instability as items
1/2/3. Test by measuring per-session RR span on a recent night BEFORE touching any threshold.

This also matters for item 8: with `hrvBaseline` nil, stress scores HR-only, so the v4 recalibration is
carrying the whole signal by itself.

## AD. HRV RESOLVED by measurement — the gate is correct, the LINK was the problem. No code change.

Pulled `Documents/sessions.json` (12.6 MB, 28 sessions, 24 with RR) and measured continuous-RR spans
directly. **My AC hypothesis was wrong** — sessions are not short. Most are a full 180 minutes.

The real mechanism is intra-session dropout density. Median RR spacing is ~1.0 s everywhere (the stream
is dense), but a few percent of intervals arrive more than 3 s late, and they are spread evenly enough
to chop every candidate five-minute window:

| session | gaps > 3 s | mean clean run | longest run | HRV windows |
|---|---|---|---|---|
| 08-17 04:00 | 4.3 % | ~23 s | 122 s | 0 |
| 08-18 07:27 | 4.4 % | ~23 s | 72 s | 0 |
| 08-18 16:28 | 6.7 % | ~15 s | 85 s | 0 |
| **08-18 04:27** | **2.1 %** | ~48 s | **1377 s** | **6 -> the one night HRV worked** |
| 08-19 02:12 *(post-fix)* | 2.6 % | ~38 s | 367 s | 3 |
| 08-19 05:12 *(post-fix)* | **1.3 %** | ~77 s | 603 s | 2 |

At ~1 RR/s a 300 s window needs ~300 consecutive intervals with no >3 s gap. P(clean) falls off a
cliff: 1.4e-06 at 4.4 % dropout, 1.7e-03 at 2.1 %, 2.0e-02 at 1.3 %. So HRV appears only once the
dropout rate drops below roughly 2 %, which is exactly what the table shows.

**Conclusions:**
1. The HRV qualification is CORRECT and needs no change. RMSSD across a >3 s hole would difference
   non-adjacent beats. Widening the gate to make a number appear would be fabrication.
2. The defect is upstream: BLE dropouts degrade an otherwise dense RR stream.
3. **The two lowest-dropout sessions on record are both post-fix** (2.6 % and 1.3 %, versus 4.3-6.7 %
   before), and both produced qualifying windows. That is consistent with the items-1/2/3 link-stability
   fix improving RR continuity — but it is **two samples**, so suggestive, not proven. Re-measure after a
   full night on the current build.

**Nothing shipped.** The correct lever was already pulled.

One honest gap remains, NOT built: the app shows no HRV and does not say why. The project's own rule is
that fail-closed states must be visible, so "HRV needs 5 unbroken minutes of beat-to-beat data; the strap
link dropped N times last night" would be truthful and useful. Left for the user to decide — it is a UI
addition, not a defect fix.

## AE. Item 11 (5) journal nudge — measured, and a self-correction

Started on the journal-nudge half of item 11 defect (5): "Start the day with Journal — right after main
night sleep is detected."

**Correction to something I said mid-investigation.** I first reported
`atria.dutyCycle.sleepWindowEndMin` as **None** on the device and was about to conclude the nudge falls
back to a hard-coded `8 * 60` = 08:00. That was **my own key-casing error** — the schema key is
`atria.dutycycle.sleepWindowEndMin`, lowercase `c` (AtriaBLESchema.swift:448). Searched correctly, the
device has it populated:

```
atria.dutycycle.sleepWindowStartMin = 143  -> 02:23
atria.dutycycle.sleepWindowEndMin   = 654  -> 10:54
morningNudgeMinutes(654)            = 609  -> 10:09   (windowEnd - 45 min)
```

So the learned window IS working and the nudge is NOT a hard-coded 08:00. The mechanism is
`windowEnd - 45 min`, where `windowEnd` is the learned typical wake.

**What is actually true:** it is still a *fixed clock time* recomputed from a 14-day median, not anchored
to the night that just ended. On 08-18 that happened to land well — confirmed sleep 04:27 + 303 min
-> wake ~09:30, nudge at 10:09, i.e. ~39 min after the real wake. On a 06:00 wake the same schedule
would be roughly 4 hours late. That matches the user's complaint in shape, but the magnitude is much
smaller than the original finding implied, and on some nights it is fine.

**Nothing shipped.** The honest fix is to deliver relative to the ACTUAL detected wake when one exists,
keeping the median-derived pre-schedule as the fallback it was designed to be (it exists precisely so an
unconfirmed night still gets a nudge — see the comment at LocalNotificationScheduler.swift:448-455).
That is really item 11 defect (1), event-bound rather than pass-bound scheduling, and it is notification
surgery that deserves a fresh session rather than the tail of a long one — especially having just made a
lookup error on this very item.

## AF. Item 11 defect (3) FIXED — review banners no longer land 6 s after you open the app

`sleep_review` and `workout_review` decisions are produced only by a launch / scene-active / BGTask PASS
and carry `delay: 6`, and `schedule(...)` had no application-state guard (unlike
`AtriaEventNotificationScheduler`, which uses `guard !applicationIsActive` at :76, :156, :171). So on a
foreground pass the banner lands about six seconds AFTER the user opens Atria — while the in-app review
card is already on screen showing the same candidate. That is literally "the push notification lies
there, but never shows up at right time".

Added `reviewBannerIsRedundantWhileActive(kind:applicationIsActive:)`, scoped to the two REVIEW kinds
only. Battery, connection diagnosis, catch-up completion, morning summary, fit-check and sleep-logged
still fire while the app is open, because those report state no card is already showing — pinned by test.

**Why it is safe NOW and was not before.** I deliberately deferred this earlier: suppressing a
badly-timed signal without an alternative delivery path would have removed it entirely, since discovery
was foreground-only. Defect (2) (entry Z) fixed that — the resident checkpoint can now discover a new
nap/night while backgrounded, so a BGTask pass can still deliver. The dependency ran (2) -> (3), and
doing (3) first would have made things worse.

Deliberately NOT clearing any dedup receipt on suppression — the lesson from defect (4), where the
suppression path wiped `workoutReviewLastCandidateIDKey` and re-armed already-delivered candidates.
Suppression means "not now", not "the user has never seen this".

Also added the missing `import UIKit` (the file is already `@MainActor`, so `UIApplication.shared` is
actor-safe here). `AtriaEventNotificationPolicyTests`: **18/18 green**.

**Item 11 now 3 of 5.** Remaining: (1) pass-bound rather than event-bound scheduling — the architectural
one, which subsumes the journal-nudge half of (5) measured in AE; and (5)'s "Nap detected" push, which
stays inert until motion recovers.

## AG. Item 11 defect (1) FIXED — a physiological event now schedules its own notification

The finding's headline was "no physiological event in Atria schedules its own notification". That was
half right: `scheduleSleepLogged` already fires at save time for an AUTO-CONFIRMED night
(Sessions.swift:37590, :38456). What had no equivalent was the case the user actually hits — a night or
nap that needs REVIEW. Those waited for the next launch / scene-active / BGTask pass.

The event-time hook already existed and was unused: `Sessions.swift:36987`, where an admitted candidate
is persisted via `AtriaPendingSleepReviewStore.save(night)` and `persisted == true`. That is the moment
the app KNOWS there is something to review.

Added `LocalNotificationScheduler.scheduleAdmittedSleepReview(store:)` and called it there. Design notes:

- **It adds a trigger, not a policy.** It runs the SAME `makeSleepReviewDecision` gate stack, so the
  per-episode delivery cap (entry R), the window-start end-growth debounce, the per-candidate cooldown,
  local dismissal and the settings toggle all still apply unchanged. It also honours the
  redundant-while-active suppression from AF.
- **No `AtriaBLEManager` needed.** `makeSleepReviewDecision` takes only `store` — the live-capture
  protection is workout-only. That matters because `SessionStore` holds no BLE handle, and every other
  notification call it makes is store-only.
- **Reachable while backgrounded only because of defect (2).** Before entry Z the admission path could
  not run unattended, so this hook would have fired only when the user opened the app — i.e. exactly the
  useless timing AF just removed. The dependency chain is strictly (2) -> (3) -> (1).

`AtriaEventNotificationPolicyTests` + `AtriaSleepReviewNotificationDebounceTests` +
`AtriaSleepReviewCacheTests`: **85/85 green**.

**Item 11 now 4 of 5.** Only (5)'s "Nap detected" push remains, and it stays inert until motion recovers
— so it correctly waits on the R10 proof work rather than being built now. The journal-nudge half of (5),
measured in AE, is materially improved by this change for the review prompt, though the nudge itself is
still median-anchored.

## AH. Item 13 engine half — the whiteboard coach was permanently, not temporarily, silent

`AtriaWhiteboardCoachSentence.rewrite` (Dashboard.swift:336) required **both** `hrvTrusted` AND
`restingTrusted` before producing any guidance; otherwise "Calibrating your baseline · N of 14 nights"
with `target: nil`.

On this device that is not calibration, it is permanent silence. Per entry AD, HRV appears on 1 of 43
days because RR dropouts stop a five-minute window ever forming, so `hrvTrusted` **never flips** and the
wearer reads "1 of 14 nights" forever — while a perfectly mature resting band sits unused. That is item
13's "there must be engines that learn and suggest": the engine exists and is gated behind a baseline
this hardware cannot produce.

Two facts made a resting-only lane the right answer rather than an invention:
1. **The file's own neighbouring doctrine** (Insights.swift:302-317): "a value is shown from the first
   day and the qualifier discloses how far the baseline has matured, rather than withholding the reading
   until it is confident. **Withholding is not more honest — it just leaves the wearer with nothing while
   the app silently waits.**" The whiteboard was the site violating it.
2. **Precedent for HRV-free guidance already ships** — the recovery model's
   `limitedEvidenceEstimateWithoutHRV` weights HRV exactly 0 at `.unverified`. No new claim class.

Added `restingOnlyGuidance(kernel:context:rhrZ:)`, taken only when the resting band is mature and HRV is
not. It calls an elevated resting HR on its own, keeps the kernel target (a real band backs it), and
**always** appends "HRV is still calibrating, so this reads resting HR only" — it never claims an HRV
reading it does not have, pinned by test. With NEITHER band mature the original calibrating tier is
untouched.

Resting HR does not share HRV's limitation: it learns from qualified daytime low-HR windows
(Insights.swift:298-300), which is why it matured on this device and HRV did not.

`AtriaWhiteboardCoachSentenceTests`: **9/9 green, 0 skipped** — the fixture genuinely produces a
resting-trusted / HRV-untrusted baseline (`learn(fromResting:hrv: 0)` is the no-HRV sentinel).

**Item 13 now: input defect fixed (AB) + the first engine unblocked (AH).** The broader ask — measured
predictors instead of hand-typed journal tags — remains open and is a genuine feature.

## AI. Full set installed 06:26 — and the retention bootstrap proved itself across a relaunch

Built at `7ed43886`, verified by literal (`redundant_while_app_active`, `resting HR only`,
`trigger=admission`, `resident_review_checkpoint` all present), installed and launched.

Post-install: HR live, `stallReconnects` still **331** (no recurrence of the original stall since 02:11),
link connected, drain frontier advanced to 08-19 02:21 with the backlog down to **4.14 h** (from 6.19 h
at 06:04).

**The AA fix verified in the way that matters:** `historical-archive.identity.prune.json` is still
stamped **05:58** after this relaunch — it was NOT overwritten. That is exactly the bug AA repaired: the
marker now survives restarts, so the six-hour retention clock keeps counting from first launch instead of
resetting on every process death. First prune still due ~11:58.

## AJ. Item 13 — the "learning engine" was manufacturing ~4 false findings per run

`AtriaBehaviorImpact.summariesCancellable` screens **every** `BehaviorJournalEntry.Tag` at an
uncorrected `p < 0.10`. There are **40 tags**. So once a wearer journals enough to clear the day gates:

```
P(at least one false positive) = 98.5 %
expected spurious findings      = 4.0 per run
```

on a surface that renders causal-sounding claims like "alcohol: -5 % next-day recovery". An engine that
invents four such claims out of noise is worse than one that says nothing — and this is the very engine
item 13 asks to "learn from the insight and suggest".

**The codebase already had the answer.** `AtriaJournalInsights` (v2) applies "a Bonferroni correction
over the searched candidates" plus 2000-permutation testing (AtriaJournalInsights.swift:262). v1 was the
lone outlier — the same shape as `maximumHeartRateGap = 15` standing against a 90 s stack everywhere
else (item 10 gate B). Matched the sibling rather than inventing a third policy.

Added `correctedThreshold(testedCount:familyWise:)` and filtered results through it. Corrected over tags
**actually tested**, not all 40: a wearer who logs two tags is not penalised for the thirty-eight they
never used, and that is also the standard "searched candidates" treatment v2's comment names. Zero
tested candidates collapses the threshold to 0 rather than dividing by zero.

`AtriaBehaviorImpactPresentationTests`: **23/23 green**, including a genuinely strong single-tag effect
that still survives the correction (so this tightens false positives without silencing real findings).

**Item 13 status:** input defect fixed (AB), first engine unblocked (AH), and the statistical engine no
longer fabricates findings (AJ). The remaining ask — predictors derived from MEASUREMENT rather than
hand-typed tags — stays open. It needs a new predictor family, a widened `BehaviorImpactSummary` type and
UI surface, and it would raise the searched-candidate count, so the correction above is a prerequisite
rather than an afterthought.

## AK. Verified the item-11 fix is durable — and corrected a date I quoted repeatedly

Tracked `rangeLossBackfillRequestedAt` across **all 30 device snapshots** taken this session, spanning
five hours:

```
requestedAt = 08-08 17:08:39   — IDENTICAL in every single snapshot
startedAt   = moves every ~15 min (the retry cadence)
```

**This verifies the item-11 defect-(4) fix by measurement rather than by reasoning.** I bounded the
live-capture suppression by the ticket's own age on the assumption that `requestedAt` is a one-shot
stamp. If it were re-stamped on each retry the ticket would keep looking fresh and workout notifications
would stay suppressed forever — the fix would have been useless. It never moves, so a stale ticket stays
stale and the suppression genuinely releases. Only `startedAt` advances.

**Correction.** I have been writing that this ticket has been pending "since 2026-08-06, thirteen days",
in two places in this ledger and in commit `4ec5096e`'s message. Unix `1786189119` is
**2026-08-08 17:08:39**, so the correct figure is **10.6 days**. The substance is unchanged — a durable
ticket stuck for over ten days silencing an entire notification class — but the number was wrong and is
now fixed above.

## AL. Item 15 lead (a) ROOT-CAUSED — the range-loss ticket requires resolving a window that no longer exists

My original lead was **wrong about the mechanism**. I wrote that
`scheduleStaleArmedRangeLossBackfillReconciliation` blocks the clear because the live status is not in
its `clearableStatuses` list. That function only LOGS — it sets `staleRangeLossReconciliationInFlight`
true and immediately false, and clears nothing. Here is the real chain, traced end to end.

The only non-user clear path is `AtriaBLEManager.swift:16391`, gated by:

```swift
// AtriaBLEHistoricalRecoveryPolicy.swift:1610
return ledgerCoverageResolved && !hasRequestedWindow
```

**Device state right now:**

| | |
|---|---|
| `rangeLossBackfillPending` | **true**, requested 08-08 17:08 (10.6 days) |
| `recoveryWindowStart` / `End` | **absent** -> `hasRequestedWindow = false` |
| `atria.offlineSync.missingWindows.v1` | **absent** -> zero pending gap windows |

So the clear reduces to `ledgerCoverageResolved` alone. And that flag is set in exactly one shape
(AtriaBLEManager.swift:37341):

```swift
if gapResult.resolvedWindows > 0, activeFullDrainEventIdentity == nil {
    offlineHistoricalSyncResolvedGapCoverage = true
}
```

**`resolvedWindows > 0` cannot happen when the ledger holds zero windows.** Nothing is left to recover,
and precisely because nothing is left to recover, the ticket can never be acknowledged. The only other
clear site is `startFreshAcceptingMissedDataLoss` — the user manually tapping "Start fresh" and
accepting data loss.

**Sixth instance of this report's defect class:** a clear/recovery condition satisfiable only by an event
that cannot occur in the state it governs. (Siblings: silent-stream latch, pure-HR requalification,
`lastPruneAtUnix`, the backfill ticket's notification authority, the foreground-only nap catcher.)

**Deliberately NOT fixed here.** The conservative design is explicit — "Only rows appended by this sync
can acknowledge it" — because clearing on general readiness once silently discarded a real recovery
request (the documented gym failure). A wrong change drops genuine unrecovered data. The shape of the
right fix is clear: a completed sync that finds NO pending ledger windows and NO requested window has no
recoverable target, and should clear under its own distinct auditable status rather than requiring
`resolvedWindows > 0`. That deserves a fresh session and its own verification, not the tail of this one.

## AM. Item 15 lead (e) + an honesty regression I introduced myself

**50.8 MB of orphaned artifacts measured on device**, none of which has a reader:

| MB | files | what |
|---|---|---|
| 22.8 | 61 | `tmp/` share PNG + exported HTML/GPX, oldest **7/15 — 35 days old** |
| 17.0 | 2 | `atria-memprobe*.log` — **the writer no longer exists anywhere in the codebase**, only a stale comment at HistoricalArchive.swift:6483 survives |
| 11.0 | 9 | other `tmp/` |

`tmp/` is nominally purgeable by iOS; it demonstrably was not being purged here. Added
`shouldSweepGeneratedArtifact(name:modifiedAt:now:minimumAge:)` — generated extensions only
(`.png`/`.html`/`.gpx`), age-gated at 24 h so an in-flight share sheet cannot own the file, and refusing
forward-dated files since a clock correction is not evidence of age. `orphanedDebugLogNames` names only
the memprobe pair, which has no writer at all.

**And an honesty regression I created.** `AtriaManagedStorageInventory.currentRetentionExecutionBlocked`
still asserted `RETENTION_EXECUTION_BLOCKED(automatic_execution_disabled+cold_session_consumers_shadow_only)`.
The first half stopped being true the moment I lifted the archive-wide fence in `df11d6c5` — automatic
maintenance now runs from the BGProcessing lane under `shouldAdmitAutomaticArchiveCompaction`. This
file's own header says *"a false storage promise is worse than an honest blocker"*, and that cuts both
ways: a false BLOCKER misreports state just as badly. Renamed to `currentRetentionExecutionState` and
corrected to `RETENTION_EXECUTION_ADMITTED(bg_processing_environmental_admission)+COLD_SESSION_CONSUMERS_SHADOW_ONLY`
— the half that is still true is still named. Both call sites migrated; the old symbol is gone, so it
cannot silently drift again.

## AN. Orphan sweep WIRED — the 50.8 MB now actually gets reclaimed

Previous entry shipped the policy and its tests but deliberately stopped short of invoking it, because
deleting user files from a per-launch task is the shape that has burned this session twice. With the
policy pinned, the wiring is now bounded.

`sweepOrphanedArtifacts(documentsURL:temporaryURL:now:fileManager:)` deletes exactly two things —
the memprobe pair in Documents (writer removed from the codebase) and generated `.png`/`.html`/`.gpx`
in `tmp/` older than 24 h — and returns the bytes reclaimed. It never walks the archive, never touches a
store, and every failure is swallowed: reclaiming disk must never fail a launch, so a file that will not
delete is simply counted as not reclaimed.

Wired into the existing per-launch inventory `Task.detached`, **before** `measure()` so the receipt
reports the container as it now stands rather than as it was a moment ago. `Receipt.reclaimedBytes`
already existed and was always 0; it now carries the real figure, so the sweep is auditable rather than
silent.

Tests run against **real temporary directories**, not a mock, and pin both directions: the two memprobe
logs and two aged artifacts are reclaimed (exact byte total), while `sessions.json`, a 2-hour-old share
PNG, and a non-generated `tmp/` file all survive. A second pass reclaims 0 and throws nothing, so the
sweep is idempotent and safe on every launch.

`AtriaHandoff13Tests`: **14/14 green**. One compile error caught en route — I passed `reclaimedBytes`
before `nextEligibleAction` at the call site.

## AO. FIRST REAL BYTES RECLAIMED — 39.9 MB, device-measured

Installed the sweep and measured the container before and after:

| | sweepable | container |
|---|---|---|
| before | 39.8 MB / 63 files | 5.506 GB |
| after | 0.0 MB / 1 file | **5.467 GB** |

**Reclaimed 39.9 MB**, and `memprobe` now returns **zero** matches in the container listing — both
orphaned logs gone.

The device's own receipt confirms it auditably rather than silently:

```
recordedAt         08-19 07:20:05
reclaimedBytes     41,795,313  (39.9 MB)
retentionExecution RETENTION_EXECUTION_ADMITTED(bg_processing_environmental_admission)
                   +COLD_SESSION_CONSUMERS_SHADOW_ONLY
```

That is `Receipt.reclaimedBytes` — a field that existed and had always been 0 — carrying a real figure
for the first time, alongside the corrected retention string reporting the honest state.

**Correction to my own figure.** I quoted "50.8 MB of orphans" in AM. That was the total
orphan/transient footprint; **39.8 MB of it was in scope for this sweep.** The other ~11 MB is `tmp/`
content that is not a generated share/export artifact (e.g. two 5.5 MB UUID-named files), which the
sweep deliberately does not touch. So 39.9 MB reclaimed matches the designed scope exactly — the earlier
number measured the wrong set.

## AP. Item 15 lead (b) CLOSED as not-a-defect — and my characterisation of it was wrong

I recorded lead (b) as "`terminalArchiveFailureDiagnostic = publicationCheckpointMissing`, **stuck since
2026-08-14** (5 days)". That reading was wrong in kind: the key holds only the **latest** failure, so
08-14 meant "the most recent failure was on 08-14", never "wedged since". The device now reads
`terminalArchiveFailureAt = 2026-08-19 01:07:33` — it moved, so it recurs and recovers.

Followed the site tag to the exact throw. `terminalFailureSite` advanced `site38023` -> **`site38213`**,
and that `#line` is:

```swift
if fullScanSnapshotChanged {
    guard previousFullScan.generation < UInt64.max,
          refreshedSnapshot.catalogGeneration > previousFullScan.catalogGeneration else {
        throw Self.terminalCheckpointMissing("site\(#line)")
    }
```

The archive content changed (SHA/timestamps differ) while the catalog generation had not yet advanced —
precisely the race the Handoff-12 comment names: *"a transient publicationCheckpointMissing (catalog
snapshot changed before its generation advanced)"*. That lane already self-heals:
`scheduleTerminalConsumerDependencyRetry()` re-arms `resumePendingFullDrainPublicationIfNeeded` on a
bounded interval, added specifically because this was once "the one failure lane with no self re-arm".

**Conclusion: known, handled, transient. No change shipped.** The site-tag mechanism did exactly its
job — its own comment says a five-day wedge was previously "diagnosed only through repeated on-device
passes", and here it resolved the question in one lookup.

**Worth noting as a pattern**, not acted on: several of these diagnostics are single-slot and therefore
cannot show FREQUENCY — the same limitation I hit on the R10 proof context and fixed there with a
bounded ring. `terminalArchiveFailureAt` has the identical shape. If this failure ever needs real
triage, it will need the same treatment.

## AQ. Retention clock has now survived THREE relaunches

`historical-archive.identity.prune.json` still reads **05:58** after relaunches at 06:26, 07:19 and
07:26. Each relaunch is an independent test of the AA bootstrap fix, and the marker has not been
re-seeded once. The six-hour interval is genuinely wall-clock now; prune due ~11:58.

## AR. Item 15 lead (c) CLOSED as not-a-defect — the park is NOT engaged

Checked whether the sequence-gap terminal park had exhausted its budget and wedged. It has not:

```
atria.offlineSync.sequenceGapParkedAt.v1             ABSENT
atria.offlineSync.sequenceGapParkedFrontierUnix.v1   ABSENT
```

Both park keys are absent, so the ticket was never parked. `historySequenceGapAttemptBudget = 6` per
exact gap fingerprint was never exhausted.

The failure that raised the lead — `history_sequence_gap_replay_mismatch_expected_44057_received_57618` —
is stamped **2026-08-18 02:08:23, 1.22 days ago**, and it is a single historical event rather than an
ongoing condition. The drain has advanced continuously all session since: frontier 21:34 -> 04:16 with
the backlog falling 4.75 h -> 3.17 h. A parked ticket would not do that.

**No change shipped.** Same discipline as lead (b): the honest output is closing a lead with evidence,
not manufacturing a fix for a healthy subsystem.

### Item 15 sweep — all five leads now resolved

| lead | outcome |
|---|---|
| (a) range-loss ticket stuck 10.6 d | **root-caused** (AL) — needs a window that no longer exists; fix shape recorded, deliberately not shipped (data-integrity risk) |
| (b) `publicationCheckpointMissing` | **closed, not a defect** (AP) — recurring transient race, already self-heals; my "stuck since 08-14" reading was wrong |
| (c) sequence-gap terminal park | **closed, not a defect** (AR) — park never engaged, budget never exhausted |
| (d) `hrv.lastReadyAnalysisAt` 8 d stale | **resolved** (AD) — RR dropouts prevent 5-min windows; gate is correct, link was the cause |
| (e) 17 MB memprobe + tmp leftovers | **FIXED and measured** (AN/AO) — 39.9 MB reclaimed on device |

Two of five were real defects, two were my own misreadings of single-slot diagnostics, and one was a
correct fail-closed state.

## AS. REGRESSION I INTRODUCED — the v4 stress scale is calibration-fragile and is currently wrong on device

Verified two shipped fixes against the device. One landed exactly as intended; the other did not.

**AH (whiteboard coach) — VERIFIED GOOD.** The device baseline holds 19 fresh resting samples and 1
fresh HRV sample against `trustedMinimumSamples = 14`:

```
restingTrusted = TRUE  (19/14)
hrvTrusted     = FALSE (1/14)
```

That is precisely the state the resting-only lane was built for, so this user now gets real guidance
instead of "Calibrating your baseline · 1 of 14 nights" forever. Device-confirmed, not hypothetical.

**AS (stress v4) — REGRESSION.** I calibrated the v4 scale against a single snapshot of
`stress.awakeReference.v1`. That reference is **volatile**, and it drifted during this very session:

| | center | spread | zoneHalfWidth | calm edge | high edge |
|---|---|---|---|---|---|
| at calibration 01:57 | 85.0 | 2.97 | 6.0 | 79 bpm | 91 bpm |
| now 07:18 | **80.0** | **7.41** | **12.0 (capped)** | **68 bpm** | 92 bpm |

Re-simulated over the same 132,880-sample histogram:

| | calm | moderate | high |
|---|---|---|---|
| what I simulated and shipped | 65.6 % | 28.4 % | 6.0 % |
| **what it now produces** | **14.5 %** | **80.7 %** | 4.8 % |

A calm edge of 68 bpm sits at roughly this wearer's **p8**, so ~92 % of waking life reads
Moderate-or-above. That is the **old 95 %-Medium failure mode** the project already fixed once, and the
exact opposite of the "keep Calm-dominant" behaviour the user chose.

**Root cause of my error:** I anchored the midpoint on the learned center, having verified it only at a
moment when that center happened to sit at the wearer's p90. When it drifts down to ~p73 the midpoint
lands mid-distribution, and a mid-distribution midpoint puts half the mass above it **by construction**
— the precise failure I identified and rejected during simulation, then reintroduced through a volatile
anchor. `spread * 2` hitting the 12 cap widened it further.

**The app already holds the stable input I should have used:** `stress.awakeBaseline.v1` carries per-day
quiet-awake histograms over 12 days (132,880 samples). Zone edges derived from that distribution's own
percentiles — e.g. calm edge near p70, high edge near p96 — would be stable, self-calibrating, and
express "calm-dominant with reachable High" directly.

Not shipping another guess at hour six on a metric the user is watching. Surfaced to the user with the
options rather than silently re-tuning.

## AT. Stress scale RE-ANCHORED on the wearer's own 12-day distribution (user's choice)

Replaced the volatile 45-minute `(center, spread)` anchor with percentiles of the multi-day quiet-awake
histogram the app already stores. `AtriaAwakeBaselineArchive.zoneEdges(calmPercentile:highPercentile:)`
pools every qualifying day (>= 30 samples) and returns the wearer's **p70** and **p96** as the
calm/moderate and moderate/high edges. `AwakeReference` now carries those edges;
`zoneMidpoint` and `zoneHalfWidth` fall out of them, and because `3*sigmoid(-ln2) = 1` and
`3*sigmoid(+ln2) = 2` the zone boundaries land **exactly on those percentiles**.

**Why this cannot drift the way my first attempt did:** `calmPercentile` IS the calm fraction by
definition. "Calm-dominant with reachable High" is now expressed structurally rather than hoped for from
where a moving center happens to sit.

Verified against the device's own 132,880 samples over 12 qualifying days: **p70 = 80, p96 = 92 ->
midpoint 86, halfWidth 6 -> 69.1 % calm, 26.0 % moderate, 4.8 % high.** Inside the band the user chose.

Two of my own earlier tests failed and both were right to: they asserted the 45-minute reference forks
the kernel, which is precisely what this stops. Migrated to assert the opposite — the volatile tuple now
has **no** effect, while the multi-day archive does. The seeding test likewise flipped to
`XCTAssertEqual`: `minimumQualifyingDays = 3`, so **one warmed day no longer personalises the scale**,
which is exactly the conservative property the drift regression proved was missing.

`AtriaStressMonitorTests` + `AtriaPhysiologicalStressModelTests`: **88/88 green**.

Not yet installed — the device still runs the fragile version, so this needs a build+install before the
scale is right on the phone.

## AU. Re-anchored scale INSTALLED and verified live — 69.2 % calm on the real archive

Built at `77101667`, symbols verified (`zoneEdges` / `calmEdge` present), installed and launched 07:57.

Computed the edges from the **live** on-device archive as it now stands:

```
12 qualifying days, 133,300 samples
p70 = 80   p96 = 92   ->  midpoint 86, halfWidth 6
=> calm 69.2 %   moderate 26.0 %   high 4.8 %
```

The archive has grown since the fix was written (132,880 -> 133,300 samples) and the derived edges did
**not move**. That is the stability property the percentile anchor was chosen for, demonstrated rather
than argued: under the old center/spread anchor the same six hours moved the calm edge 79 -> 68 bpm.

The regression is closed on device, and the scale now sits in the band the user chose.

Also confirmed this launch: `reclaimed 0.0 MB` in the storage receipt — the orphan sweep is correctly
**idempotent**, having already taken its 39.9 MB and finding nothing left to take.

Device otherwise healthy: HR live, `stallReconnects` still 331, backlog down to **2.40 h**.

## AV. Item 10 CORRECTION — stages are not "structurally unreachable"; they produce on 19 % of nights

Verified against `daily-metrics.json` rather than reasoning about gates. Stages DO produce:

| nights with stages | segments |
|---|---|
| 08-11 | 50 |
| 08-12 | 302 |
| 08-14 | 86 |
| 08-15 | 104 |
| 08-18 | 160 |

**5 of the 26 nights that have a sleep duration produced stages — 19 %, not zero.** I described item 10
as stages being "structurally unreachable" and "fail-closed" on this strap. That was too strong. The
user's complaint stands as an experience — 81 % of nights come back blank — but the mechanism is
intermittency, not impossibility.

**Duration is definitively NOT the discriminator**, which rules out the obvious explanation:

```
08-16   650 min of sleep  ->   0 segments
08-14   189 min of sleep  ->  86 segments
```

A 10.8-hour night produced nothing while a 3.2-hour night produced 86 segments. What tracks instead is
**RR/HR continuity**, the same variable that governs HRV (entry AD). The one night with detailed session
telemetry is decisive: 08-18 had the lowest dropout rate measured (2.1 %, longest clean run 1377 s), and
it is the night that produced BOTH 160 stage segments AND the only HRV value in 38 nights.

So items 8, 10 and the HRV gap share one upstream cause — BLE dropouts fragmenting an otherwise dense
stream — and the link-stability fix (items 1/2/3) is the lever for all three.

Gate B (`maximumHeartRateGap` 15 s -> 90 s) went on device at 04:05 and has not yet met a night; its
effect is measurable on tonight's sleep. Against a 4 % dropout rate the 90 s window admits roughly six
times more of a segment than 15 s did, so it should raise that 19 % materially — but that is a
prediction, and the next iteration should check it rather than assume it.

## AW. Drain is converging — 2.44x realtime, full catch-up due ~09:37

Backlog trace across the session:

```
02:19  4.75 h      (just after the item-1/2/3 fix relaunch)
02:56  4.40 h
06:04  6.19 h      <- grew while materialization held the lane (entry O)
07:26  3.17 h
07:57  2.40 h
08:03  2.28 h
```

Recent window 07:26 -> 08:03: **53 minutes of backlog cleared in 37 minutes of wall clock**, i.e. net
closure **1.44 min/min**, frontier advancing **~2.44x realtime**. At that rate the remaining 2.28 h
converges around **09:37** — the first time this device will be fully caught up since the 08-18 stall.

Note this is materially faster than the **1.53x** I measured at 02:19-02:56 and corrected the ETA to
back then. The difference is the materialization park (entry O) that was holding the lane in the early
hours; with that cleared the drain runs closer to the 2.37x first burst. My 05:47 and 10:54 ETAs were
both wrong for the same reason — I extrapolated a rate measured during contention.

## AX. Item 5 fix installed but NOT yet exercised — recording that honestly

`atria.notification.sleepReview.notifiedCountByStart.v1` is **absent** on device. That is expected, not
a failure: the key is only written when a sleep-review notification is actually delivered, and none has
fired since the install (no reviewable night today yet). The pre-existing
`notifiedEndByStart.v1` holds 8 entries, correctly bounded at `maximumTrackedStarts = 8`, and the
`scheduleCount` keys still number 60 with the newest dating to 08-18 — no new deliveries.

So the per-episode cap is shipped and installed but **unverified in the field**. Tonight's sleep is its
first real test, alongside gate B and the event-bound review delivery. Recording this rather than
implying the fix is proven.

## AY. Memory consolidated to the CORRECTED state

The durable memory files were written around commit 14 and several headline conclusions have since been
reversed. Rewrote them so a future session inherits the corrections rather than the first drafts:

- `atria-field-report-2026-08-19` now lists **seven** plausible-but-wrong fixes, not three — and names
  the two that were **my own shipped regressions** (the retention marker that could only run after the
  condition it fixed; the stress v4 anchor that drifted to 80.7 % moderate). It also carries the
  single-most-useful model to inherit: items 8, 10 and the HRV gap share ONE upstream cause (BLE
  dropouts fragmenting an otherwise dense RR stream), so the link-stability fix is the lever for all
  three.
- `atria-recovery-state-defect-class` goes from four instances to **six**, adding the foreground-only
  nap catcher and the range-loss clear that needs a window which no longer exists — and records that I
  reproduced the bug while fixing it.
- Both index lines updated; the old "14 commits / FOUR wrong fixes / 4 instances" framing is gone.

Also corrected in memory: the HRV gate must NOT be widened (`maxReadyRRGapSeconds`), the drain rate must
never be extrapolated from a window measured during materialization contention, and
`rawActivation = score / 3` so zone edges sit at 1/3 and 2/3.

## AZ. Monitoring pass — nothing to change, everything on track

Deliberately a short iteration. All 15 items have dispositions and the remaining work is device-gated,
so manufacturing a change here would add risk without value.

```
08:12  lastHR 0.3 min ago   frontier 08-19 06:06   backlog 2.11 h
       stallRe 331 (unchanged since 02:11)   keepalive history_transport_owned
       R10 pure_hr_v10/fallback_active  imu=0  requalifyAt 08-19 04:04
       proofDisconnectHistory: 0 entries
```

Drain over the longer 07:26 -> 08:12 window: 64 min of backlog cleared in 46 min wall, net
**1.38 min/min**, converging **~09:44** (my earlier 09:37 was computed off a 37-minute window; the
longer baseline is the better estimate).

`proofDisconnectHistory` at 0 entries is CORRECT, not a failure — the ring only fills on a proof
disconnect, and the next R10 requalification is not due until ~16:05 (12 h after 04:04).

### Open checkpoints, in order

| when | what it tests |
|---|---|
| ~09:44 | drain fully caught up — first time since the 08-18 stall |
| ~11:58 | first identity-retention prune (the 2.13 GB) |
| ~16:05 | second R10 proof sample, into the new forensic ring |
| tonight | gate B (90 s), item 5's per-episode cap, event-bound review delivery, background nap catcher — all meet a real night for the first time |

## BA. Loop re-paced 5 min -> hourly, and the checkpoints written into the prompt

`08:17  lastHR 0.2 min  frontier 08-19 06:18  backlog 1.98 h  stallRe 331` — first time under two hours.

The 5-minute cadence was right while there was code to write. It is wrong now: all 15 items have
dispositions and the nearest checkpoint is ~90 minutes out, so a 5-minute loop would fire ~18 no-op
passes before anything could possibly report. Replaced job `f15fbb2a` (every 5 min) with `834f47fa`
(hourly at :23).

Hourly still catches every checkpoint within an hour of it landing, and the new prompt carries the
checkpoint table plus an explicit instruction: **if nothing has reported, keep the pass short — one
device read, report, hold, and do not manufacture code changes.** That instruction exists because the
failure mode from here is inventing reasons to touch code, not missing a signal.

To restore the fast cadence: `CronDelete 834f47fa`, then re-run `/loop 5min …`.

## BB. Checkpoint REPORTED and contradicted my prediction — the drain re-parked, it does not converge monotonically

First hourly pass. The ~09:44 convergence estimate is **retracted**.

```
07:26  3.17 h      08:12  2.11 h
08:03  2.28 h      08:17  1.98 h   <- low-water mark
                   08:38  2.16 h   <- GREW back
```

08:17 -> 08:38: 21 min of wall clock, backlog **grew 11 minutes**. The frontier advanced only 10 min in
21, i.e. **0.49x realtime — losing ground.** `syncStatus = deferred_terminal_materialization`: the same
park as entry O, which held the lane for 47 minutes in the early hours.

**Corrected model.** The drain does not converge steadily toward a predictable ETA. It oscillates
between two regimes:

| regime | rate | driver |
|---|---|---|
| draining | ~2.4x realtime | materialization idle, lane free |
| parked | ~0.5x realtime | `deferred_terminal_materialization` holds the lane |

Every ETA I have given (05:47, 10:54, 09:37, 09:44) assumed the draining regime persists. All four were
wrong for the same reason: **I kept extrapolating a rate from whichever regime happened to be active
when I measured.** The honest statement is that catch-up time is not predictable from a spot rate — it
depends on how much materialization work is queued, which is itself a function of the archive size.

That is not a new defect. It is the O/AW behaviour, now seen twice, and it strengthens the case that
item 12's retention work (archive size) is the real lever on item 1's catch-up latency — not drain
tuning.

Also noted: `stallReconnects` 331 -> **332**, the first increment since 02:11. One reconnect in 6.5
hours against 323 in the four hours before the fix. Not a regression; recording the datapoint.

**No code change.** This is a measurement that corrects a prediction, which is what the checkpoint was
for.

## BC. Frontier frozen while work IS happening — item 2's symptom in a third form

Pushed everything through `65df64c8`; loop re-paced to 10 minutes (`c359e608`) at the user's request.

`08:57  frontier 08-19 06:29 — UNCHANGED since 08:38, backlog 2.16 -> 2.47 h`

Ran the same is-it-wedged test as entry O. Container diff 07:20 -> 08:58 (98 min):

| directory | 07:20 | 08:58 | delta |
|---|---|---|---|
| segments (raw) | 707 | 715 | **+8** |
| aggregates-v2 | 360 | 364 | +4 |
| retention-manifests-v2 | 360 | 364 | +4 |
| consumer-receipts-v1 | 801 | 833 | **+32** |

**So nothing is wedged.** Raw is still being drained to disk (+8 segments), aggregates are still being
built (+4, roughly one per two new segments), and receipts are still being written (+32). The rate is
far below entry O's +126 aggregates/107 min, but that window was burning a post-relaunch backlog; +4
against +8 new segments is steady-state, not a crawl.

**What is NOT advancing is `drainedThroughUnix` — the value the UI shows as "last sync".** Raw arrives,
aggregates build, receipts land, and the user-visible frontier sits still at 06:29 while wall clock runs
to 08:57.

That makes **three distinct mechanisms** now identified behind item 2's single symptom:
1. the silent-stream central-rebuild latch (fixed, `47538c32`)
2. terminal-materialization deferral parking the drain lane (entry O)
3. **this** — the frontier not advancing even while the materialization it defers to is productive

**No code change.** The frontier/publication gate is the least-understood part of this subsystem, this
session has twice punished confident changes to things I had not fully traced, and I do not yet know
whether a stalled frontier here is a defect or an honest "publication checkpoint not yet reached". The
next iteration should trace what actually advances `drainedThroughUnix` before anything is touched.

## BD. Traced the frontier — my "third mechanism" was a CONSEQUENCE, not a mechanism

Followed the explicit next task from BC before touching anything. `drainedThroughUnix` is advanced in
exactly one meaningful place, `commitDurableHistoricalRawFrontier` (AtriaBLEManager.swift:37370), and
its first line is:

```swift
guard offlineHistoricalSyncInProgress,
      generation == offlineHistoricalSyncGeneration else { return }
```

**The frontier can only advance while an offline historical sync is actually running.** The device sits
at `lastStatus = deferred_terminal_materialization`, which is set on the path that returns `false`
WITHOUT starting a sync (AtriaBLEManager.swift:10988). So while materialization holds the lane, no sync
runs, and therefore no frontier commit is even attempted.

**That corrects my own model from BC.** I reported three distinct mechanisms behind item 2's symptom.
There are **two**:

1. the silent-stream central-rebuild latch — fixed, `47538c32`
2. terminal-materialization deferral parking the drain lane — and the frozen frontier is its
   **consequence**, not a separate fault

It also explains the apparent contradiction that raw segments kept arriving (+8) while the frontier
froze: those are LIVE capture writes, which do not go through the historical-sync path. Live data flows;
history catch-up is what stalls. The user sees "last sync" stuck precisely because `drainedThroughUnix`
tracks the history drain, not the live stream.

**Still no code change, and now for a better reason than caution:** the frontier behaviour is CORRECT
given a deferred sync. Making it advance independently would be a lie — it would report catch-up
progress that did not happen. The real target is the deferral itself, i.e. reducing the materialization
work that steals the lane, which is exactly what item 12's retention does. This strengthens the BB
conclusion rather than opening a new front.

`09:04  frontier 06:29 (unchanged)  backlog 2.58 h  deferred_terminal_materialization`

## BE. Monitoring trace (no-op passes consolidated here)

Rather than a new lettered entry per 10-minute pass, holding passes append a row. A pass only earns its
own entry if something changes materially.

| time | frontier | backlog | syncStatus | note |
|---|---|---|---|---|
| 08:17 | 06:18 | 1.98 h | draining | low-water mark |
| 08:38 | 06:29 | 2.16 h | deferred_terminal_materialization | park begins; stallRe 331 -> 332 |
| 08:57 | 06:29 | 2.47 h | deferred | container diff proves work IS happening (+8 segments, +4 aggregates, +32 receipts) |
| 09:04 | 06:29 | 2.58 h | deferred | frontier trace done (BD) |
| 09:14 | 06:29 | 2.75 h | deferred | park 36 min |
| 09:24 | 06:29 | 2.92 h | deferred | park **46 min**; flushDebt 1688 -> 767, so debt IS being worked off |
| 09:34 | 06:29 | 3.08 h | deferred | park **56 min** — EXCEEDS the 47-min precedent; flushDebt frozen at 767 |
| 09:44 | 06:29 | 3.25 h | deferred | park 66 min; flushDebt still 767; no change from 09:34 |
| 09:54 | 06:29 | 3.42 h | deferred | park 76 min; flushDebt still 767; unchanged |
| 10:04 | 06:29 | 3.59 h | deferred | park **86 min** — now nearly 2x the 47-min precedent; scene last active 08:04 |

**Diagnostic available but NOT taken.** `historicalConsumerMaterializationInFlight` is a process-local
`var`, so a relaunch clears it unconditionally — which is what ended the 02:11 park. That makes a
relaunch a clean discriminator: if the frontier resumes immediately afterwards, this is a process-local
wedge and the **fourth** instance of the recovery-state defect class; if it re-parks straight away, the
queued materialization work is real.

Not doing it unasked. A relaunch is a device action, it destroys the evidence that would let anyone
diagnose this properly, and the user may be using the phone (scene last active 08:04). Offered instead.

| 10:14 | 06:29 | 3.75 h | deferred | park 96 min |
| 10:24 | 06:29 | 3.92 h | deferred | park 106 min; lane-ceiling fix written |
| 10:37 | 06:52 | 3.75 h | — | **park self-resolved after ~112 min**, before the fix could install |
| 10:39 | 06:52 | 3.77 h | terminal_consumer_materialization_deferred_raw_first_slice | lane ceiling now installed |
| 10:44 | 06:52 | 3.85 h | **deferred_terminal_materialization** | park re-entered ~7 min post-install — first live test of `dd79df63` |
| 10:54 | 06:53 | 4.01 h | deferred_terminal_materialization | **1 min of frontier in 10 min = 0.10x realtime** — sharpest measure yet of what the park costs |
| 11:04 | 06:53 | 4.18 h | deferred_terminal_materialization | frontier UNCHANGED; ceiling not observed firing at the edge of its window |

### The ceiling may be the defect class again — unproven, flagged early

Two facts from 11:04, neither of which I want to soften:

1. `releaseMaterializationLaneIfHeldTooLong` has exactly **one** call site
   (AtriaBLEManager.swift:11093, the deferral site). It can therefore only run when a sync attempt
   re-enters that path.
2. Every `atria.offlineSync.*` key is **byte-identical** between the 10:44 and 11:04 pulls — status,
   reason, all timestamps. Twenty minutes, no writes.

The process is demonstrably alive: HR arrived 0.5 min before the pull. So this is not suspension.

If sync attempts are not re-entering during a park, then a timeout evaluated only at the deferral
site cannot fire — which would make my own fix an instance of
[[atria-recovery-state-defect-class]]: *a recovery bounded by the very path it is meant to unblock.*
That would be the second time this session I reproduced the shape while fixing it.

**This is not proven.** A re-entry that rewrites identical values is invisible in a plist diff, so
fact 2 is consistent with both readings. The deciding observation is the ~11:10 threshold I set in
advance: frozen past it, and the placement is wrong. I am not changing code on an inference I have
already been burned by once today.

| 11:14 | 06:58 | 4.26 h | **armed** | park ended — but see below, it is NOT attributable to the ceiling |

### Verdict on the ceiling: UNPROVEN, and my 11:04 reasoning had a hole

The park ended between 11:04 and 11:14 and the frontier moved again. That lands inside the ceiling's
eligibility window, so the tempting read is "it fired". It is not supported.

`durableProductiveSliceReceipt.processInstanceID` changed
`0FAE7AFB-…` → `54B93EA6-…`, with `recordedAtUnix` 11:13:55. **The app relaunched inside the same
window.** `historicalConsumerMaterializationInFlight` is process-local, so a relaunch clears it
unaided — which is precisely the pre-fix behaviour the doc comment describes as "holds the lane until
the process dies". Ceiling and relaunch are indistinguishable here, and the simpler explanation is
already sufficient.

This is the trap written down at 10:44 as outcome 2, arriving in a form I had not predicted (a
relaunch rather than a self-resolve). Writing the outcomes in advance is what stopped it being scored
as a win.

**A hole in my own 11:04 argument, too.** I filtered the plist keys on `Attempt` (capital A), which
silently excluded `atria.offlineSync.attempts`. It was frozen at 23680 from 10:39 through 11:04 and
then jumped +9 by 11:14 — but that does NOT prove the absence of re-entry either, because the
increment at AtriaBLEManager.swift:13743 sits downstream of the deferral guard, so a park is expected
to freeze it. The re-entry question remains genuinely open.

### The instrument that was missing (`AtriaBLESchema.swift`, `AtriaBLEManager.swift`)

The reason today's firing is undecidable is that the release path logged **only** to `ATRIADBG`,
which is stdout and unrecoverable after the fact. A fix whose firing cannot be observed cannot be
trusted, and every future firing would have been just as ambiguous.

Added `atria.offlineSync.materializationLaneCeilingReceipt.v1`: a counted, durable receipt
(`atUnix`, `heldSeconds`, `ceilingSeconds`, `count`). The count is the part that matters — it
separates "fired once, correctly" from "is truncating the same work over and over", which is the
failure mode of a ceiling set too low.

### A wrong claim in the shipped comment, corrected

The ceiling's own doc comment justified 20 minutes with "the longest productive run was ~47 min" —
which is false twice over. The 47- and 56-minute figures in this ledger are **park** durations
(entries at lines 377/1591/1699), not healthy work; and 47 min would *exceed* a 20-minute ceiling,
not sit comfortably inside it. The same wrong sentence had been copied into the test.

The honest statement, now in both places: **no healthy materialization has ever been timed on
device.** The 20-minute bound is set from the failure side — every observed park (47, 56, 106, 112
min) is well past it — and if a legitimate run is ever measured above 20 min the constant is wrong
and must rise. The new receipt is what would make that visible instead of silent.

428/428 green in `AtriaBLERecoveryCadenceTests`.

| 11:24 | 07:00 | 4.39 h | armed | lane free, attempts climbing 23689 -> 23705, but only 2 min frontier in 10 |

Worth noting against the "lane free means fast drain" assumption: the lane IS free, sync attempts are
climbing normally, and the frontier still advanced only 2 minutes in 10 (0.20x). So the 2.4x figure
in the loop brief is not what a free lane guarantees — it was one favourable window. `durableRowsDelta`
is 0 on the current slice, so this process has not yet committed productive rows. Not diagnosing it
from one sample; recording it so the next free-lane window has something to compare against.

### Pre-prune baseline, measured 4 minutes before it is due (11:54)

| artifact | size | mtime |
|---|---|---|
| `historical-archive.identity.jsonl` | **1.28 GB** | 11:51 |
| `historical-archive.identity.lookup-v1.sqlite` | **839.7 MB** | 11:51 |
| `…sqlite-wal` / `-shm` | 302 KB / 32 KB | 11:51 / 11:54 |
| `historical-archive.identity.prune.json` | 38 bytes | **05:58** (unmoved) |

The ledger is still GROWING (1.27 → 1.28 GB) right up to the prune, and both primary artifacts were
written 3 minutes ago, so this is a live baseline rather than a stale one. That matters for reading
the result: any post-prune shrink has to be scored against 1.28 GB, not against this morning's 1.27 GB
figure, or the reclaim will look larger than it was.

Drain meanwhile is deferring under a THIRD distinct reason today, `deferred_live_continuity_owner`
(the drain yielding to live capture) — not the materialization park. Frontier 07:04 → 07:07 across
11:33–11:54, attempts creeping 23717 → 23725. Recorded, not diagnosed: the deferral reasons have
rotated all morning and one 20-minute window cannot separate healthy live-capture priority from
another park wearing different clothes.

## CHECKPOINT REPORTED — the first identity-retention prune fired at 11:58:46

`prune.json` → `{"lastPruneAtUnix": 1787120926.156039}` = **08-19 11:58:46**, six hours and forty-six
seconds after the 05:58 bootstrap stamp. Item 12's retention tiering has now executed on the device
for the first time.

This closes the loop on the bug I shipped and had to fix: `32f4e598` wrote the marker only from
inside a *completed* prune, so it needed six hours of unbroken process uptime that iOS never grants.
`476ffed8` moved the stamp to init. The marker then survived five installs, and today it did the
thing it exists to do — fire on a wall clock rather than on process luck. Persisting through
relaunches was necessary evidence; **firing** is the sufficient evidence, and only now do I have it.

### The streaming compaction is running right now

    .historical-archive.identity.jsonl.compact.0CC8F9A4-….tmp   565.6 MB   12:00   (hidden)
    historical-archive.identity.jsonl                           1.28 GB    11:58
    historical-archive.identity.lookup-v1.sqlite                839.7 MB   11:59
    …sqlite-wal                                                 Zero KB    11:59   (checkpointed)

That temp file is `compactIdentityIndexOutsideHorizonLocked` streaming in 64 KiB chunks — the design
that broke the "too big to load, therefore too big to compact" deadlock. It is the first proof the
streaming path runs against a real 1.28 GB ledger instead of a fixture.

**No reclaim figure yet, deliberately.** The temp is still being written; 565.6 MB is a partial, not
a result. Dividing it against 1.28 GB right now would produce exactly the kind of number I have had
to retract four times today from spot rates. The figure to report is the *final* temp size at the
moment it replaces the source.

One thing already worth flagging: during compaction the source and the temp **coexist**, so peak disk
is source + temp — up to ~1.85 GB of the container committed to one artifact mid-prune. On a device
the user already considers over-full at 5 GB, a retention pass that transiently grows the footprint is
worth stating plainly rather than discovering later.

The WAL going to Zero KB at 11:59 says the sqlite side checkpointed as part of the same pass.

## The prune's real outcome: it LEAKED 565.6 MB, and the storage number is under-reported

Follow-up at 12:13–12:15 turned the checkpoint from a success into two defects — both mine, both
shipped this morning.

### 1. The compaction was killed mid-stream and permanently orphaned its temporary

    .historical-archive.identity.jsonl.compact.0CC8F9A4-….tmp   565.6 MB   mtime 12:00  (UNCHANGED at 12:13)
    historical-archive.identity.jsonl                           1.28 GB    mtime 12:13  (still being appended)
    reclaimedBytes                                              0

`processInstanceID` moved 54B93EA6 → 181EA23D: the process was replaced around 12:00, mid-write.

`compactIdentityIndexOutsideHorizonLocked` removes its temporary on exactly three paths — a thrown
error, a `dropped == 0` no-op, and the successful `replaceItemAt`. **All three require the compaction
to conclude.** A process killed mid-stream runs none of them, and the filename carries a fresh
`UUID()`, so the next attempt does not reuse the file — it adds another one.

Nothing else collects it. `sweepOrphanedArtifacts` walks only the Documents debug logs and
`FileManager.temporaryDirectory`, and passes `.skipsHiddenFiles` — so a dot-prefixed file in the
archive directory is invisible to it twice over.

So the retention feature built to *reduce* the user's 5 GB can *add* up to ~1 GB per interrupted run,
every 6 hours. That is item 12 made worse by the fix for item 12. It is also, once again, the shape
this whole report keeps finding: **cleanup bound to a completion that did not happen.**

**Fixed** (`AtriaHistoricalArchiveDurableStore`): `sweepStaleIdentityCompactionTemporaries` runs at
store init, matching `.<index>.compact.<UUID>.tmp` with a 30-minute age gate — our own compaction
cannot be running at init, so the gate only protects a hypothetical second container client. Future
mtime is treated as clock skew, absent mtime as stale, and non-matching names are never touched.

### 2. The inventory the user sees under-reports by 1.34 GB

Summing the container's own file listing against the inventory recorded at 12:10:53:

| source | bytes |
|---|---|
| container file listing (3641 files) | **6.32 GB** |
| `debug.managedStorageInventory.v1` total | **4.98 GB** |
| gap | **1.34 GB** |

The gap decomposes almost exactly: the 565.6 MB orphan above, plus the **839.7 MB
`historical-archive.identity.lookup-v1.sqlite`, which appears in no category path at all**
(4.98 + 0.57 + 0.84 = 6.38 GB against 6.32 GB measured, inside the rounding of devicectl's
one-decimal sizes). The `archive_identity_and_manifest` category lists two files — the manifest and
the identity index — and the lookup database was simply never added.

Item 12 opens with "I'm not really confident on the data size". The app's own answer to that question
was wrong by 27%. **Fixed**: the lookup database is now in `categoryPaths`; `allocatedBytes` already
folds in its `-wal`/`-shm` sidecars.

36/36 `AtriaHistoricalArchiveDurableStoreTests`, 14/14 `AtriaHandoff13Tests`.

### What the prune did NOT tell us

No reclaim figure exists yet — `reclaimedBytes` is 0 and the index is unchanged at 1.28 GB, because
the compaction never finished. The question "does a smaller archive stop terminal materialization
stealing the drain lane" is therefore still unanswered, and stays on the checkpoint list.

**Correction:** an earlier line here said this moves to "the 14:00 prune". That was wrong — the
interval is six hours (`AtriaHistoricalArchiveDurableStore` line 836), so from the 11:58:46 stamp the
next prune is **17:58**, not 14:00.

### Installed at 12:27 — and the sweep correctly did NOT fire

Both pending fixes are now on the device (`3d4a6f3a` receipt, `bb429531` sweep + inventory).
Build succeeded, installed, relaunched at 12:27.

The orphan is still there:

    .historical-archive.identity.jsonl.compact.0CC8F9A4-….tmp   565.6 MB   mtime 12:00   STILL PRESENT

That is not a failed fix. The temporary's mtime is 12:00 and the launch was at 12:27–12:28 — **28
minutes old against my own 30-minute age gate**. The sweep declined it, which is exactly what the
gate is for. Verification therefore needs a store init after 12:30, i.e. the next relaunch.

Recording this before re-checking so it cannot be quietly rewritten later: the *pass* condition is
the file being gone after a post-12:30 launch. If it survives that, the fix is wrong and the cause is
something else — a lazily-constructed store whose init is not reached, or a failed `removeItem`.

It is worth being blunt that a 30-minute gate is a real cost here: an orphan is not collected by the
*next* launch, only by the next launch 30 minutes after the leak. Given how often this process is
replaced that is acceptable, but it is a deliberate trade, not a free one.

Container unchanged at 6.321 GB across 3603 files (down from 3641 — unrelated sidecar churn, not the
orphan).

## VERIFIED on device 12:32 — the sweep reclaimed 565.6 MB

Relaunched at 12:32:45, with the orphan 32.5 minutes old and therefore past the 30-minute gate.
The pre-registered pass condition was "the file is gone after a post-12:30 store init":

    12:32:33  .historical-archive.identity.jsonl.compact.0CC8F9A4-….tmp   565.6 MB   PRESENT
    12:32:45  relaunch
    12:32:56  (no compaction temporaries)                                            GONE

| measure | before | after |
|---|---|---|
| container (summed file listing) | 6.321 GB | **5.760 GB** |
| delta | | **−561 MB**, matching the 565.6 MB file inside rounding |

File *count* rose 3603 → 3679 over the same window, so this was not a general cleanup — one large
file went away while ordinary sidecar churn continued.

### The inventory fix landed too

`archive_identity_and_manifest` went **1508.7 MB across 2 files → 2409.3 MB across 5 files**: the
lookup database plus its `-wal` and `-shm`, exactly the +900.6 MB and +3 files predicted. Reported
total 4.977 GB → 5.884 GB.

The residual against my 5.760 GB container sum now runs the *other* way (inventory higher by
0.124 GB), which is what binary-vs-decimal unit conventions predict: devicectl prints "1.28 GB" for a
file I counted as 1.28e9 bytes but which is 1.374e9 if the unit is GiB — a ~94 MB undercount on that
file alone. So the earlier 1.34 GB gap was far outside unit noise and real; this residual is inside it
and is not a defect.

### One more honesty gap, closed

`reclaimedBytes` still read **0** at 12:32:46 despite 565.6 MB having just been reclaimed, because
the store's init sweep does not feed the inventory's counter — only
`AtriaManagedStorageInventory.sweepOrphanedArtifacts` does. A user checking the storage screen after
this morning's leak would have been told nothing was recovered.

`sweepOrphanedArtifacts` now also sweeps the archive directory's compaction temporaries, so their
bytes land in `reclaimedBytes`. The sweep is idempotent, so running from both the store init and the
inventory pass is harmless. **Not yet installed** — it needs another orphan to exercise it, and there
is none on the device now.

51/51 across `AtriaHandoff13Tests` + `AtriaHistoricalArchiveDurableStoreTests`.

## The marker is stamped BEFORE the work it records

Chasing when the next prune is due surfaced the reason today's compaction will not simply be retried.

`pruneExpiredIdentitiesLocked` sets `lastPruneAtUnix` and calls
`persistLastPruneAtUnixBestEffort()` **before** the compaction it authorises runs. So a prune killed
mid-stream still advances the clock a full six hours, and the index it failed to compact is not
revisited until then — while the sidecar records the prune as having happened.

That is exactly today's sequence: marker stamped 11:58:46, compaction killed ~12:00 having written
565.6 MB, next attempt not due until **17:58**. On a device whose process is replaced as often as this
one, a compaction needing several uninterrupted minutes can be starved indefinitely while retention
bookkeeping reports normal operation. It is the same family as everything else in this report, with
the polarity flipped: instead of a recovery blocked by the success it needs, here the **success
marker is written before the success**.

**Fixed.** The orphaned temporary found at init is precise evidence that the previous compaction did
not conclude, so it now also pulls the retention clock forward:
`retentionClockAfterInterruptedCompaction` sets the marker so the next maintenance pass fires 30
minutes out instead of six hours, bounded to **3 consecutive fast retries** — a compaction that dies
every time must not rewrite hundreds of megabytes every half hour forever. The counter lives in the
sidecar (absent in older files, which reads as zero) and resets when a compaction concludes.

**A bug I wrote and the test caught.** My first guard was `candidate > lastPruneAtUnix`, reasoning
that the clock must not move backwards. That is inverted: an *earlier* marker means *more* elapsed
time, which is what makes the prune due sooner. The guard rejected every real case and the helper
returned nil unconditionally. Corrected to `candidate < lastPruneAtUnix` — only ever shorten the
wait, never lengthen one that is already closer.

Worth stating plainly: that helper looked right, read right, and was exactly backwards. Only the
assertion on the *interval* — `now - marker == interval - retryDelay` — failed it. A test that had
merely checked "non-nil and counter incremented" would have passed a dead function.

74/74 across the three retention suites.

**Installed 12:55.** Post-launch state: no compaction temporaries, marker intact at 11:58:46, next
prune **17:58:46**. The sidecar still reads `{"lastPruneAtUnix": …}` with no
`interruptedCompactionRetries` field — which is correct, not a failed write: the field is only
emitted by `persistLastPruneAtUnixBestEffort()`, and neither a prune nor an interruption adjustment
happened at this launch. The loader treats an absent field as zero, which is exactly the
older-sidecar case it was written for.

Drain over 12:14 → 12:51: frontier 07:16 → 07:52, i.e. 36 minutes of frontier in 37 minutes of wall
(~0.97x), with backlog flat at 4.96 → 4.98 h. Keeping pace, not catching up. No park has occurred
since the ceiling landed, so `materializationLaneCeilingReceipt.v1` is still absent — the receipt is
armed and waiting, and its absence right now is the honest reading rather than a failure.

## Repo cleanup pass (user-requested): 8.73 GB → 1.4 GB

| removed | size | why it was safe |
|---|---|---|
| `build/` | 3.2 GB | gitignored build output, regenerable |
| `evidence/` payloads >5 MB (127 files) | 3.55 GB | all captured 2026-07-26…07-31; dominated by 81 oversized `sessions.json` and 10 `historical-archive.identity.jsonl` device pulls, every type superseded by newer copies in the live container |
| 3 clean git worktrees | 213 MB | `git worktree remove` deletes the checkout, **not** the branch — `claude/app-ux-ui-polish-a68d7e`, `claude/trusting-engelbart-3f1a5f` and `claude/relaxed-faraday-a4ad5c` were re-verified present afterwards |
| 27 stale worktree records | — | git itself marked them `prunable`; their directories were already gone |
| `logs/live-device` | 181 MB | gitignored, last written 2026-07-30 |
| `__pycache__`, stray `.tmp` | ~1 MB | build/scratch residue |
| my own scratchpad (`dd2`, `dd3`, 6 xcresult bundles) | 1.15 GB | superseded derived data and result bundles |

The removed evidence payloads are itemised with sizes in
[`.claude/evidence-pruned-2026-08-19.md`](evidence-pruned-2026-08-19.md) — `evidence/` is gitignored,
so a manifest written inside it would not have been version-controlled. The 66 `evidence/` citations
in `docs/WHOOP4_PROTOCOL_FINDINGS.md` still resolve: directory structure and all 13,936 small
analysis files were kept.

### Deliberately NOT removed

**Four worktrees with uncommitted edits.** `agent-a3ac32b3300f4a61d` (5 modified files including
`AtriaHealthScreen.swift` and `AtriaStressDetailView.swift`), `agent-a20fb84ef7bf7d604` (2),
`agent-aaf58d1f2586859da` (3), `design-consent-fdd4ed` (4). Their commits are all reachable, but the
working-tree edits exist nowhere else. That is the user's call, not mine.

**No tests were deleted, and the check that suggested otherwise was wrong.** Comparing
`AtriaTests/*.swift` against `project.pbxproj` reported **307 of 307 files "not in project"** — which
is not 307 orphans, it is a broken test. The target uses a `PBXFileSystemSynchronizedRootGroup`
(5 entries in the pbxproj), so files are included by directory membership and never listed
individually. Every one of those 307 files compiles and runs; we executed 428 cases from a single one
of them today. Acting on that grep would have deleted the entire test suite.

Only 6 `XCTSkip` sites exist across the whole suite, so there is no meaningful dead-test population
to remove.

### What 17:58:46 tests

The whole retention chain end to end, in one shot: does the compaction survive to completion this
time; if it does, how much does 1.28 GB actually shrink; if it is interrupted again, does the orphan
get swept, does `reclaimedBytes` finally report it, and does the clock pull forward to ~30 min
instead of six hours. Every retention fix from today converges on that single event.

**Install deferral, resolved.** The receipt from `3d4a6f3a` was committed but not on the device, so
the next park was unmeasurable. Installing before the prune would have relaunched the process ~30 min
ahead of the checkpoint this loop had waited on since 05:58. The receipt only pays off on a *future*
park; the prune happened once.

### First field test of the materialization lane ceiling

The park re-entered at or before 10:44, which is the first one to begin under the installed
20-minute ceiling. If the lane is genuinely held, `releaseMaterializationLaneIfHeldTooLong` should
fire around **11:01–11:04** and the frontier should start moving again without a relaunch.

That is a real prediction with a falsifiable time, and it is worth being precise about what each
outcome means:

- frontier advances near 11:04 → the ceiling fired; `dd79df63` works.
- frontier advances well before 11:00 → the park self-resolved again (as it did at ~10:30 after
  112 min), and the ceiling is still unproven — NOT evidence for the fix.
- frontier still frozen past ~11:10 → the ceiling did not fire at the deferral site, and the
  placement needs re-examining.

The middle case is the one I would most easily misread as success, so it is written down first.

**Prune marker survived a FOURTH relaunch** — `prune.json` still stamped 05:58 after the 10:37 install.
The retention clock has now held across installs at 06:26, 07:19, 07:26, 07:57 and 10:37 without ever
being re-seeded, so the wall-clock interval is thoroughly proven. Prune still due ~11:58.

## BF. Narrowed WITHOUT the relaunch — no timeout, and no failure to trigger the retry

Traced the escape paths for `historicalConsumerMaterializationInFlight` instead of intervening.

There IS a bounded retry: `scheduleTerminalConsumerDependencyRetry` re-arms
`resumePendingFullDrainPublicationIfNeeded` on a 15-minute
`terminalConsumerDependencyMismatchRetryInterval`, with a fingerprint-based suppression guard. At 96
minutes that is ~6 windows, so the obvious question is why six retries have not cleared it.

**Device answer: the retry has not been firing, because nothing has failed.**

```
terminalArchiveFailureAt.v1   08-19 01:07:33  — 547 min ago, UNCHANGED through the whole park
terminalConsumerDependencyMismatch.v1  present (older .v1 schema)
terminalConsumerDependencyMismatchAt.v2  ABSENT
```

`scheduleTerminalConsumerDependencyRetry` is called from the terminal-archive-failure catch. No new
terminal failure has occurred since 01:07, so that retry never armed during this park.

**So the shape is now evidenced rather than guessed:** the flag is a process-local `var` with **no
watchdog and no timeout**; its 11 clear sites all sit on completion or failure paths; and the one
bounded retry that could rescue it only arms on a failure that is not happening. A materialization that
neither completes nor fails therefore holds the lane indefinitely — until the process dies.

That is the **fourth** instance of this report's recovery-state defect class, and unlike the earlier
three it is characterised from code plus device state without needing to destroy the evidence.

## BG. FIXED — a bounded ceiling on the materialization lane

Changed my mind on deferring this, for a reason that distinguishes it from the range-loss clear (AL):
**the failure modes are not comparable.** Clearing a range-loss ticket wrongly can drop genuine
unrecovered data. Releasing a stuck in-flight flag cannot — the release goes through the ordinary
`finishHistoricalConsumerMaterialization` path, every existing cleanup and re-arm runs, and the next
pass simply attempts the work again. Early release is the SAFE direction, and the lane was actively
costing the user item 2's symptom for 106 minutes and climbing (backlog 1.98 h -> 3.92 h).

Added `historicalConsumerMaterializationLaneCeiling = 20 min` plus
`materializationLaneHeldTooLong(startedAt:now:ceiling:)`, with the flag now stamping
`historicalConsumerMaterializationStartedAt` via `didSet` so the claim time cannot drift from the claim.

The reclaim is invoked **at the deferral site itself** — that is what made the hold self-sustaining:
every sync attempt saw the flag, deferred to it, and never asked how long it had been set. Now the
attempt reclaims a lane past its ceiling before deferring to it again.

20 minutes is generous against observation: the longest PRODUCTIVE materialization measured this session
was ~47 min, but that one completed and would never reach this path while progressing — the ceiling only
catches a lane that neither completes nor fails. Fails safe on a backwards clock.

`AtriaBLERecoveryCadenceTests`: **427/427 green**, including the exact 106-minute field case.

### BG-correction: the park SELF-RESOLVED before the fix could be installed

Built and installed at 10:37. Between the 10:24 read and the pre-install baseline the park **ended on
its own**: frontier moved 06:29 -> **06:52**, status left `deferred_terminal_materialization`. Total
hold ~112 min (08:38 -> ~10:30).

**So my stated mechanism was stronger than the evidence supported.** I wrote that a materialization
which neither completes nor fails "holds the lane until the process dies". It did not — it released
after ~112 minutes without a relaunch. What I actually proved is narrower and still real:

- there is **no timeout** enforcing an end (verified in code: 11 clear sites, all on completion/failure;
  the one bounded retry arms only from the failure catch)
- the observed hold was **112 minutes**, during which `drainedThroughUnix` — the user's "last sync" —
  was completely frozen and the backlog grew 1.98 h -> 3.92 h

The fix stands on that narrower claim: a nearly two-hour freeze of the user-visible sync clock is a real
defect regardless of whether it would eventually have cleared, and a 20-minute ceiling bounds it without
abandoning data. But I should not have asserted an unbounded hold, and `dd79df63`'s message says "until
the process died" — that phrasing overstates what was observed.

Post-install 10:37: frontier 06:52, backlog 3.75 h, `deferred_archive_warm` (a different, expected
post-launch state), flushDebt 1489, HR live, stallRe 332.

**Correcting my previous read.** At 09:24 I wrote that the park matching entry O's 47 minutes "looks
like a characteristic duration rather than a hang". It has now run 56 minutes and `flushDebt` has
stopped falling, so that reading was premature.

But the follow-up test is **less conclusive than I first treated it**. Container diff 08:58 -> 09:35
(37 min) shows `aggregates-v2 +0`, `segments +0`, `hr-index +0`, `consumer-receipts +5`. That looks
alarming next to the earlier +8/+4/+32, until you notice **file COUNTS are a coarse instrument here**:
segments rotate at 32 MB so live writes append to the existing file without creating one, and an
aggregate is built per SEALED chunk, so no seal in 37 minutes means no new aggregate regardless of
health. `+0` therefore does not prove a wedge.

What IS solid and did change: **`flushDebt` was actively falling (1688 -> 767) and has now frozen**,
alongside a park exceeding its previous duration. Receipts still tick (+5), so something is alive.

Honest position: this is no longer well described as a characteristic park, but I do not have evidence
sufficient to call it wedged either. Not acting on it — the ~11:58 prune is 2 h away and is the
intervention most likely to change this state anyway.

Next checkpoint remains the ~11:58 prune. No code change.

## Done this loop
- `32f4e598` **L**: identity retention now actually reclaims (items 12 part 1). 39/39 green.
- `3cc520a9` **I**: pure-HR fallback passive requalification (items 6/10 root) + item 9 reband + item 7
  lower bound + item 10 gate B. 80/80 green.
- `47538c32` **C**: silent-stream central-rebuild latch → interval-bounded permit (items 1/2/3). Test added.
- **D**: compact tri-ring stroke inset (item 14).
- Ledger + full device evidence capture.
- AtriaBLERecoveryCadenceTests **60/60 green, 0 errors**.
- Committed as `47538c32`.
- Launched workflow `wf_d58bdc20-521` to root-cause items 4,5,6,7,8+9,10,11,12,13,15 in parallel
  with two independent adversarial verifiers per finding.

## RECURRING DEFECT CLASS — worth a lint rule, not three more fixes

Three separate items in this one report reduced to the same shape: **state that gates recovery is
process-local, and the only thing that can advance it cannot happen in the state it gates.**

| item | field | could only be cleared by | why that never happened |
|---|---|---|---|
| 1/2/3 | `silentStreamCentralRebuildIssued` | a fresh accepted HR sample | a wedged session cannot produce one |
| 6/10 | `allowFallbackRequalification` | a manual workout intent live AT LAUNCH | passive wear never sets it |
| 12 | `lastPruneAtUnix` | 6 h of unbroken process uptime | iOS restarts apps far sooner |

All three were individually reasonable and all three were unreachable. Candidate rule: any field whose
purpose is to bound a RECOVERY action must be either persisted or interval-bounded, never cleared only
by the success it is blocking. Not acted on — flagged for the user.

## NEXT
1. Items 6/10: investigate `clean_owner_proof_disconnect` — the strap drops ~5 s after the R10
   activation command. This is now the ONLY thing between the user and working naps/stages.
2. Item 12 part 3 (compression DROPPED — see P): thread a cooperative deadline through `HistoricalArchive.compactArchiveConverging`
   (zero instrumentation today, see K), then lift `shouldExecuteArchiveWideMaintenance` and prune
   raw > 30 d.
2. Items 4, 5, 11 — all three have verified root causes in `.claude/field-report-root-causes.md`.
3. Item 8 (stress ceiling) and item 13 (insight engine).
4. Old item 12 retention tiers — raw `segments/raw-*.jsonl` are uncompressed and never pruned (2.99 GB),
   and `identity.jsonl` + its sqlite are 2.13 GB of unbounded dedupe bookkeeping. Insight tier is only
   ~93 MB, so a raw-retention window + compaction is safe. Also: `atria-memprobe*.log` (17 MB) and
   `tmp/*.png|html` share leftovers are never cleaned.
3. Item 6 nap detection — verify independently of the stall (the evening nap fell inside the 4 h dead
   window, so it may be starved rather than broken; prove which).
4. Items 8/9 stress, 10 stages, 5 duplicate sleep prompt, 11 notification timing, 4 midnight rings.

## Standing note
`offlineSync.rangeLossBackfillPending = true` since **2026-08-08 17:08** (10.6 days — see AK for the
correction to the 08-06 figure I originally quoted).
`scheduleStaleArmedRangeLossBackfillReconciliation` only clears statuses in
`["armed","archived","archive_metric_ready","throttled","no_rows"]`, but the live status is
`gap_retained_transaction_unverified` — so the reconciliation can never fire. Separate defect, worth
its own pass.
