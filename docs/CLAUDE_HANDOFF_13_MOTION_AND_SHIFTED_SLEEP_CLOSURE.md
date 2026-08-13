# Atria — Claude handoff 13: close live motion and surface the shifted sleep

Date: 2026-08-13 IST
Repository: `adidshaft/atria`
Branch to update: `codex/whoop-remaining-product-gaps`
Exact required start: `ea7fe417f0842723edaa685f48b2055f0e41e9ef`
Open motion/steps authority: [#21](https://github.com/adidshaft/atria/issues/21)
Open shifted-sleep review: [#25](https://github.com/adidshaft/atria/issues/25)
Stress validation: [#32](https://github.com/adidshaft/atria/issues/32)
Stress continuity/UI closure: [#37](https://github.com/adidshaft/atria/issues/37)

## Read this first

Handoff 12 shipped three real improvements and they must not be rebuilt:

- every current-sleep admission attempt now ends in a terminal receipt;
- Stress replay now includes the resident journal and reconciles on foreground;
- Vitals has one Stress owner and a clamped compact chart pointer.

The remaining failures are concrete:

1. **Motion is still not live.** The authorized H12 attempt was correctly not repeated because the strap was at 25%, below the >70% experiment precondition. A prior real attempt remained in `proving` for roughly 47 minutes despite a 150-second proof timeout, then collapsed to `clean_owner_proof_disconnect`. H12 added the missing disconnect-context recorder, but did not restore R10.
2. **The real Aug-13 shifted sleep still has no review card.** A terminal receipt now says `not_qualified(mean_hr_above_sleep_band)` because a two-hour clustering policy merges the 09:56–13:39 low-HR/RR core with a short prelude and about eight hours of post-wake wear.
3. **Stress is materially improved but its diagnostic counts overstate missing minutes.** The receipt compares the replay-produced facts rather than the final merged store, and the row-capped active-journal tail is still labeled too generically until session seal.

Do not spend this pass renaming `HR-only`, polishing fallback copy, changing chart styling, or revisiting already-shipped H12 work.

## Hard scope and cutline

Deliver, in order:

1. **CP0 / P0 — one attributable protected-R10 motion qualification.** Fix/prove the proof deadline first, then make exactly one physical attempt only when all preconditions pass.
2. **CP1 / P0 — one durable unconfirmed review card for the real 09:56–13:39 shifted sleep.** Split the continuous awake tail without weakening sleep truth.
3. **CP2 / P1 — make the Stress gap receipt describe the merged store and the active-tail state accurately.** Do not change the score model.

Timebox: **4 hours**, maximum **two implementation commits**. CP0 gets at most 90 minutes including the physical window. If its external preconditions are unavailable, record `PRECONDITION_BLOCKED` and spend no radio writes; continue CP1/CP2. Do not turn this into protocol archaeology.

## Worktree, identity, and safety

- Work in a new clean detached worktree from exact `ea7fe417`.
- Do not touch the user's dirty checkout at `/Users/amanpandey/projects/atria`.
- Preserve the evidence corpus byte-for-byte; use guarded temporary symlinks only if an existing test requires one.
- Author and committer: `adidshaft <adidshaft@gmail.com>`.
- No AI/Codex/Claude trailers.
- Fetch and prove the remote tip has not moved before each push.
- Push only a clean fast-forward to `origin/codex/whoop-remaining-product-gaps`.
- No TestFlight.
- Never open Brave, Safari, or Passwords. Never install or pair the WHOOP app, unpair the strap, or change system/Bluetooth permissions without explicit user approval.

## Physical environment and Computer/iPhone Mirroring

The iPhone is cabled and Atria may be inspected through iPhone Mirroring. At handoff creation time the **Mac was locked**, so no fresh visual claim was made. Before any UI work:

1. Ask the user to unlock the Mac if Computer reports it locked.
2. Use Computer with app bundle `com.apple.ScreenContinuity` for read-only inspection and screenshots.
3. Re-fetch accessibility/screenshot state after every action; do not reuse stale element indices or assume the old 123-pixel click offset still applies.
4. Prefer `devicectl device process launch --payload-url` for navigation when the tab bar cannot be reached. Existing routes include `atria://overview`, `atria://vitals`, `atria://sleep-review`, `atria://strap`, and `atria://journal`.
5. Do not claim a screen was verified unless its screenshot is preserved with exact installed commit/build provenance.

The motion attempt also requires the user to be wearing the strap and able to move normally. Computer automation cannot manufacture a physical motion proof.

---

## CP0 / P0 — restore or exactly terminalize protected R10 motion

### The current truth

This is not evidence that the strap lacks a motion sensor:

```text
current clean owner             pure_hr_v8
current owner state             fallback_active
current failure                 clean_owner_proof_disconnect
stream suppressed               true
passive reprobe failures        10
activation count                359
current protocol IMU frames     0
user selected HR-only           false
```

The same installation lineage has previously recorded:

```text
passive CRC/layout-valid R10 frames     154,075
motion-handshake R10 frames               1,105
first R10 payload bytes                   1,920
IMU activation sequence completed          true
stable transport qualified                 2026-07-27 02:22 IST
```

The strap has served dense motion before. Atria is now preserving its own safe fallback after a failed proof.

The H12 real-attempt anatomy was:

```text
lease began                  05:45:45 IST
requalification attempted    06:22:16
activation/subscription      06:22:45
fallback on disconnect       07:10:09
nominal proof density window 90 s
overall proof timeout        150 s
```

A proof that remains active for approximately 47 minutes is a state-machine/lifecycle defect even if the eventual disconnect is external.

### Source anchors

Audit these exact authorities before editing:

- `prepareProtectedR10CleanOwnerAtLaunch`
- `denseBringUpIsWanted`
- `beginHRFirstDenseBringUpIfNeeded`
- `protectedR10RecoveryDecision`
- `scheduleProtectedR10CleanOwnerProofTimeout`
- `protectedR10CleanOwnerProofHasExpired`
- `protectedR10StabilityWindowIsProven`
- `protectedR10ProofDisconnectDecision`
- the `didDisconnectPeripheral` proof-context path
- `atria.protectedR10.proofDisconnectContext.v1`

### CP0-A — make the proof deadline real

Before touching the phone, add a generation-owned terminal proof controller:

- Capture `{peripheral UUID, connection epoch, clean-owner generation, proof UUID, startedAt, deadlineAt}`.
- At 150 seconds, the exact still-current proof must terminalize once even if no R10 callback, HR callback, scene callback, or disconnect occurs.
- Foreground/background changes may not cancel the terminal deadline silently. If iOS suspension prevents the timer from firing, the first process/scene/HR/BLE callback after the deadline must synchronously terminalize before doing any further protected work.
- A stale timer/callback from an older connection cannot qualify or roll back a newer owner.
- Success cancels only the exact proof deadline.
- Disconnect records H12's full context before owner teardown.
- Different failures must stay distinct:
  - `no_r10_frames_served`
  - `r10_crc_or_layout_rejected`
  - `required_cccd_not_confirmed`
  - `activation_not_acknowledged`
  - `density_or_freshness_below_proof`
  - `corebluetooth_disconnect(domain:code:)`
  - `hr_watchdog_rollback`
  - `proof_deadline_expired`
- No terminal may schedule another attempt automatically.

Do not broaden this into new payload guesses or characteristic scans. The already-proven profile is the only profile allowed.

### CP0-B — preflight for the sole physical attempt

Freeze a read-only baseline immediately before the attempt:

```text
installed bundle version / executable SHA / commit
data-container UUID
strap identifier and battery reading timestamp
charging state
connected peripheral + central state
2A37 notify state and CCCD set
clean owner/state/failure/generation
R10 activation/proof counters
CRC-rejected counter
first/last raw, accepted, durable HR timestamps and counts
last decoded motion timestamp/count
history frontier + lag
v24 bank governor state and verified-step frontier
disconnect/CCCD/watchdog/reconnect counters
```

Attempt only when all are true:

```text
strap is worn
strap battery >70% from fresh strap evidence
iPhone is cabled, unlocked, and connected
Atria has stable current 2A37 HR for >=2 minutes
no history/offload radio owner is active
one fresh explicit Strength or calibration lease exists
no pending prior protected proof
```

If any precondition is false, record `PRECONDITION_BLOCKED(<exact field>)`; perform **zero** protected writes and do not count it as the attempt.

### CP0-C — one attempt, no loop

Use the explicit Strength/calibration authority once:

1. Keep 2A37 active first.
2. Bind the proven protected profile to the exact fresh lease/generation.
3. Confirm required notify/CCCD state.
4. Send the existing single leased activation, at most once.
5. Observe the bounded proof.
6. On failure, restore stable HR exactly once and stop.
7. On success, retain the protected owner and observe a 30-minute motion window including screen lock/background and foreground return.

### Motion acceptance

Success requires every line:

```text
proof terminal = qualified before its exact deadline
fresh CRC/layout-valid R10 advances for >=30 minutes
decoded motion covers >=90% of the proof window
liveStrapMotionCapturedAt advances from current strap evidence
2A37 raw == accepted == durable progression
no accepted-HR gap >=30 seconds
no disconnect, CCCD churn, watchdog, reconnect, or owner rollback
same owner/generation survives lock/background/foreground
one durable source-identified motion receipt exists
verified strap-only motion/step frontier advances
phone/preliminary motion contributes zero authority
```

Dense R10 and v24 are separate authorities. A successful live R10 proof does **not** prove complete all-day v24 bank coverage or exact daily steps. Keep #21 open unless its independent whole-day acceptance also passes.

If the attempt fails, the pass may still ship CP1/CP2, but report CP0 as failed with the exact terminal context. If the context proves the proven Atria profile was sent correctly and the strap still disconnects or serves no valid frames, the next required artifact is an official-app PacketLogger/hardware BLE negotiation trace. Do not install the official app, re-pair, or guess payloads during this pass.

### Required motion tests

At minimum:

1. deadline fires once without any R10/HR callback;
2. background suspension followed by a late callback terminalizes before protected work;
3. old-generation deadline cannot affect a replacement connection;
4. success cancels the exact deadline and preserves fresh authority;
5. each failure category writes a distinct terminal receipt;
6. precondition failure performs zero radio writes;
7. activation is at-most-once;
8. failure restores 2A37 once and never retry-loops;
9. dense R10 never masquerades as all-day v24 completeness;
10. verified motion cannot come from phone or stale timestamps.

---

## CP1 / P0 — surface the real shifted sleep despite continuous post-wake wear

### Physical evidence and current blocker

Expected review core:

```text
09:56:03–10:36:23    2,381 HR / 2,276 RR    mean 62.9, SD 4.0, p90 67
10:39:07–13:39:05   10,527 HR / 9,956 RR    mean 61.1, SD 3.8, p90 64
reconnect seam       164 seconds
resting HR           58 bpm
```

This is review-worthy HR/RR evidence, not motion-validated sleep and not safe auto-confirm authority.

Installed H12 receipt:

```text
source=settlement_completed_deferred_session_load
finalOutcome=not_qualified(mean_hr_above_sleep_band)
heartRateRows=67107
rrRows=42840
frontierUnix=1786634434
compactMotionOutcome=qualified_not_saved
confirmedSleeps 30 -> 30
```

Why it fails:

- review clustering tolerates gaps up to two hours;
- an 08:45–09:23 prelude sits only 32.6 minutes before the low-HR core;
- post-wake wear begins about three seconds after the core and continues roughly eight hours;
- the existing short-prelude splitter requires a >90-minute separating gap;
- the low-HR physiological draft also groups low-HR five-minute bins separated by up to two hours, allowing later quiet-wear bins to stretch the episode;
- the resulting mega-cluster average correctly fails the sleep band.

Do not lower `mean_hr_above_sleep_band`, increase the sleep HR ceiling, globally reduce the two-hour broken-sleep allowance, or auto-confirm this case.

### Required design

Add a **review-only awake-boundary/core extractor**, not a new sleep model:

1. Work from the same immutable canonical HR/RR snapshot and cooperative deadline as `makeBoundedSleepReviewCacheProjection`.
2. Build five-minute robust physiology bins for the bounded 36-hour horizon.
3. Identify candidate low-HR cores using existing sleep-relative HR, density, RR/provenance, clock, duration, dismissal, and confirmation gates.
4. Allow the observed 164-second reconnect seam.
5. Split a trailing continuous-wear tail only when there is positive sustained awake evidence after the candidate core. A mere end timestamp or absence of motion is insufficient.
6. Positive awake evidence should be bounded and robust—for example a sustained run of above-core HR/variability bins—rather than a single spike. Freeze the exact policy in a pure helper and tests.
7. Apply the helper only to **unconfirmed review construction**. It cannot write canonical sleep, Recovery, rings, HRV, stages, notifications, HealthKit, or daily metrics.
8. The final candidate remains `motionValidated=false`, `confidence=review_needed`, and must persist through `AtriaPendingSleepReviewStore` with Confirm / Adjust / Dismiss.
9. The terminal receipt must include original cluster bounds, extracted core bounds, split reason/evidence, row counts, source revision, frontier, and store outcome.

Prefer one shared pure boundary primitive used by the low-HR draft and aggregate review lane. Do not create two subtly different splitters.

### Mandatory sleep fixtures

1. **Exact Aug-13 mega-cluster:** 08:45 prelude + the two physical core sessions + continuous post-wake wear. It returns exactly one unconfirmed review near 09:56–13:39.
2. **Elevated 21:00–09:23 physiology:** still rejected.
3. **True biphasic/resumed sleep:** two low-HR blocks inside the existing two-hour allowance remain one review episode when no sustained awake tail is proven.
4. **Quiet daytime wear/reading:** does not become sleep solely from low HR.
5. **Single post-core HR spike:** cannot trim the boundary.
6. **Sustained post-wake physiology:** trims deterministically and records the evidence.
7. **Confirmed/dismissed overlap:** durable user authority wins.
8. **Old source revision/generation:** cannot replace a newer pending card.
9. **Deadline/revocation:** returns a terminal receipt and no partial store write.
10. **Strong motion-validated sleep:** existing auto-confirm behavior is byte-semantically unchanged.

### Physical sleep acceptance

- Normal no-argument Release launch produces one terminal receipt from the real source revision.
- One review card appears near 09:56–13:39 with Confirm / Adjust / Dismiss.
- It is clearly unconfirmed and motion-unverified.
- `confirmedSleeps` does not change before user action.
- Rings, Recovery, daily metrics, HRV, notifications, widgets, ActivityKit, and HealthKit do not consume it before confirmation.
- Do not press Confirm on the user's real sleep unless the user explicitly asks during the run.
- If the user does confirm/adjust, Today ring, Activity sleep marker, current-cycle identity, and persistence must converge exactly once and survive relaunch.

Close #25 only after the real physical card exists—not from a DEBUG fixture.

---

## CP2 / P1 — finish Stress continuity receipts without touching the model

H12 already physically proved:

- 19:18–19:22 was filled with real replay facts;
- 159/219 previously missing 10:00–13:39 minutes were filled;
- the true 09:24–09:56 HR outage stayed blank;
- the duplicate Vitals Stress row is gone;
- left/right pointer cards stay inside the plot.

Do not redo any of that.

Make only these receipt/source-state corrections:

1. Compare the requested minute set against the **final merged Stress store**, not only the current replay-produced facts. Already-live facts cannot inflate missing/blocker counts.
2. A minute outside the resident row-cap but still inside an unsealed active session must be `source_not_yet_durable(active_journal_row_cap)`, not generic `insufficient_hr_samples`.
3. On session seal/durable source revision, run one generation-gated reconciliation and terminalize those exact minute keys.
4. Genuine raw-HR outages remain blank.
5. No interpolation, carry-forward, invented zero, alternate series, or score-formula change.

Acceptance:

- receipt categories sum exactly to the requested unique minute keys;
- no minute already present in the merged store is called missing;
- the 16:12–16:19 and 16:40–16:43 residuals either become real facts after seal or retain the precise source-not-yet-durable blocker;
- 09:24–09:56 remains a raw-source gap;
- #37 may close only when the receipt and physical timeline agree;
- #32 remains open for labeled model validation.

---

## Tests and build gate

Use serial tests, parallel testing disabled, fresh DerivedData and xcresult. Include at minimum:

```text
AtriaR10TransportPolicyTests
AtriaBLECallbackEpochFenceTests
AtriaBLERecoveryCadenceTests
AtriaBackgroundDrainBacklogTests
AtriaDailyStepPresentationTests
AtriaStepCalibrationPlanTests
AtriaHandoff12Tests
AtriaCompactLatestNightSettlementTests
AtriaSleepReviewCacheTests
AtriaSleepAuditRegressionTests
AtriaStressMonitorTests
```

Add a dedicated H13 suite for the exact physical motion deadline and mega-cluster sleep fixtures. Run a full simulator app compile. A known baseline failure may be documented only after proving it reproduces at exact `ea7fe417` with the same fixture/environment; no changed-path failure is acceptable.

## Signed physical Release gate

Before install:

- hash the exact commit diff and executable;
- inventory the data container and authoritative preference/session/sleep counts;
- ensure no active history write is interrupted;
- preserve pairing and container.

After in-place install:

- one clean no-argument launch;
- migration audit;
- exact executable/commit provenance;
- at least 10 minutes of healthy HR/runtime observation independent of the optional 30-minute motion proof;
- no crash, jetsam, watchdog, HangTracer >=2 seconds, reconnect loop, CCCD churn, or app relaunch;
- preserve screenshots/receipts in a new evidence root.

Use Computer/iPhone Mirroring to capture:

1. Strap/motion authority before the attempt.
2. Exact motion terminal state after the attempt.
3. If qualified, a current live motion/Strength surface after lock/background return.
4. The real Aug-13 Sleep Review card.
5. Stress timeline at the former residual and genuine outage.

If Mirroring is still unavailable because the Mac is locked or touch routing fails, use read-only device probes for authority but do not claim the visual gate passed.

## GitHub hygiene

- Update #21 with the exact preflight, proof UUID/generation, terminal context, R10/2A37 timeline, battery, and verified-motion result. Keep it open unless both live motion and independent whole-day step acceptance pass.
- Update #25 with the original cluster, extracted core, terminal receipt, and physical card. Close only on real-device card evidence.
- Update #37 with corrected receipt counts and residual state. Close only if its stated continuity/UI acceptance is fully satisfied.
- Keep #32 open; this pass does not validate the Stress score against labels.
- Every issue update must include commit, focused-test total/xcresult, Release executable hash, evidence path, and remaining caveat.

## Explicitly out of scope

- New proprietary payload guesses, service/characteristic brute force, repeated R10 attempts, or official-app pairing changes.
- Making high-frequency R10 a 24/7 stream without a separate battery/safety design.
- Global history-drain throughput, ACK/prefix retirement, or cooldown redesign.
- Step-count formula changes, phone/CMPedometer fallback, preliminary count substitution, or missing-time extrapolation.
- Sleep auto-confirm thresholds, stage algorithms, Recovery/HRV/RHR/respiration formulas, or nap ownership redesign.
- Stress model/scoring changes or interpolation.
- SpO2, skin-temperature calibration, relative-skin math, notifications, HealthKit, widgets, ActivityKit, TestFlight, or app-wide visual redesign.

## Required final report

Return one concise report with:

1. exact start/end commits and remote parity;
2. files changed and why;
3. CP0 preconditions, proof UUID/generation/deadline behavior, one-attempt result, and exact failure context or 30-minute success metrics;
4. proof that 2A37 HR remained raw==accepted==durable;
5. proof that dense R10 and all-day v24/steps were not conflated;
6. original sleep cluster, extracted review bounds, terminal receipt, and pending-store authority;
7. confirmation that no metric consumed unconfirmed sleep;
8. before/after Stress receipt counts and the genuine outage;
9. test totals and xcresult paths;
10. signed Release executable hash, migration audit, screenshots, runtime health, issue links, and only genuine remaining blockers.

Do not call H13 complete if CP0 is replaced with another HR-only label, if the proof can outlive 150 seconds silently, if only a synthetic sleep fixture passes, if the real review card is absent, or if Stress diagnostics still count already-present minutes as missing.
