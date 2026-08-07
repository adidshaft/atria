# Atria — Handoff 2026-08-07 (sync self-heal DONE; product backlog NEXT)

Read top-to-bottom to resume with zero prior context. Companion memory:
`atria-aug7-drain-starvation-diagnosis` (+ its addenda).

## What was broken this morning (all root-caused, all fixed)

1. **Drain starvation.** iPhone Mirroring held Atria foreground-interactive ~19h
   (foreground defers history BY DESIGN); on top of that, once a drain authority
   resolved/cleared, NO lane could *create* a new one — the Aug-6 commit
   `d8c0f441` had retired automatic exact-gap arming (measured transport hog)
   without an automatic replacement. Everything needed taps/relaunches.
2. **Repeated kills.** `cpu_resource_fatal` ×3 (windowed workout-candidate pass
   re-sorting `rrImpliedMedianBPM` per session per window, >80% bg CPU) + a
   03:09 jetsam (memory pressure mostly from the mirroring stack itself:
   SpringBoard 508 MB / backboardd 362 MB / avconferenced 276 MB; Atria was
   73 MB). Post-kill relaunches sat in **phantom foreground** (flag inited
   `true`, no scene event ever fires on iOS background relaunches) so they
   never drained.
3. **Honesty gaps.** Manual Settings "Sync missed data" refused
   (`gap_retained_exact_recovery_unproven`); banner hid its Sync button off an
   18h-stale debt count of 132 (< floor 300) while ~7,300 records sat on the
   strap; footer frontier lagged materialization by hours and read "stuck".

## What shipped today (branch `codex/whoop-remaining-product-gaps`)

| Commit | Fix |
|---|---|
| `e5bb872c` | Attended catch-up (Settings sync / pull-to-refresh / banner) passes the exact-recovery fence; stale-debt banner keeps the Sync affordance honest |
| `6521e43e` | Stranded `.draining`-authority resume from ordinary re-arms (60s-stable link + fresh HR + 90s silence); launch-time P3 ticker restart; Overview sync-progress footer (very bottom) |
| `d49ab72a` | `rrImpliedMedianBPM` content-key cache — kills the cpu_resource_fatal loop |
| `0ba50678` | **Autonomous cursor-anchored catch-up creation** — background re-arm may START a drain with no authority (stable 60s link, HR ≤45s, no workout/storm, 120s cooldown). The designed replacement for the retired exact-gap arming |
| `bc182d00` | `foregroundInteractiveMode` inits **false** (phantom-foreground, structure-test pinned); maintenance tick = background self-heal (link down → `reconnectToSavedPeripheralIfPossible`; stale 0x22 → `requestStrapStatusRead`); ticker start/keep-alive survives cleared ticket while last debt > caught-up floor; `drainedThroughUnix` written monotonically at durable-flush cadence → footer "behind" falls LIVE |

| `2104a9dc` | Debt-refresh deadlock (frontier ≥30 min behind is itself backlog evidence); footer shows whenever behind |
| *(overnight)* | **6-hour throttle fix** — see below |

### The 6-hour throttle (found 2026-08-08 01:20, the "why is sync so slow" bug)

`offlineHistoricalSyncMinimumInterval = 6 * 60 * 60`. The fast 10-minute
catch-up interval applied ONLY while the range-loss ticket was pending. Once
publication cleared that ticket mid-backlog, every maintenance re-arm answered
`lastStatus = throttled` against a 6-hour cadence — observed dead for 23+ min
with 9.6 h still on the strap and `lastAttemptAt` 5.75 h old. This is why the
drain ran in rare bursts all evening. Fix: `catchUpAttemptMinimumInterval` —
any real backlog (via `strapBacklogPendingForCatchUp`, which includes the
frontier rule) uses the catch-up cadence, and an attempt that **yielded rows**
earns a 60 s progress-gated retry. Idle upkeep keeps the 6 h interval.

### Throughput: measured ceiling and the ONE remaining lever (2026-08-08 02:00–02:30)

Continuity is solved; **throughput is now the binding constraint**. Hard numbers,
all from the device, drain running continuously:

| condition | rate | delivered |
|---|---|---|
| background, 25 min undisturbed (no polling) | **1.44×** realtime | — |
| foreground (screen on, app open), 5 min | **2.12×** realtime | 2.20 rows/s, 3.1 KB/s |
| background lull, 7 min | 0.22× | 0.22 rows/s, 318 B/s |
| bursts seen all day | up to ~3.9× | — |

- Data is uniformly ~1.04–1.07 rows/strap-second (continuous 1 Hz), so frontier
  rate ≈ delivered-row rate. Slow stretches are never "denser data".
