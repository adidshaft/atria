# RUNNING GOAL — Fix strap step totals (WHOOP4), strap-only, without breaking live HR

## Goal (do not stop until this is true, verified on my physical device)
Make Atria's **daily strap step total reach the real number (~10k+ on an active day)** and
stay close to up-to-date, **strap-only** (no iPhone pedometer), by finishing the WHOOP4
historical flash drain. Prove it on-device with logs: steps climb from the stuck ~1,118
toward the real total **AND** live HR/RR never breaks during the drain. Steps are the
primary WHOOP metric — treat this as P0.

## Hard constraints (non-negotiable — these are my explicit decisions)
1. **Strap-only.** Do NOT add iPhone `CMPedometer`/phone steps for daily or workout steps.
2. **Never interrupt a HEALTHY live HR/motion epoch** to drain history. Live HR is the
   highest-priority owner at ALL times. (A prior "Build-5" attempt seized the link from a
   healthy epoch and cancelled live HR — do not reproduce that.)
3. Drain **only during the strap's natural disconnects / an already-idle-or-ending epoch.**
4. **Soak-driven & multi-session is fine.** Write a little → soak on device for real time →
   read telemetry → correct. Do not ship unsoaked BLE surgery. Do not fake completion.
5. Keep every gate flag-gated until soak-proven, so the default build is never at risk.

## Proven root cause (already established — do not re-litigate)
- The stuck step total is **app-side, NOT a hardware ceiling.** The flash HOLDS the steps.
- Device evidence: `historyDrainTelemetry stream5_rx=0 durable_rows=0`, `offline_sync
  status=deferred_realtime_continuity_owner` / `deferred_live_continuity_owner` — the drain
  is deliberately **deferred to protect the live 2A37/R10 epoch**, so history never streams.
- The strap can't do live HR + history on one link, and it drops the link (~15-20 s,
  CBError remote_range_loss) constantly, so the only safe drain window is a **natural gap**.
- The ACK protocol in the app is **integrity-safe** (persist-before-ack; `HISTORY_END`
  ACK withheld only on `orphan_not_archived`/`spool_open_failed`). Not the bug.

## Verified protocol (WHOOP4, from device + reference clients whoop-reader/noop/my-whoop)
- Service `61080000-8d6d-82b8-614a-1c8cb0f8dcc6`.
- Drain = `0x22 GET_DATA_RANGE` (returns newest/oldest/backlog + time→offset anchors) →
  `0x16 SEND_HISTORICAL` (payload `[0x00]` = full drain from current/oldest pointer) →
  each `HISTORY_END` ACKed with `HISTORICAL_DATA_RESULT` carrying the chunk's `end_data`
  cursor. **Persist-before-ack**; skip the ACK and the strap re-serves the same chunk
  forever; reconnect **resumes from the last ACKed cursor**. Convergence/resume come from
  the ACK cursor — there is NO usable `SET_READ_POINTER` seek on 4.0, and a range encoded
  in the `0x16` payload is **ignored** (device-tested: `history_started=false`).

## What is already shipped (build on this — commits on branch codex/whoop-remaining-product-gaps)
- `934f32c8` Step 1: pure safety predicate
  `AtriaBLEManager.shouldDrainHistoryDuringNaturalGap(retainedExplicitHistoryRequest:
  strapBacklogPending: priorEpochEndedNaturally: healthyLiveEpochActive:
  explicitMotionOwnershipActive: thermalParked:)` in
  `Atria/Atria/AtriaBLEHistoricalRecoveryPolicy.swift` (inside `extension AtriaBLEManager`,
  ~line 625). Hard-guards `!healthyLiveEpochActive` FIRST → Build-5 failure is structurally
  impossible. Unit tests in `Atria/AtriaTests/AtriaBLELiveContinuityPolicyTests.swift`
  (testNaturalGapDrain* — 3 tests, green).
