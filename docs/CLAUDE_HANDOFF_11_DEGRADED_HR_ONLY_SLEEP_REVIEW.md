# Atria — Claude handoff 11: surface current sleep for review when compact motion is incomplete

Date: 2026-08-13 (Asia/Kolkata)  
Release branch: `dev`  
Exact pushed starting commit: `1c37a0f09dac74dc654e77256c0ee87c0c00ce28` (`Scope receipt replace-ordering to one process instance`)  
Remote parity verified at handoff: `HEAD...origin/dev = 0 0`  
Clean release worktree: `/private/tmp/atria-notifications-integration.wyA4H7/source`  
Dirty user checkout that must not be touched: `/Users/amanpandey/projects/atria` at `293d1a7c988bf99b6093b8529da0cf528d6e4896`  
Primary issue: [#25](https://github.com/adidshaft/atria/issues/25)

## Mission and hard cutline

This pass has **one product deliverable**:

> When the bounded latest-night compact-motion read is incomplete, sufficiently strong resident HR/RR evidence must still be able to produce one durable, explicitly HR-only **review candidate**. It must never obtain compact-motion commit authority, auto-confirm, mint Recovery, or mutate canonical sleep until the user reviews it.

This is the sole Handoff-10 blocker. Do not turn it into another motion, backlog, stage-model, graph, biomarker, or notification pass.

Timebox: **2–3 hours total**, including focused tests, one deterministic physical fixture, and a normal Release smoke. Maximum two commits. If the design cannot preserve the authority separation below, stop with the exact blocker rather than broadening scope.

## Worktree safety — mandatory

The main checkout contains the user's uncommitted chart work and handoff documents. Never edit, stash, reset, clean, stage, switch, merge, rebase, or commit application source there.

Continue only in `/private/tmp/atria-notifications-integration.wyA4H7/source` after proving:

```text
HEAD = 1c37a0f09dac74dc654e77256c0ee87c0c00ce28
git status --short = empty
git rev-list --left-right --count HEAD...origin/dev = 0 0
```

If the remote moved, fetch and inspect it first. Integrate only by a clean fast-forward or an isolated rebase/cherry-pick whose final diff is audited against this handoff. Never use the dirty main checkout as a merge source.

This handoff document is coordination material and must not enter the app commit.

Use author and committer `adidshaft <adidshaft@gmail.com>`, with no AI/co-author trailer. Push only after all gates pass.

## Verified Handoff-10 state — do not redo it

The exact starting tip already shipped and physically verified:

- Today and prior-day rings use distinct, explicit presentation identities.
- Today no longer borrows yesterday's Recovery/Sleep/Strain as primary values.
- The durable resident live-journal session is already threaded into compact latest-night settlement.
- Orphaned productive-slice starts self-heal across process interruption.
- Sparse Recovery/Strain/Sleep charts no longer clip axes or fabricate ambiguous ticks.
- The final signed Release executable had SHA-256 prefix `05b925282bfbf61a`.
- Handoff-10 tests passed: current-day `380/380`; receipt/BLE `508/508` then `442/442`; chart `8/8`; sleep `196/197`, with the sole failure being the already-documented missing ignored July-26 fixture.

Handoff-10 closure report:

```text
/Users/amanpandey/.codex/attachments/6340a4ee-a04d-4c70-8da2-36256eaa7b2d/pasted-text.txt
SHA-256 6946d1c051871332d076b9e40fbfb6b8df40e0e29d7428aa95a5a1ff213daf20
```

Do not reopen those fixes unless this pass proves a direct regression.

## Fresh read-only preflight

I revalidated the exact clean tip and used Computer + iPhone Mirroring only for observation/navigation. A direct normal launch with:

```text
xcrun devicectl device process launch \
  --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --payload-url 'atria://sleep-review' \
  --activate --terminate-existing false \
  com.adidshaft.atria
```

started PID `38992`. Mirroring showed the already-fixed Strain detail rather than a current sleep-review card. This is a useful baseline observation, not proof of the exact compact-motion failure reason.

Fresh read-only preference pull:

```text
/private/tmp/atria-h11-preflight.2Lkjyt
app-prefs SHA-256: 58c1501715d9ea2d1982b5c83c2fc0439f85c1fd315d4f7bedae94a409c66a10
drainedThroughUnix: 1786613862 = 2026-08-13 15:07:42 IST
rangeLossBackfillPending: true
```

Recovered cache footprint at the pull:

```text
HR rows:       1,147,884
RR rows:         676,082
skin rows:     1,113,605
gravity rows:    750,000
motion IDs:      750,000
physical MB:       1,394
```

No existing persisted field gave the exact `LatestNightReadFailure` for the attempted current sleep. Measure that reason first; do not infer it from the absence of a card.

## Exact defect anatomy at `1c37a0f0`

### 1. The current preparation has only canonical success or total failure

`Atria/Atria/Sessions.swift` around `8780` defines:

```text
CompactLatestNightSettlementProposal
  settlement
  sourceStrapIdentifier
  compactReceipt
  commitAuthority
  row counts

CompactLatestNightSettlementPreparation
  .ready(proposal)
  .withheld(failure)
```

There is no third outcome for a valid HR/RR review that intentionally lacks motion authority.

### 2. Any incomplete compact-motion read discards the HR/RR path

`makeCompactLatestNightSettlementPreparation` around `Sessions.swift:35119`:

1. Builds the bounded latest-night session slice.
2. Reads motion through `AtriaWhoop4MotionTickCompactStore.latestNightMotionRead`.
3. On `.qualified`, attaches compact epochs and continues.
4. On **any** `.incomplete(failure)`, immediately returns `.withheld(.compactMotion(failure))`.

The resident live journal is already available here. It is therefore possible for HR/RR to be current and physiologically reviewable while motion alone prevents any candidate from reaching the review store.

### 3. The existing compact receipt and commit authority are correctly canonical-only

The `.ready` path mints `LatestNightCommitAuthority` from the exact compact receipt. The MainActor commit path around `Sessions.swift:35459` consumes that single-use authority before calling:

- `autoConfirmStrongSleepCandidates`, or
- `commitPreparedWakeBoundarySleepIfUseful`.

Keep this invariant. A degraded HR/RR review must **not** fabricate, borrow, weaken, or bypass `LatestNightCommitAuthority`.

### 4. The existing review builder already supports honest HR-only output

`makeBoundedSleepReviewCacheProjection` around `Sessions.swift:33473`:

- runs under a shared cooperative deadline;
- uses bounded canonical/resident sessions;
- uses `.attachedCompactOnly`, so it never opens the full motion archive;
- emits an unconfirmed `SleepHistorySnapshot.Night`;
- sets `motionValidated = false` and `confidence = "review_needed"` for HR-only candidates;
- computes only qualified in-window physiology;
- respects confirmed-sleep and dismissal authority.

Reuse this truth model. Do not create another sleep detector.

### 5. The UI projection is intentionally foreground-only

`shouldEnqueueSleepReviewProjection` around `Sessions.swift:33060` requires both foreground authority and `UIApplication.State.active`. The worker's final publication also rechecks foreground state and generation.

Keep that rule for `@Published`/UI mutation. The missing design is a separate background-safe **durable receipt publication** that the next active edge can reconcile into the UI exactly once.

### 6. A durable pending-review store already exists

`Atria/Atria/AtriaPendingSleepReviewStore.swift` already persists one unconfirmed candidate and rejects:

- confirmed overlaps;
- dismissed overlaps;
- implausible windows;
- stale receipts older than 72 hours.

Evolve this store additively rather than creating an unrelated second pending-sleep database.

### 7. The recovered current-cycle lane can legitimately run outside the foreground

`runRecoveredCurrentCyclePublicationStep` and `runRecoveredSleepSettlementStep` around `Sessions.swift:17293` and `17599` call the same settlement lane under an exact recovered foreground or explicit-background execution authority. A review receipt must be persistable there without requiring UIKit active state, while UI publication remains deferred until activation.

## Required implementation contract

### Checkpoint 1 — split canonical settlement from review-only settlement

Give compact latest-night preparation three semantically distinct outcomes. Names may vary, but the type system must make this separation obvious:

```text
.canonical(motion-qualified proposal + exact compact receipt + commit authority)
.reviewOnly(HR/RR review proposal + explicit motion blocker + evidence fingerprint)
.withheld(failure)
```

Rules:

1. `.canonical` preserves the current code and gates unchanged.
2. `.reviewOnly` contains **no** `LatestNightSourceReceipt` that can be used as canonical authority and **no** `LatestNightCommitAuthority`.
3. `.reviewOnly` may call only the bounded review builder and durable review-store path. It must be structurally impossible to pass it into `autoConfirmStrongSleepCandidates` or `commitPreparedWakeBoundarySleepIfUseful`.
4. `.withheld` remains the result for invalid HR/RR input, source-integrity uncertainty, cancellation, or an exceeded review budget.

Suggested review-only carrier:

```text
night: unconfirmed SleepHistorySnapshot.Night
motionBlocker: exact LatestNightReadFailure
evidenceFingerprint: stable digest of the candidate window and HR/RR authority
preparedAt
source strap ID
session count / HR rows / RR rows
resident-journal ID + end bucket (if used)
captured canonical/review/confirmed-sleep revisions for same-process fencing
settlement authority domain + generation for callback validation
```

Do not persist process-local revisions as cross-launch truth. They are same-process compare-and-swap fences only. The durable fingerprint must derive from stable evidence identity, not an incrementing in-memory counter or mtime.

### Checkpoint 2 — classify incomplete motion honestly

The compact store's exact failures are:

```text
invalidRequest
thermalCritical
shardCapExceeded
missingShard
byteCapExceeded
rowCapExceeded
integrityFailure
deadlineExceeded
sourceChanged
```

Required policy:

- `missingShard`, `shardCapExceeded`, `byteCapExceeded`, and `rowCapExceeded` may enter the HR/RR review-only lane **if and only if** the independent HR/RR review gates pass. The user-facing provenance must say motion could not be verified; a cap failure is not evidence that the strap has no motion.
- `invalidRequest`, `integrityFailure`, `sourceChanged`, `deadlineExceeded`, and `thermalCritical` remain withheld/retry/blocker outcomes. Do not turn a programming error, corrupt source, race, expired lease, or adverse environment into an apparently qualified sleep review.
- Every result records the exact failure string. Do not collapse everything into `motion unavailable` in diagnostics.
- If physical evidence reveals a different safe classification, document it in #25 and add a direct test before changing the table.

### Checkpoint 3 — build one HR/RR review from the same bounded source

For an eligible incomplete-motion failure:

1. Use the already-capped canonical + resident-journal latest-night session slice.
2. Strip/ignore unqualified motion; never query the full archive as a fallback.
3. Call the existing bounded sleep-review projection with a shared absolute deadline.
4. Require its existing gap, coverage, duration, physiology, confirmed-overlap, and dismissal gates.
5. Select at most one main review candidate for this lane. Existing nap handling remains separate.
6. If there is no candidate, return a named terminal reason such as `hr_rr_review_not_qualified`; do not leave the UI on `Loading…` and do not persist an empty candidate.

The review candidate must remain:

```text
confirmed = false
motionValidated = false
confidence = review_needed (or the existing exact HR-only review value)
source = existing sleep-review source grammar
```

Any RHR, HRV, or respiratory-rate field must come only from that candidate's qualified window. Never borrow a prior night's HRV or Recovery.

HR-only stage segments may be materialized only through the existing bounded HR-only estimator and must retain the exact product labels:

```text
Estimated stages · HR-only
lower confidence / motion not verified
```

If staging cannot qualify, show a terminal unavailable state rather than inventing stage boundaries.

### Checkpoint 4 — persist truth in background; publish UI only when active

Do not weaken `shouldEnqueueSleepReviewProjection` or `shouldPublishSleepReviewProjection`.

Instead:

1. Persist a qualified `.reviewOnly` result to an additive evolution of `AtriaPendingSleepReviewStore` from the settlement utility worker or its exact serialized completion path.
2. Persistence must not mutate `@Published`, SwiftUI, widget, ActivityKit, HealthKit, daily metrics, Recovery, sleep history, or confirmed-sleep state.
3. Store an exact evidence fingerprint and motion blocker so identical callbacks dedupe.
4. Record a durable dirty/reconciliation signal or make foreground resume discover the stored receipt without source-publisher activity.
5. On `scene_active`, `UIApplication.didBecomeActive`, or normal `onAppear`, the existing foreground review projection must reconcile the durable candidate, recheck current authorities, and publish the latest one exactly once.
6. Backgrounding again before UI publication must leave the durable review intact but perform zero UI mutation.

The recovered current-cycle component may count a successfully persisted review receipt as a completed review outcome so the broader recovered pipeline does not fail solely because motion was unavailable. It must not count as a canonical sleep save.

Prefer a typed settlement completion result over extending another ambiguous Boolean, for example:

```text
canonicalSaved
reviewPersisted
noCandidate
withheld(reason)
authorityLost
```

Do not refactor unrelated recovered components merely to introduce this type.

### Checkpoint 5 — exact authority, dedupe, and user precedence

Capture and recheck before durable persistence and again before UI install:

- settlement worker generation and authority domain;
- canonical/review evidence revision;
- confirmed-sleeps revision;
- current strap identity;
- active resident-journal ID/end bucket used by the proposal;
- candidate evidence fingerprint;
- cancellation/thermal state where applicable.

Required outcomes:

1. A stale background callback cannot overwrite a newer candidate.
2. A stale callback cannot resurrect a candidate the user confirmed, edited, dismissed, deleted, or reclassified.
3. Identical evidence produces one durable review, not repeated cards or notifications.
4. A later motion-qualified preparation for the same window may enrich/replace the unconfirmed review or enter the existing canonical lane, but never duplicate it.
5. User authority wins over both the degraded and later motion-qualified worker.
6. Re-pairing the strap invalidates an old source identity.

Evolve the pending-store schema additively. Legacy v1 records may remain readable, but they must not acquire stronger authority from absent new provenance fields.

### Checkpoint 6 — canonical mutation stays motion-qualified

Add structural and behavioral fences proving that `.reviewOnly` cannot call:

- `autoConfirmStrongSleepCandidates`;
- `commitPreparedWakeBoundarySleepIfUseful`;
- `saveConfirmedSleeps`;
- Recovery/daily-metric publication;
- widget or share numeric sleep publication;
- HealthKit;
- a `sleep logged` notification.

The existing compact receipt, single-use commit authority, source-strap comparison, fingerprint CAS, thermal check, and canonical auto-confirm behavior remain byte-semantically unchanged unless a direct test requires a narrow compile adaptation.

## UI contract

When a strong HR/RR candidate exists but motion is incomplete:

```text
Sleep detected — review
<start>–<end> · <duration>
HR/RR estimate · motion not verified
[Review]
```

Use existing product copy if it already conveys the same facts. Requirements are semantic:

- It is visibly a review request, not a confirmed sleep.
- It does not say motion was absent when the exact reason was a read cap.
- It does not show `Loading activity…` indefinitely.
- Today may surface the review card, but today's Sleep/Recovery rings remain `Awaiting current sleep` until confirmation under the existing product contract.
- Activity may show the review row, but it must not look canonical or counted.
- HR-only stage presentation remains explicitly estimated.

If HR/RR cannot qualify, show a terminal named blocker such as:

```text
No review candidate yet · heart-rate coverage incomplete
```

Do not fabricate a card solely to make the UI nonempty.

## Bounded diagnostic receipt

The current physical prefs do not retain the exact compact failure. Add one bounded diagnostic receipt only if existing logs cannot prove it. Suggested key:

```text
atria.debug.sleepCompactReviewReceipt.v1
```

Keep at most 16 small events or one latest record. Include no raw arrays. Fields:

```text
timestamp
window start/end
outcome: canonical / reviewOnly / withheld
exact motion failure
session / HR / RR counts
accepted HR coverage and maximum gap used by review gates
resident journal ID + end bucket
source strap pseudonymous identity/fingerprint
authority domain + generation
durable review saved: 0/1
UI published: 0/1
terminal reason
```

The diagnostic is evidence only. It grants no publication or canonical authority.

## Required tests

Run only the focused matrix needed for this pass. Add direct behavioral tests, not source-string-only tests, for:

1. `missingShard` + strong bounded HR/RR produces `.reviewOnly` with no compact receipt/commit authority.
2. shard/byte/row cap + strong HR/RR can produce review-only with the exact cap blocker.
3. `integrityFailure`, `sourceChanged`, `deadlineExceeded`, `thermalCritical`, and `invalidRequest` remain withheld.
4. weak/gappy HR/RR + missing motion produces no candidate and a named blocker.
5. review-only preparation cannot enter either canonical commit function.
6. background settlement persists one review and emits zero `@Published`/UI updates.
7. activation consumes the persisted review once with no later source publisher required.
8. duplicate background callbacks dedupe by stable evidence fingerprint.
9. stale canonical/confirmed/review revision rejects persistence and UI install.
10. user confirm/edit/dismiss/delete/reclassify between preparation and publish wins and prevents resurrection.
11. later matching motion-qualified evidence reconciles without a duplicate card.
12. app relaunch preserves one eligible review; expiry and confirmed/dismissed overlap still remove it.
13. current Today rings remain awaiting/partial; review-only does not mint Recovery, daily metrics, widget sleep, HealthKit, or a sleep-logged notification.
14. exact BLE raw/accepted HR journal and archive/drain authorities are untouched.

Focused suites should include at least:

```text
AtriaCompactLatestNightSettlementTests
AtriaSleepReviewCacheTests
AtriaPendingSleepReviewStoreTests
AtriaTodaySleepReviewProjectionTests
AtriaOverviewCurrentSleepTests
AtriaSleepImmediateProjectionTests
AtriaSceneResumePolicyTests
AtriaRecoveredDataMutationTransactionTests
AtriaSleepReviewNotificationDebounceTests
AtriaCurrentDayPresentationTests
```

Use the `AtriaTests` scheme, simulator parallelism off, maximum workers `1`, and a fresh `.xcresult`. Also run a normal simulator build. Do not launch a full-suite marathon after the focused matrix is green.

## Physical acceptance — required, bounded, non-destructive

The phone currently runs Release. Reinstall Debug only if needed for the deterministic fixture, then restore a signed Release normal build for final smoke.

Device:

```text
Aman's iPhone / iPhone 15 Pro
CoreDevice ID: 3803F5B6-1666-56D3-A71A-62F131F6CE3B
bundle: com.adidshaft.atria
```

Use Computer with **iPhone Mirroring** for screenshots. Synthetic clicks have previously landed roughly 123 px above the target and the bottom tab bar can be unreachable; prefer deep links:

```text
atria://sleep-review
atria://overview
atria://vitals
```

Never open Safari, Brave, or Passwords.

### A. Deterministic Debug fixture

Add a DEBUG-only fixture representing:

- compact motion `.incomplete(.missingShard)`;
- dense, physiologically plausible resident HR/RR through wake + tail;
- no validated motion;
- no overlapping confirmed sleep or dismissal.

Physical proof must show:

1. One `Sleep detected — review` card.
2. HR/RR-only / motion-not-verified labeling.
3. Estimated-stage labeling if stage materialization qualifies.
4. Today Recovery/Sleep rings remain awaiting/partial, not newly canonical.
5. Background → active and one relaunch preserve exactly one card.
6. No automatic confirmation occurs and no user sleep record changes.

Do **not** tap Confirm on the user's real data. The fixture may use an isolated debug store/namespace.

### B. Real Release data

Install the signed Release in place and audit migration before and after. Launch once with no arguments.

Pull the compact-review diagnostic and capture whichever truthful outcome the actual corpus produces:

- a real review candidate, or
- a named `hr_rr_review_not_qualified`/motion/source blocker.

No real candidate is acceptable if the evidence does not pass. The acceptance requirement is that the app reaches a terminal truthful state and the receipt explains why.

Verify:

- normal PID stays stable;
- live HR remains current;
- no crash, jetsam, cpulimit, disconnect, or process relaunch;
- history/frontier behavior is unchanged;
- sessions, confirmed sleeps, daily metrics, prefs, and journal authority survive install/relaunch;
- review-only publication changes none of those canonical stores.

If the actual current night no longer exists inside the 72-hour review horizon, do not extend expiry to force the test. Keep #25 open for the next genuine night after fixture closure.

## Explicitly out of scope

- No R10/IMU protocol work, radio writes, motion-bank experiments, motion decoder changes, or step changes.
- No history-drain throughput, ACK ordering, durable-prefix retirement, sequence-gap, or `persistedDrainResumeAllowed` changes.
- No new sleep detector or sleep-stage model.
- No Recovery formula, cycle ownership, main/nap reclassification, ring, graph, or Activity redesign.
- No SpO2, absolute skin temperature, relative-skin, PPG, HealthKit, widget, ActivityKit, or notification-catalog work.
- No TestFlight.
- No broad refactor of the 50k-line `Sessions.swift`.
- Never weaken a source-integrity or lifecycle gate simply to surface a card.

## Commit, push, and issue hygiene

Prefer one focused commit; maximum two:

1. degraded HR/RR review preparation + durable/foreground reconciliation + tests;
2. only if necessary, deterministic physical fixture or a defect found during acceptance.

Before each commit:

```text
swift parse for every changed Swift file
git diff --check
focused serial tests green
simulator build green
review git diff --stat and every changed path
```

Before push:

```text
git fetch origin
prove remote did not move unexpectedly
prove clean worktree
prove author/committer identity
prove no AI/co-author trailer
prove fast-forward parity after push: 0 0
```

Update [#25](https://github.com/adidshaft/atria/issues/25) with:

- exact start/end commits;
- the observed physical `LatestNightReadFailure`;
- review versus withheld receipt fields;
- focused-test count and `.xcresult`;
- executable hash and install/migration result;
- Mirroring screenshots;
- proof that no canonical sleep/Recovery/widget/HealthKit mutation occurred.

Close #25 only if its issue body has no other open criteria **and** a real or deterministic physical review survives relaunch without auto-confirming. Otherwise leave it open with the sole remaining physical criterion. Do not churn unrelated issues.

## Definition of done

This handoff is complete only when all of these are true:

- [ ] Motion-qualified canonical settlement is unchanged and still requires its exact compact commit authority.
- [ ] Eligible incomplete motion can produce one bounded HR/RR review-only candidate.
- [ ] Review-only carries no canonical commit authority and cannot auto-confirm.
- [ ] Background execution can persist the review without UI mutation.
- [ ] Foreground activation reconciles and publishes it exactly once.
- [ ] User confirm/edit/dismiss/delete/reclassify always wins.
- [ ] Weak/corrupt/stale evidence reaches a named terminal blocker, not infinite Loading.
- [ ] Today/Recovery/daily metrics/widget/HealthKit remain unchanged until confirmation.
- [ ] Focused tests and simulator build are green.
- [ ] Debug fixture is visually proven in iPhone Mirroring.
- [ ] Signed Release normal launch is stable and data-preserving.
- [ ] #25 contains exact evidence and remains open or closes truthfully.
- [ ] Branch push is a clean fast-forward with parity `0 0`.

## Required final report

Return a concise closure report with:

1. Start and final commit hashes, commit messages, author/committer, remote parity.
2. Exact source files changed and why.
3. Exact runtime motion failure observed.
4. Canonical vs review-only authority proof.
5. Focused test/build counts and artifact paths.
6. Debug-fixture and real-Release screenshots/evidence.
7. Before/after canonical store hashes proving no review-only mutation.
8. Issue #25 URL and whether it remains open.
9. Any remaining blocker, stated as one concrete sentence.