- Foreground is only ~50% faster than background → iOS BLE power-saving is a
  minor factor, NOT a 10× lever. A "catch up now / hold the app open" feature
  was considered and rejected on this evidence.
- 3.1 KB/s is far below BLE capacity, so the ceiling is not the radio.

**The lever worth chasing next: per-batch turnaround.** Live authority showed
**55 ACKed batches in 28.3 min — median 17 s, mean 31 s between ACKs**, carrying
only tens of rows each. If the strap streams a batch in ~2 s, then ~15 s per
batch is OUR turnaround (durable fsync + write-confirmation + ACK mint), and
halving it roughly doubles throughput. NOT yet measured — the next session
should instrument, per batch: frames-received window vs fsync duration vs
ACK-write latency (`historicalDrainTelemetry` already has hooks). Do this before
touching any policy. Note `postNotificationSettleInterval = 3 s` is per-slice
startup, not per batch — already ruled out.

**Practical consequence:** at ~1.4× background, a 9.5 h backlog needs ~15–20 h to
clear. The durable answer is that backlogs must never form — which is exactly
what the continuity fixes above deliver. Treat "recover a full day of debt
quickly" as unsupported until per-batch turnaround is understood.

**Measured transport reality (2026-08-08 00:54–01:13, 11 samples):** sustained
in-slice rate ~1.3–2× realtime with bursts to ~3.9×. A fresh slice epoch
averaged 2.3× vs 1.3× for a 60-minute-old epoch (n=5 each — suggestive, NOT
conclusive). Density is flat (1.07 rows/strap-second day and night), so slow
stretches are never "denser data". If overnight data confirms epoch decay, a
bounded productive-hold cap (release + immediate re-arm every ~5 min) is the
follow-up — note `shouldReleaseConnectedHistorySlice` currently returns false
unconditionally while `productiveBacklogHold` is true, so a held slice never
cycles.

**Proven live 16:46–16:53:** install-killed app on a locked phone, zero input →
CB relaunch → ticker → autonomous creation → chained slices; frontier fell
12.9h → 12.5h in 5 min (~5×). 401 cadence tests green. Installed build =
`bc182d00` Release.

Two stale cadence tests were re-pinned to the `d8c0f441` retirement reality
(Xcode test-selection had been skipping them; expect other stale pins to
surface the same way when their sources change).

## Verification cheatsheet (proven today)

- Device `3803F5B6-1666-56D3-A71A-62F131F6CE3B`; prefs pull:
  `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.adidshaft.atria --source Library/Preferences/com.adidshaft.atria.plist --destination p.plist`
- Watch: `backgroundLeaseStatus.v1` (active = draining), `lastDurableFlushBoundaryOKAt.v1`
  (fresh = flushing), `drainedThroughUnix.v1` (falling = catching up),
  `flushDebtPendingRecords.v1` + `ObservedAt` (strap-side truth, stale >15 min).
- Raw frontier ground truth: newest `Documents/atria-historical/segments/raw-v2/raw-YYYYMMDD-*.diagnostics.json` → `correctedUnixLast`.
- Mirroring on multi-display: click coords can break (clicks hit desktop) —
  keyboard (cmd+1 = Home) + `devicectl process launch` still work; background
  Atria by launching `com.apple.Preferences` over it. Locked phone refuses
  post-install launches — iOS CB-relaunches Atria itself within ~2 min.
- Foreground pauses draining (by design). Backgrounded + worn + near phone = drains.
- Never re-enable `automaticFullDrainRecoveryEnabled`; no seek exists (WHOOP 4).

## 🔴 ROOT CAUSE FOUND (2026-08-08 04:40): drain and projection cannot both run

`SessionStore.shouldStartAutomaticArchiveProjection(applicationIsActive:)`
returns `applicationIsActive` — **archive projection only runs in the
FOREGROUND**. Gates confirmed at Sessions.swift ~9976, ~11026, ~11333, ~11576,
~15805; the deferral logs as
`recovered_projection status=deferred ... app_active=0 action=coalesce_until_foreground`
and `confirmed_workout_steps status=deferred ... action=wait_for_foreground`.

Projection is what produces `verifiedHistoricalStepEvidenceDays` (steps), sleep
stages/efficiency and archive-derived daily metrics — note `refreshHistorySnapshotCache`
only PRESERVES step-evidence days unless `isRecoveredPublication` is true
(Sessions.swift ~7583), and that path is driven by `runRecoveredHistoryStep`.

Meanwhile the DRAIN only runs in the background (foreground defers history to
protect live HR). So:

| app state | raw drain | projection into readings |
|---|---|---|
| background | ✅ runs | ❌ deferred |
| foreground | ❌ deferred | ✅ runs |

**This is the actual reason steps stay at "3% of today verified", sleep
efficiency/stages never appear, and the archive grows with nothing to show for
it.** It is NOT the backlog and NOT the throughput. A user who follows the
"keep it backgrounded so it syncs" advice gets ~0 readings; this session gave
exactly that advice for hours and made it worse.

**Fix direction:** run projection in the background under the same guarded
conditions the drain already proves safe (bounded slices, storm-free, idle/
charging, yield to live HR), or interleave drain↔projection so neither starves.
Must not reintroduce the `cpu_resource_fatal` class of kill — projection is the
CPU-heavy stage (that is WHY it was foreground-gated). Chunked + cooperative
pause (see `orphanHistoryReplayPauseDuration`) is the likely shape.

**User-facing stopgap until then:** open the app for a few minutes to let
projection catch up, then background it to resume draining.

### Empirical test of the above (2026-08-08 02:53, 4-minute foreground)

- ✅ CONFIRMED the gate is real: `daily-metrics.json` and `daily-rollups.json`
  were both rewritten the moment the app was foregrounded. Projection is
  foreground-triggered exactly as the code says.
- ❌ NOT SUFFICIENT: after the pass, Aug 7 still showed `stages 0` and
  `strainCoverageFraction 0%`. So the foreground gate alone does NOT explain
  the missing readings. Do not "fix" background projection expecting steps and
  stages to appear.

Two of the three symptoms look honest-by-design rather than broken:
- **Stages = 0 on every day** — the product requires qualified motion evidence
  AND a validated stage model; no validated stage model exists, and it
  deliberately refuses to synthesise a hypnogram from hours-asleep. This is a
  MODELLING PROJECT and a product decision, not a defect (see memory
  `atria-product-decisions`).
- **Past-day `strainCoverageFraction = 0%`** — coverage is derived from live
  sessions (`observedHeartRateUnionSeconds(sessions:)`); a day whose data sat
  on the strap has no sessions, so 0% is correct. Archive rows contribute
  TRIMP, not coverage.

### STEPS — root cause found (2026-08-08 05:00). Highest-value single fix.

`AtriaHistoricalDailyConsumerProjection.stepDays` (~line 575):

```swift
let fullyCovered = accepted.first?.0.start == day.start
    && accepted.last?.0.end == day.end
    && zip(accepted, accepted.dropFirst()).allSatisfy { $0.0.0.end == $0.1.0.start }
    && knownSeconds == daySeconds
stepCount: fullyCovered ? sum : nil
```

A day yields a step count ONLY under gapless, midnight-aligned, whole-day
motion-epoch coverage. One shower, one disconnect, one missing epoch, or a
partially-drained day ⇒ `stepCount = nil` ⇒ the UI's
`"N% of today verified · no usable step count yet"`. In practice full coverage
essentially never happens, so a step count essentially never shows. **This is
the "3% recovered / steps not fresh" complaint.**

Everything needed for the honest fix ALREADY EXISTS and is simply not wired up:
- `StepDay.knownStepDeltaSum` — the projection already computes and preserves
  the non-overlapping accepted-delta subtotal ("preserved diagnostically
  without promoting it to a day value").
- `AtriaDailyStepPresentation` already has the copy for it:
  `"At least \(count) steps. Partial verified archive coverage."` — currently
  unreachable, because the count is nil'd upstream before it arrives.

**Fix:** on a partial day with `knownStepDeltaSum > 0`, surface it as an
explicit LOWER BOUND ("At least 4,200 steps · 62% verified") instead of
"no usable step count yet". Never promote it to an exact day total, never sum
overlapping epochs (the existing `invalidStepEvidence` throw must stay).

**Care required:** this is the most honesty-tested surface in the app —
`AtriaDailyStepPresentationTests` pins the current vocabulary hard, and the
"exact vs at-least" distinction is a product rule, not cosmetics. Do it with a
clear head and extend the tests deliberately; do NOT weaken `fullyCovered`
itself (an exact count must stay exact).

## Earlier lead (superseded by the above): consumer materialization is stalled

The raw drain is NOT the only pipeline. Raw strap data is archived through
Fri 18:02, but the **consumer materialization** that turns archived rows into
steps / sleep stages / strain coverage has produced nothing since **Aug 6
09:52**. Evidence, all from the device:

- `Documents/atria-historical/consumer-receipts-v1/consumer-artifact-steps-*.bin`
  newest is **Aug 6 09:52** (others Aug 5, Jul 30) — nothing since, despite
  ~44 h of newly drained raw data.
- `sleepStageSegments = []` on every day → the hypnogram gate can never pass.
- `daily-rollups.json`: `steps: None` and `duration: 0` for Aug 5–8.
- No `.v2` consumer keys and no `terminalConsumerCoverageFailure` record exist,
  so terminal consumer materialization has not FAILED — it appears never to
  have run in this build's lifetime. (The `terminalConsumerDependencyMismatch.v1`
  value on device is legacy from an older build; the code writes `.v2`.)