- `4b7d52c4` Step 2: `priorConnectionEndedNaturally` flag (set in `centralManager
  didDisconnectPeripheral` via a MainActor hop — the callback is `nonisolated`, so a direct
  mutation of a MainActor prop is a COMPILE ERROR; capture `error != nil` into a local then
  `Task { @MainActor in self?.flag = local }`), plus a **log-only dry-run**
  (`--atria-natural-gap-drain-dryrun`) at the drain-decision point in
  `requestOfflineHistoricalSyncIfNeeded` (~line 10534) that logs
  `natural_gap_drain_dryrun would_drain=… prior_natural=… healthy_epoch=… backlog=…`.
- **Device-validated:** the safety invariant fires correctly — `would_drain=0` while
  `healthy_epoch=1`. Backlog confirmed present (`backlog=1`).

## STATUS: Step 3 is IMPLEMENTED (commit eb622b8a) — the next run SOAKS it, not re-implements
The natural-gap bounded-drain wiring + the `naturalGapDrainBypass` (skips the realtime-
continuity deferrals only while no healthy epoch, forces the stop-realtime full drain) are
already committed, flag-gated behind `--atria-natural-gap-drain-enable` (default unchanged).
Device-observed: the wiring FIRES (`natural_gap_drain status=armed` -> `triggering_on_connect`);
pre-bypass it hit `deferred_realtime_continuity_owner`, which the bypass targets. The
stream-verification soak is PENDING (was blocked by device availability). So the next
session's job is: (1) run the soak with the phone free; (2) confirm the bypass lets the drain
STREAM (`stream5_rx>0`, `durable_rows` climbing, ACK cursor resuming across drops, steps
climbing toward the real ~10k, live HR continuity intact); (3) if the async didConnect
trigger keeps losing the race to HR resume (drain logs `skipped_on_connect reason=healthy_epoch`),
switch to SUPPRESSING realtime-restart on an armed reconnect — which needs a
nonisolated-readable armed flag (set in the nonisolated didDisconnect, read synchronously in
the nonisolated didConnect) so realtime doesn't win the race. Then iterate against the soak.

## The Step-3 design (already implemented — reference)
The eligible drain window (`healthy_epoch=0`) exists only in the **pre-HR instant after a
natural reconnect** — which the HR-triggered `requestOfflineHistoricalSyncIfNeeded` never
sees (it fires ON accepted HR → `healthy_epoch=1`). So you must wire the drain into the
**reconnect path**, not the HR path:
1. Add a **history-owner reconnect disposition.** The fast-lane dispositions in
   `Atria/Atria/AtriaBLEHeartRateRecoveryPolicy.swift` (~line 36: `reconnectRealtime`,
   `reconnectRealtimeAfterHistoryRelease`, `suppressHistoryOwner`) are ALL realtime — there
   is currently NO history-owner reconnect path. Add one, chosen only when
   `shouldDrainHistoryDuringNaturalGap(...)` is eligible.
2. On a **natural-disconnect reconnect** (`priorConnectionEndedNaturally == true` + backlog
   + no motion owner + not thermal-parked + no healthy epoch yet), in `didConnect`
   (`AtriaBLEManager` ~45133) BEFORE realtime 2A37 restarts, run ONE **bounded** drain:
   `0x22` → `0x16 [0x00]` → persist-before-ack `HISTORY_END`/`HISTORICAL_DATA_RESULT`,
   advancing the cursor, then **restore realtime** via the existing
   `finishOfflineHistoricalSync` → `restoreRealtimeAfterHistoryGeneration` path.
3. Reach the drain by calling the existing (currently unused) stop-realtime entry
   `startOfflineHistoricalSync(reason:force:)` (~13517 → 6-arg 13807, `connectedChunkedBackfill:
   false`), which bypasses the `requestOfflineHistoricalSyncIfNeeded` realtime-continuity
   deferrals (`shouldDeferHistoricalTransportForRealtimeContinuity` ~10964 /
   `shouldDeferAutomaticHistoryForLiveContinuity` ~10534). Verify on-device it is NOT
   re-deferred via the retained-request path (`resuming_explicit_force` →
   `deferred_realtime_continuity_owner`); if it is, drive the drain directly from didConnect
   rather than through the retained-request queue.
