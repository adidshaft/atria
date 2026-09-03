# Atria — Claude handoff 12: close motion acquisition, publish current sleep, repair Stress gaps, and remove duplicate UI

Date: 2026-08-13 (Asia/Kolkata)  
Release branch: `dev`  
Exact pushed starting commit: `22c9fa217a60f1bcf7a760016b0ea53eb56ad044` (`Persist a degraded HR-only sleep review when motion cannot be verified`)  
Remote parity verified at handoff: `HEAD...origin/dev = 0 0`  
Clean release worktree: `/private/tmp/atria-notifications-integration.wyA4H7/source`  
Dirty user checkout that must not be touched: `/Users/amanpandey/projects/atria` at `293d1a7c988bf99b6093b8529da0cf528d6e4896`  
Sleep issue: [#25](https://github.com/adidshaft/atria/issues/25)  
Stress validation issue: [#32](https://github.com/adidshaft/atria/issues/32)
Stress continuity/UI issue: [#37](https://github.com/adidshaft/atria/issues/37)  
Motion/steps issue: [#21](https://github.com/adidshaft/atria/issues/21)

## Mission and hard cutline

Ship only these four product outcomes, in this order:

1. **Motion closure:** determine and fix the exact protected-R10 fallback/disconnect so sustained strap motion is either genuinely live or ends in one precise protocol/reference blocker. Do not spend another pass improving fallback copy while leaving acquisition untouched.
2. **Current sleep:** the strong HR/RR portion of the user's Aug-13 sleep must become one durable, unconfirmed review card. It must not disappear merely because compact motion is missing or because the current-cycle settlement lane did not run.
3. **Stress continuity:** deterministically fill missing one-minute Stress facts whenever the exact preceding five-minute HR window is already qualified. Preserve honest blanks across actual telemetry gaps.
4. **Vitals cleanup:** make Stress one coherent surface on the Vitals screen—one metric identity, one chart, compact in-bounds inspection pointers, and no repeated confidence/motion prose.

Timebox: **4–5 hours total**, maximum three commits. Checkpoint 0 has a hard **90-minute investigation/one-attempt cutline**. Spend the first 30 minutes reproducing the exact receipts below; then implement. Do not broaden this into open-ended R10 archaeology, backlog-throughput, stage-model, biomarker, notification, or app-wide redesign work.

The definition of done is a signed Release on the physical phone, not only tests. Use Computer + iPhone Mirroring for the six screenshots and direct `atria://` routes when the tab bar cannot be clicked.

## Worktree and git safety — mandatory

Never edit, stash, reset, clean, stage, switch, merge, rebase, or commit application source in `/Users/amanpandey/projects/atria`. It contains the user's chart WIP and handoff documents.

Continue only in `/private/tmp/atria-notifications-integration.wyA4H7/source` after proving:

```text
HEAD = 22c9fa217a60f1bcf7a760016b0ea53eb56ad044
git status --short = empty
git rev-list --left-right --count HEAD...origin/dev = 0 0
```

If the remote moved, fetch and inspect it first. Integrate only by a clean fast-forward or isolated rebase/cherry-pick. This handoff document is coordination material and must not enter the app commit.

Use author and committer `adidshaft <adidshaft@gmail.com>`, with no AI/co-author trailer. Push only after every gate passes.

## What Handoff 11 already shipped — preserve it

Do not redo or weaken these `22c9fa21` contracts:

- compact latest-night settlement has canonical, review-only, and withheld outcomes;
- incomplete motion can yield an HR/RR review without acquiring compact commit authority;
- degraded review candidates are durable, relaunch-stable, unconfirmed, and deduplicated by stable evidence identity;
- canonical confirmation/dismissal and re-pair invalidation win;
- degraded evidence can never auto-confirm or call canonical commit APIs;
- motion-qualified settlement may later enrich/replace degraded review evidence;
- the review UI truthfully says HR/RR and motion was not verified;
- issue #25 was closed only for the H11 fixture and shipped behavior.

This pass addresses a new physical contradiction: the real Aug-13 candidate exists in resident data, but the H11 producer/receipt did not run or did not reach the pending store.

## Checkpoint 0 (P0) — stop treating Atria's persisted fallback as a hardware verdict

The current “HR-only / no motion” state is **not** proof that this WHOOP 4 cannot send motion. Read-only physical evidence shows Atria previously received and decoded R10 frames, then deliberately persisted a pure-HR fallback after a protected transport proof disconnected.

Current exact radio state:

```text
radio_standard_hr_only = 1
radio_standard_hr_only_user_selected = 0
radio_recorded_runtime_mode = protected_r10_minimal
radio_effective_mode = standard_hr_only
radio_protected_r10_active = 0
radio_clean_owner = pure_hr_v8
radio_clean_owner_state = fallback_active
radio_clean_owner_failure = clean_owner_proof_disconnect
radio_passive_r10_status = clean_owner_v8_pure_hr_active
protocol_imu_frames (current diagnostic epoch) = 0
```

Historical proof on this same installation lineage:

```text
atria.radio.passiveR10ValidFrames = 154,075
atria.motionHandshake.r10Frames = 1,105
first R10 payload length = 1,920 bytes
R10 IMU activation sequence completed = true
```

So the honest diagnosis is:

1. Standard BLE 2A37 is carrying stable HR/RR.
2. Dense proprietary R10 motion existed at least in prior proof epochs.
3. The protected clean-owner proof later disconnected (`clean_owner_proof_disconnect`).
4. Atria rolled back to `pure_hr_v8/fallback_active` to preserve HR continuity.
5. `prepareProtectedR10CleanOwnerAtLaunch` intentionally keeps that fallback on every ordinary launch. A fresh retry is authorized only by an explicit workout/calibration lease and cooldown policy.
6. The all-day v24 motion bank is a separate low-bandwidth historical counter, not a continuous IMU stream. On Aug-13 its governor spent about 35,595 s in `sync_cutover` versus 26,882 s `armed`, so catch-up repeatedly displaced bank coverage. That is why step/motion coverage can remain poor even while HR is current.

Previous passes mostly hardened ownership, rollback, history offload, authority, and truthful fallback presentation. They did **not** make the protected dense stream survive. Do not call those changes a motion-acquisition fix.

### 90-minute motion closure gate

Do this before downstream UI work:

1. Freeze a fresh state/packet/owner snapshot and prove the current saved owner/failure exactly.
2. Audit the one transition that wrote `clean_owner_proof_disconnect`: include CoreBluetooth error domain/code, central state, exact CCCD set, characteristic UUIDs, activation command/response, first/last valid R10 clocks, 2A37 raw/accepted clocks, and owner generation.
3. Add only missing bounded observability required to distinguish:
   - no R10 frames served;
   - malformed/decoder rejection;
   - CCCD/notification collision;
   - activation command rejected/missing response;
   - connection/bond failure;
   - app-owned premature rollback;
   - HR continuity watchdog-triggered rollback.
4. When the strap is worn and charged above 70%, run **one** explicit Strength/calibration requalification. The phone remains cabled, unlocked, and available through iPhone Mirroring. Do not loop attempts.
5. Start 2A37 first, then the exact protected owner/profile. Preserve the existing single-owner and generation fences.
6. If dense R10 becomes stable, retain the protected owner only after the existing proof plus a new physical acceptance below. Do not mark success on one frame.
7. If the attempt disconnects or yields no frames, stop radio writes. Return the exact terminal category and the smallest missing external artifact (for example an official-app negotiation capture or hardware BLE trace). Do not guess another payload.

### Motion success acceptance

Success requires all of the following on the current connection:

```text
fresh CRC/layout-valid R10 frames advance continuously for >=30 minutes
liveStrapMotionCapturedAt advances
decoded motion rows cover >=90% of the 30-minute proof window
2A37 raw == accepted == durable progression
no HR gap >=30 seconds
no disconnect, CCCD churn, watchdog, reconnect, or owner rollback
protected owner remains active through screen lock/background and foreground return
one compact v24/R10 authority receipt is durable and source-identified
verified step/motion frontier advances without phone/preliminary substitution
```

Then run one sleep/review fixture using the fresh motion authority and prove that motion-qualified evidence takes the stronger existing path. Do not retune sleep stages in this pass.

If any criterion fails, motion remains open on #21 with the exact blocker. The rest of Handoff 12 may still ship, but the closure report must say **motion acquisition failed**, not “motion unavailable on this strap.”

### Motion tests

Add direct tests for:

1. `pure_hr_v8/fallback_active + explicit fresh lease` performs exactly one requalification.
2. Normal launch without authority performs zero radio writes.
3. Old owner callbacks cannot qualify or roll back the new generation.
4. R10 frames + stable 2A37 for the proof window retain protected mode.
5. No frames, decoder rejection, CCCD failure, disconnect, and HR watchdog each record different terminal reasons.
6. Failed proof returns to stable HR exactly once and does not retry-loop.
7. v24 bank coverage and dense R10 coverage are never conflated.
8. UI motion authority becomes available only from fresh decoded strap evidence, never phone motion or a stale timestamp.

## Fresh physical diagnosis — this is authoritative input

Read-only runtime pull:

```text
/private/tmp/atria-no-sleep-today.SnxaMb
sessions.json SHA-256:
  ff5ac730ccf75f16dfdbfb3fec4173886b446bf68093b8a5e12cca90ed2530c3
preferences.plist SHA-256:
  94ad162b48c9c653dfdec9ffc45176c62838432512cfffd642c437572cc36def
authoritative-runtime-state.sha256 SHA-256:
  8cce77b0c3b62b28aff8b8211d7878f562c22a721cdb3ae97d2ad18e7cfce0a3
```

At the pull:

```text
current live/durable HR: fresh, connected, notifying
history frontier: 2026-08-13 18:06:42 IST
reported wake: approximately 14:00 IST
frontier lead past wake: approximately 4 hours
transport: standard_hr_only
protocol_imu_frames: 0
confirmed sleeps: 30 total; latest ended Aug-12 15:27 IST
confirmed sleep waking Aug-13: none
pending_sleep_review_status: missing
atria.debug.sleepCompactReviewReceipt.v1: absent
```

Therefore **sync lag is not the reason the Aug-13 sleep is absent**. The frontier is already well beyond wake. Do not wait for more history or change drain throughput as the first response.

### What the raw physiology actually supports

The user's reported interval was approximately Aug-12 21:00 through Aug-13 14:00. Across that entire 17-hour span the archive has 57,409 HR and 36,996 RR rows, but the early portion is not a specific HR-only sleep shape:

```text
21:00–09:00 hourly mean HR: mostly 73–90 bpm
whole reported span median HR: 75 bpm
whole reported span p90 HR: 90 bpm
whole reported span HR SD: 12 bpm
largest HR gap: 1,938 s at 09:23–09:56
```

Without motion, it would be unsafe to auto-confirm that entire 17-hour claim. Do not weaken the auto-confirm gate to do so.

However, two adjacent resident sessions form a strong review-only shifted-sleep candidate:

```text
09:56:03–10:36:23  HR rows 2,381; RR rows 2,276; mean 62.9; SD 4.0; p90 67
10:39:07–13:39:05  HR rows 10,527; RR rows 9,956; mean 61.1; SD 3.8; p90 64
between-session seam: 164 s
session accepted-HR gap authority: 0 s and 31.4 s
personal current-cycle resting HR shown by app: 58 bpm
```

This is about 3 h 40 m of dense, stable HR/RR with one visible short seam. It fits the intent of the existing shifted/dense HR-only review lane. It must surface for **Confirm / Adjust / Dismiss**, never auto-save. “Adjust” lets the user extend/correct the bounds using their own authority.

### Current failure signals to preserve in the receipt

`preferences.plist` also records:

```text
rangeLossBackfillPending = true
lastStatus = armed
lastReason = connected_raw_catch_up_accepted_hr_batch
terminalArchiveFailure = publicationCheckpointMissing
terminalConsumerDependencyMismatch = pending_consumer_dependency_v1|...
terminalFailureSite = site37794
```

These may explain why a current-cycle consumer did not run even after the frontier passed wake. Measure the exact branch; do not infer. The missing H11 receipt is itself a bug in terminal observability.

## Checkpoint 1 (P0) — make current-sleep review admission terminal and observable

### Required behavior

After the durable frontier passes a plausible wake plus the existing post-wake tail:

1. Evaluate current-cycle review evidence exactly once per stable source revision, even if the canonical compact-motion settlement already ended, was withheld, or a consumer dependency was parked.
2. Use the existing bounded HR/RR review builder. Do not create a second sleep classifier.
3. Persist at most one review candidate through `AtriaPendingSleepReviewStore`.
4. Keep it `confirmed = false`, `motionValidated = false`, and without compact/canonical commit authority.
5. Publish it on the next active edge with Confirm / Adjust / Dismiss.
6. A stale generation, source change, confirmed overlap, dismissal, or re-pair must still reject it.
7. If no candidate qualifies, write a terminal decision receipt instead of silently producing nothing.

### Required decision receipt

Extend the existing bounded H11 receipt or add one versioned sibling. It must record one terminal event per attempt, with no user health values beyond what is already locally stored:

```text
attempt ID / source revision / strap pseudonymous ID
candidate start/end/duration
HR rows, RR rows, HR/RR coverage
mean, median, p90, SD, maximum source gap, maximum accepted gap
sleep-core/shifted-clock gate result
confirmed/dismissed overlap result
compact-motion outcome
frontier and wake-tail readiness
settlement/coordinator terminal state
pending-store outcome
final outcome:
  saved_review | duplicate | already_confirmed | dismissed |
  source_not_ready | not_qualified(<exact gate>) |
  stale_generation | authority_revoked | deadline | integrity_failure
```

The real-device acceptance must explain why this attempt previously emitted no `atria.debug.sleepCompactReviewReceipt.v1` at all.

### Do not do these

- Do not auto-confirm the full reported 21:00–14:00 interval.
- Do not reinterpret high-HR awake time as sleep merely to match the user's recollection.
- Do not bridge the 32-minute 09:23–09:56 telemetry gap as observed sleep.
- Do not manufacture motion, stages, HRV, respiratory rate, or Recovery.
- Do not wait indefinitely on a still-advancing backlog once the required frontier is already beyond wake.
- Do not let a degraded pending review seed Recovery, including presentation-only Recovery, unless an explicit pre-existing contract and direct test proves that is desired. H11's product statement says this evidence is review-only; keep that authority boundary literal.

### Direct tests

Add deterministic tests for:

1. The two-session 09:56–13:39 shape above produces one unconfirmed review.
2. The earlier elevated 21:00–09:23 data cannot be appended or auto-confirmed.
3. Frontier before wake-tail -> `source_not_ready`; same source after frontier -> exactly one attempt.
4. Already-parked/terminal canonical settlement still schedules the review-only consumer once.
5. Duplicate source revision is byte-stable and does not notify twice.
6. Relaunch restores the candidate.
7. Confirm, Adjust, Dismiss, stale generation, re-pair, and source change all win.
8. Every no-candidate branch writes one exact terminal blocker.
9. Degraded candidate cannot enter canonical sleep, daily metrics, Recovery, HealthKit, notification success, or motion-qualified stage paths.

## Checkpoint 2 (P0/P1) — repair Stress continuity from evidence, never interpolation

I pulled the production Stress archive read-only from:

```text
/private/tmp/atria-no-sleep-today.SnxaMb/stress-history-v3
```

The current 12-hour slice contains:

```text
601 scored minute facts
29 discontinuities longer than the 90-second fact-continuity boundary
34 missing Stress minutes whose exact preceding five-minute HR windows were already dense:
  >=120 HR rows
  >=285 s observed span
  maximum raw HR gap <=10 s
```

Material dense-HR / missing-Stress runs include:

```text
16:12–16:19  8 minutes
16:40–16:42  3 minutes
19:18–19:22  5 minutes
19:27        1 minute
```

These are not cosmetic chart gaps and not strap-HR gaps. The same archive also contains genuine source gaps, such as the approximately 09:23–09:56 outage. The repair must distinguish them.

### Required continuity contract

1. Define one deterministic minute-keyed five-minute Stress fact producer shared by live and replay paths.
2. A minute is eligible only when the exact preceding five-minute HR window passes the existing `AtriaPhysiologicalStressModel` gates (`minimumQualifiedHRSpan`, sample floor, and maximum raw HR gap). RR remains optional and provenance-qualified exactly as today.
3. Live delivery may publish immediately. A bounded reconciliation pass must later fill eligible minute keys missed because the app was backgrounded, MainActor was starved, a subscription tick was skipped, or the process relaunched.
4. Reconciliation reads canonical resident/archive HR/RR, uses the same scoring version and exact personalization/context authority, and merges through existing replay non-regression rules.
5. Persist the reconciled facts in existing `stress-history-v3` shards; do not create a second UI-only Stress series.
6. Never synthesize an input or interpolate a score. If the raw five-minute window is incomplete, the graph stays blank.
7. Never connect rendered segments when adjacent qualified facts are more than `maximumFactContinuityGap` apart.
8. The current `historicalReplay` authority must still delete/replace obsolete replay facts when source or context revisions change.

### Required gap receipt

For each visible missing minute (bounded/ring-buffered), classify:

```text
qualified_and_reconciled
raw_hr_gap
insufficient_hr_span
insufficient_hr_samples
source_not_yet_durable
sleep/context_authority_pending
replay_deferred
stale_generation
deadline_or_thermal
```

The physical acceptance must prove that the 16:12–16:19 dense-HR gap becomes real replay facts, while 09:23–09:56 remains blank.

### Direct tests

1. Dense five-minute HR with a skipped live tick -> replay inserts exactly one minute fact.
2. Multiple missed consecutive minute keys -> bounded replay fills all eligible keys in order.
3. A >60-second raw HR gap -> no fact and an exact `raw_hr_gap` receipt.
4. No cosmetic line connects a >90-second fact gap.
5. Live wins exact timestamp collisions; current replay can replace older replay only under existing authority rules.
6. Relaunch hydration + replay is idempotent and retains original timestamps.
7. Background computation/durability continues without inactive `@Published` churn.
8. Scoring version, calibration revision, sleep context, and motion context never regress.

## Checkpoint 3 (P1) — compact Stress UI, in-bounds pointer, and screen-level deduplication

The current Vitals screen repeats Stress four times in one viewport:

1. selected `Stress` segment;
2. “Current reading” detail sentence;
3. tooltip repeats HR-only, motion unavailable, and low confidence;
4. Health Monitor repeats a full “Physiological stress” card directly below the Stress chart.

This wastes space and makes one metric look like several unrelated products.

### One-screen ownership rule

On a single screen, one metric may have only one primary interactive owner. A second appearance is allowed only if it adds a genuinely different time scale or action and does not repeat the same current value/copy.

For Vitals:

- **Live monitor / Stress** is the sole Stress owner.
- Remove the duplicate Health Monitor “Physiological stress” row from this screen.
- Keep Recovery, Resting HR, and HRV cards; they are distinct metrics.
- Stress remains reachable through the Stress segment and its detail navigation.
- Do not hide Stress data from Activity or other screens where it serves a different day/workout context.

Audit Today, Vitals, and Activity for exact same-screen duplicates, but keep the implementation bounded: fix the proven Vitals duplicate plus at most two other indisputable duplicates. Put any larger redesign into an issue instead of expanding this pass.

Add a small pure ownership inventory/test so a future view cannot render both the full Stress owner and the duplicate summary card.

### Visible copy — remove the literature

The normal Stress state should read approximately:

```text
Current reading                                      1.5 / 3
Moderate
[chart]
0–1 Calm          1–2 Moderate          2–3 High
5-min estimates · gaps are missing data
```

Do not show these phrases repeatedly in the normal visible chart:

```text
HR-only estimate
Motion unavailable
Low/lower confidence
```

Keep necessary provenance and limitations in the metric information sheet and accessibility value/hint, not duplicated in the header, tooltip, footer, and Health Monitor row. A disconnected/blocked state may still use one short truthful blocker.

### Pointer/tooltip contract

Replace the wide Swift Charts `.annotation(position: .top, y: .disabled)` behavior with one plot-local, clamped inspection overlay.

Requirements:

- maximum width about 128–144 pt;
- maximum three visible lines: time, `score · zone`, and HR when available;
- no HR-only/motion/confidence paragraph;
- clamp horizontal origin to the plot frame with at least 6–8 pt inset;
- place left/right of the selection when that avoids clipping;
- choose above/below the point when top/bottom space is insufficient;
- never cover axes, legend, screen edge, or selected point;
- preserve the vertical rule + point marker;
- portrait and landscape use the same pure placement policy;
- Dynamic Type and accessibility expose the complete semantic description even though visible copy is compact.

Add deterministic placement tests for far-left, center, far-right, top-band, bottom-band, narrow portrait, and landscape coordinates. Add a screenshot/fixture test proving no text or material card leaves the chart/screen bounds.

### Chart continuity rendering

- Continue to use segment identity; do not visually bridge absent facts.
- Once Checkpoint 2 creates real missing minute facts, the line becomes continuous naturally.
- Do not add a chart-only interpolator or carry-forward value.
- Prefer the shared chart visual grammar already used elsewhere; do not introduce another one-off gradient/line language.

## Physical acceptance — mandatory

### Preconditions

1. Build from the clean release worktree and exact pushed tip.
2. Install a signed Release in place, preserving the data container.
3. Write and verify fresh installed provenance. The current pulled `installed-app-provenance.json` is stale (it still names `976a06b7` and old container paths), so do not use it as proof of the running binary.
4. Verify the installed executable hash, bundle path, data-container path, normal launch args `[]`, PID stability, and migration counts.
5. Do not use DEBUG fixtures as physical proof.

### Computer + iPhone Mirroring

Use the `computer-use` plugin and iPhone Mirroring. When tab-bar taps do not route, navigate with:

```bash
xcrun devicectl device process launch \
  --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --payload-url 'atria://vitals' \
  --activate com.adidshaft.atria

xcrun devicectl device process launch \
  --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --payload-url 'atria://sleep-review' \
  --activate com.adidshaft.atria
```

Mirroring synthetic clicks have previously landed about 123 px above the aim point and the bottom tab bar may be unreachable. Prefer deep links; do not spend the timebox fighting the tab bar.

Capture these six screens:

1. Vitals Stress at current time with the compact header and no duplicate Health Monitor Stress row.
2. Far-left selected pointer fully inside the chart.
3. Far-right selected pointer fully inside the chart.
4. A formerly missing dense-HR Stress interval now populated by real replay facts.
5. A genuine raw-HR outage still blank.
6. Sleep Review showing the Aug-13 HR/RR candidate with Confirm / Adjust / Dismiss.

### Sleep acceptance

- The current real source produces one review around the strongest 09:56–13:39 evidence (exact final bounds may move only if a receipt shows why).
- It remains unconfirmed until user action.
- No canonical sleep, ring, Recovery, daily metric, HealthKit row, or notification success appears before confirmation.
- Adjust can extend/correct the window under user authority.
- After confirmation, Today/Activity/cycle projections converge once, without stale prior-day carryover.
- If the real candidate still does not appear, stop with the exact terminal receipt and do not claim success from a fixture.

### Stress acceptance

- Re-pull `stress-history-v3` and compare minute keys against accepted HR.
- Every filled point has an exact qualified five-minute source window and retained timestamp/provenance.
- The known dense-HR 16:12–16:19 gap is filled or has a precise non-cosmetic blocker.
- The genuine 09:23–09:56 telemetry outage remains blank.
- No duplicate current Stress row remains in the same Vitals viewport.
- Header/footer/tooltip contain none of the repeated phrases listed above.

### Runtime health

After install and normal launch, observe at least 10 minutes:

```text
live raw == accepted == durable HR progression
the protected-R10 owner/result matches the Checkpoint 0 receipt
if motion qualified, fresh decoded motion continues advancing without fallback
no disconnect/CCCD churn
no app relaunch
no crash, jetsam, watchdog, or HangTracer >=2s
no recovered-projection CPU loop
stress replay bounded and terminal
sleep review attempt terminal and deduplicated
```

Do not interrupt an active productive history slice merely to collect a screenshot.

## Focused test/build gate

Run serially, parallel testing disabled, fresh xcresult. Include at minimum:

```text
Atria protected-R10 clean-owner/requalification tests
Atria motion-owner generation and rollback tests
Atria strap-motion availability/authority tests
Atria verified-step provenance tests
AtriaDegradedSleepReviewTests
AtriaCompactLatestNightSettlementTests
AtriaSleepReviewCacheTests
AtriaSleepAuditRegressionTests
AtriaPendingSleepReviewStore tests
AtriaStressMonitorTests
AtriaStressHistoryPersistence tests
AtriaPhysiologicalStressModel tests
AtriaVitals stress timeline/presentation tests
AtriaSwiftUIPerformanceAuditTests
AtriaHomeSideEffectPublisherBoundaryTests
```

Also run a full simulator app compile. Fail on any changed-path test, source-scan drift, compiler warning introduced by this diff, or evidence/provenance mutation outside the isolated worktree.

## GitHub issue hygiene

- Reopen/update #25 with the physical Aug-13 no-receipt case; close it again only after the real review card appears on device.
- Update #32 with the dense-HR/missing-Stress counts, the final reconciliation contract, and before/after physical receipts.
- Keep the continuity, tooltip, and same-screen dedup work on #37; link measured scoring/validation implications back to #32.
- Update #21 with the exact persisted fallback, prior valid-R10 proof, one-attempt requalification result, and verified-motion coverage receipt. Do not close it unless sustained live motion and whole-day verified-step authority both pass physically; live motion alone does not prove the historical step bank is complete.
- Do not close #5 unless its broader 7/30/90-day trend requirements are independently satisfied.

Every issue update must name the exact commit, tests, device build hash, and remaining physical caveat.

## Explicitly out of scope

Do not change in this pass:

- BLE history ACK/prefix retirement, attempt cooldowns, or drain throughput;
- any R10 payload guessing, repeated radio experiments, broad protocol archaeology, step-percentage formula change, or phone/preliminary-step fallback. The only authorized transport mutation is the single Checkpoint 0 protected-R10 requalification with exact rollback and evidence;
- sleep-stage algorithms or stage labels;
- SpO2, skin-temperature decoders, or relative-skin math;
- Recovery/HRV/RHR/respiratory formulas;
- notification catalog or settings;
- HealthKit, widgets, ActivityKit, or TestFlight;
- global app navigation or a broad visual redesign;
- the dirty main checkout or evidence corpus.

## Required final report

Return one concise closure report containing:

1. exact start/end commit and remote parity;
2. files changed and why;
3. the exact pre-attempt motion owner/failure and one-attempt result, including R10/2A37 clocks, decoded coverage, lock/background survival, and verified-step frontier;
4. the exact pre-fix sleep rejection/omission reason;
5. the real review candidate's final bounds and authority state;
6. before/after Stress gap counts, separating qualified-reconciled from true source gaps;
7. proof that no score was interpolated;
8. before/after screenshots for pointer bounds and Vitals dedup;
9. focused test totals + xcresult paths;
10. signed Release executable hash, provenance, migration audit, PID/runtime health;
11. issue links and only genuinely unresolved blockers.

Do not call the pass complete if motion acquisition is replaced by another copy/UI change, if only the DEBUG fixture works, if the current real sleep still has no terminal receipt, if dense-HR Stress gaps remain unexplained, or if the same Vitals viewport still renders Stress twice. If the one bounded R10 attempt fails, call the overall motion checkpoint failed and name the exact external evidence required; do not relabel that as a hardware limitation.