**Explicitly NOT established — do not assume:** that this stall is what starves
steps/stages. `strainCoverageFraction` is computed from LIVE SESSIONS
(`observedHeartRateUnionSeconds(sessions:)`), not from archive rows, so Aug 7
reading 0% has an innocent explanation (that day's data sat on the strap, so no
live sessions existed) and is NOT evidence of a materialization bug. Likewise
the consumer-receipts artifacts are terminal-publication durability receipts,
which may be a different path from the live `historySnapshot` /
`AtriaHistoricalDailyConsumerProjection.StepDay` the UI actually reads.

**First job next session — settle the causal chain before fixing anything:**
1. Does archived raw data ever become `StepDay` / stage evidence WITHOUT a
   terminal full-drain publication? Trace `historySnapshot` step days and
   `AtriaWhoop4MotionTickDailyStore` back to their inputs.
2. If it requires a terminal publication, the chunked catch-up lane (which
   never reaches `historyComplete`) has no materialization stage at all — that
   would be the real architectural gap and the true cause of the missing
   readings.
3. Success test either way: a fresh `consumer-artifact-steps-*.bin`, or a
   populated `StepDay` for an already-drained past day.

Where to start: `historicalConsumerMaterializationInFlight`, the
`consumer-receipts-v1` writer, and the `pendingConsumerDependency` /
`terminalConsumerDependencyMismatch.v1` state (a mismatch value IS persisted:
`pending_consumer_dependency_v1|37b98471-…|1785004200000|1785104606322|Asia/Kolkata`).
Also check `recovery_window_pending` / `partial_history_published_gap_preserved`
statuses seen cycling during drains — publication may be repeatedly deferring
consumer commit. Verify with a fresh `consumer-artifact-steps-*.bin` appearing
after a drain slice.

## BACKLOG — in priority order (user's list, 2026-08-07)

1. **Fresh-day surface audit** (after full catch-up): every Overview/Vitals card
   should show last-night sleep + recovery + live strain/steps with no `--`;
   chase any that stay dark. Known suspects: recovery % recompute instability
   across process restarts (75→38→58→62 observed within hours — likely
   RHR-only vs HRV-inclusive recompute race at launch); Resting HR card
   flapping "this morning 56" ↔ "wear estimate 65".
2. **Journal notification**: user wants a daily prompt to fill the journal.
   `LocalNotificationScheduler` exists (`morningNudgeMinutes` etc.) — check for
   a journal-prompt lane, wire if missing.
3. **Sleep stages / hypnogram**: gate says "qualified motion evidence + a
   validated stage model". After catch-up, verify motion evidence qualifies;
   if the STAGE MODEL is the gate, that's a modeling project — scope it
   deliberately (do not fake stages).
4. **Battery pill honesty**: post-install "battery pending" while
   `notificationLastError=new_link_unconfirmed` even though a credible level
   exists (`atria.battery.credibleLevel`). Show last credible level +
   "updating…" instead of pending.
5. **Footer v2**: distinguish "syncing from strap" vs "processing on phone"
   (materialization lag masqueraded as being hours behind); optional ETA from
   recent drain rate.
6. **Strap-debt freshness**: periodic background 0x22 refresh beyond the tick
   nudge, so caught-up detection never relies on a stale count.
7. **Deep metrics**: wrist temp "Decoder unavailable", fitness age "Building
   HRV baseline", VO2max sanity, sleep-history "Routine consistency 8%",
   HealthKit `overfilled` reconciliation (gate G), strain coverage fraction.
8. **Jetsam pressure**: external (mirroring stack + on-device AI service), but
   consider trimming Atria's own peak (cold-session rebuild at launch pinned
   the UI ~5 min on 03:09 relaunch — move to chunked/background).
9. **Nap surfacing** (existing memory `atria-nap-surfacing-gap`) + deferred
   product decisions (`atria-atria-product-decisions`).

## Open questions for the user

- Sleep-stage model: invest in validating a stage model (real project) or keep
  honest "no stages" until references exist?
- Journal notification: what time / trigger (post-wake? fixed hour?)