4. Gate ALL of this behind `--atria-natural-gap-drain-enable`; ship default-off until soak.
5. Watch `connectedRawHistoryCatchUpRequestAuthorityIsValid` (~29937) — its
   `liveSilenceLimit` (45 s) and thermal-park can still abort an active drain; ensure the
   bounded chunk completes + ACKs before those fire, and that authority is bound to the
   exact peripheral/epoch.

## Soak finding 2026-08-22 (design refinement): natural-gap-only is NOT sufficient
A soak window showed the strap connection can stay STABLE for 90s+ (no natural disconnect),
so the natural-gap-only trigger never fires and steps don't catch up during stable stretches.
The complete fix therefore needs BOTH: (a) the natural-gap drain (safe, already wired), AND
(b) a bounded realtime-PAUSE interleave for stable-connection periods — drain a small chunk
with a brief (~few-second) 2A37 pause that HR recovers from, then resume realtime, repeating
until caught up. (b) is NOT Build-5's full cutover (which failed to restore cleanly); it is a
short, self-healing pause per chunk, still gated so it never runs while a workout/motion owner
holds the link. Soak (b) carefully: confirm HR gaps stay small (~seconds, self-healing) and
steps climb. This is the key remaining design piece.

## Key test target (user clarification 2026-08-22)
YESTERDAY was a real ~10k+ step day (completed); TODAY accumulates toward 10k as the user
walks. The device shows `whoop4_daily_steps window=immediately_prior steps=1118` — i.e.
YESTERDAY's completed total is under-drained (1,118 vs the real ~10k+). Yesterday is the
DETERMINISTIC acceptance target: draining yesterday's flash records must reconstruct its
total to ~10k+ (no live-accumulation ambiguity). Today's window validates the live+drain
path climbing as the user walks. Prove BOTH.

## Acceptance criteria (soak, both must hold)
- **Steps converge:** `historyDrainTelemetry` shows `stream5_rx>0`, `durable_rows` climbing,
  `ack_sent`/`ack_ok` climbing, frontier advancing, and cursor **resume across reconnects**
  (each natural-gap chunk continues from the last ACK, not from oldest). The Today step
  total climbs from ~1,118 toward the real ~10k over the soak.
- **Live HR intact:** live 2A37 HR/RR continuity is not broken by the drain — `accepted_hr`
  gaps stay ~0 across the whole soak; the app returns to normal realtime after each chunk.

## Build / deploy / soak commands
- Build+install (Release, over localNetwork): `export
  ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B; ./scripts/ship-device.sh --no-launch`
  (prints `shipped <sha>`). Sim tests: scheme `AtriaTests`, sim iPhone 17 Pro (Kept)
  `44333107-67D1-4E0C-9107-B8F52D7FDF19`.
- Launch + console:
  `xcrun devicectl device process launch --console --terminate-existing --device
  $ATRIA_ID com.adidshaft.atria --atria-enable-debug-logs --atria-natural-gap-drain-enable`
  (add `--atria-natural-gap-drain-dryrun` to also log the predicate). Telemetry greps:
  `historyDrainTelemetry`, `natural_gap_drain`, `offline_sync status=`, `stream5_rx`,
  `durable_rows`, `accepted_hr`.

## Gotchas (learned the hard way)
- `didConnect`/`didDisconnectPeripheral` are `nonisolated` → any MainActor state needs a
  `Task { @MainActor in … }` hop (else a compile error).
- Device `--console` only captures once the phone is UNLOCKED and Atria is foregrounded
  (locked → 0 bytes). Wake via iPhone Mirroring; the phone often sits on a private app
  (Messages/WhatsApp/etc.) — do NOT interact with it, just relaunch Atria via devicectl to
  foreground it.
- SourceKit shows phantom cross-file errors (UIKit/AtriaBLEManager/XCTest "not found");
  trust `xcodebuild`, not the editor diagnostics.
- Full details + all prior findings: memory `atria-history-drain-app-side-abort-rootcause`
  (and `atria-history-download-physically-proven`, `atria-fulldrain-nonconvergent`,
  `atria-steps-strap-only-decision`).

## Also (secondary, same session if time)
- Make the daily step display **feel up to date** between drains: ensure the drained rows
  publish to the Today step tile promptly (revision bump) so the number climbs live as
  chunks land, not only on next launch.
