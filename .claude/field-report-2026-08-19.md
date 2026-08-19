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
| 11 | Notifications never fire at the right moment | **2 of 5 FIXED** (T + Z) | workout class un-silenced; background nap-catcher now runs; (1)(3)(5) open |
| 12 | 5 GB+ data size, need raw/insight retention tiers | **PARTS 1 + 3 FIXED** (L + Y) | 2.13 GB dedupe tier (`32f4e598`); fence lifted + 30-day raw horizon; part 2 (compression) DROPPED on evidence (P) |
| 13 | Insight→suggestion engine | **INPUT DEFECT FIXED** (AB) | rebuild no longer erases measured restingHR (63%→ should approach 100%); engine-design half still open |
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
that anything is filling right now. On the field device it has been `true` since **2026-08-06, thirteen
days**, and the strap is worn/connected/streaming almost continuously, so the guard returned true
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
`offlineSync.rangeLossBackfillPending = true` since **2026-08-06** (13 days).
`scheduleStaleArmedRangeLossBackfillReconciliation` only clears statuses in
`["armed","archived","archive_metric_ready","throttled","no_rows"]`, but the live status is
`gap_retained_transaction_unverified` — so the reconciliation can never fire. Separate defect, worth
its own pass.
