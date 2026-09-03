# Atria — Claude handoff 9: finish cold HR latency, accelerate proven catch-up, verify notifications, and expose relative-skin truth

Date: 2026-08-13 (Asia/Kolkata)  
Release branch: `dev`  
Exact pushed starting commit: `0bc84fdd3ee6184d756839f85e921420a370a810` (`Harden notification settings cancellation`)  
Remote parity verified at handoff: `0bc84fdd...origin/dev = 0 0`  
Clean release worktree: `/private/tmp/atria-notifications-integration.wyA4H7/source`  
Integrated notification commits: `61fec3b12e5b30c3b486f992654581c309df6f7f`, `0bc84fdd3ee6184d756839f85e921420a370a810`  
Tracking issues: [#35](https://github.com/adidshaft/atria/issues/35), [#21](https://github.com/adidshaft/atria/issues/21), [#31](https://github.com/adidshaft/atria/issues/31), [#36](https://github.com/adidshaft/atria/issues/36)

## Mission and hard cutline

This is the final bounded closure pass for the work Handoff 8 left genuinely incomplete. Do these in order:

1. **P0 — eliminate the remaining mutable-active-chunk floor in Activity historical HR.** The same real completed-day cold lookup must reach a terminal result in at most 3 seconds, not 23–30 seconds.
2. **P0 — make a productive history backlog catch up at a useful rate.** The measured `1.148x` slope technically converges but takes roughly 15 hours to clear a 2.3-hour lag. Shorten cadence only after an exact durable-frontier advance; failure/no-progress keeps the existing five-minute brake.
3. **P1 — physically verify the already-integrated notification catalog.** Do not re-cherry-pick, merge, or redesign it. Only fix a notification defect if physical evidence disproves the shipped contract.
4. **P1 — keep the experimental relative-skin row visible while blocked.** Show a truthful named blocker/progress state; never invent a numeric value.
5. Run focused tests, one signed in-place install, physical checks through iPhone Mirroring, commit/push, and update the four issues.

Timebox: roughly 4 hours implementation plus 45 minutes physical acceptance. If one checkpoint cannot meet its gate, stop with the exact blocker and evidence. Do not turn this into another open-ended research pass.

Explicitly out of scope:

- More R10/IMU activation, protocol writes, service discovery, ownership, or cooldown experiments.
- More sleep-stage, sleep-detection, nap/main, graph-system, chart-style, or activity-marker work.
- SpO₂ formulas, raw Red/IR ratios, absolute skin-temperature conversion, or medical claims.
- WHOOP API/OAuth work, Passwords, Safari, or Brave.
- TestFlight.
- A full-suite marathon after the focused matrix and signed build are green.

## Worktree safety — mandatory

The user's main checkout at `<repo-root>` is intentionally dirty and old at `293d1a7c988bf99b6093b8529da0cf528d6e4896`. It contains the user's chart work and handoff documents.

Do **not** edit, stash, reset, clean, stage, switch, merge, rebase, or commit application source in the main checkout.

Continue in `/private/tmp/atria-notifications-integration.wyA4H7/source` only after proving:

```text
HEAD = 0bc84fdd3ee6184d756839f85e921420a370a810
git status --short = empty
HEAD...origin/dev = 0 0
```

If that worktree is unavailable or dirty, create a fresh detached worktree from `origin/dev`. This handoff file is coordination material; do not add it to an app commit.

The old `/private/tmp/atria-notifications-wt` worktree and `claude/notifications-2026-08-13` branch are historical inputs only. Their commit was already cherry-picked and hardened on the release branch. Do not merge, cherry-pick, rebase, push, or delete that branch/worktree in this pass.

## Verified Handoff-8 state — do not repeat

### Shipped commits

- `bbe9c1ac5051bd92e03ae25cee0209b3ca5ab9fa` — sealed-chunk HR sidecars, exact-window cache, preparing state, and read receipts.
- `7537161c22b3e97b00cbc93e08e2446ac20cec24` — persisted blocker-first relative raw-skin summaries and Vitals wiring.
- `61fec3b12e5b30c3b486f992654581c309df6f7f` — typed 17-category notification catalog, event schedulers, settings copy, dedup ledger, and four default-off categories.
- `0bc84fdd3ee6184d756839f85e921420a370a810` — fail-closed unknown notification kinds and exact pending-request cancellation for category/master opt-out.

All four are on `origin/dev` with parity `0 0`.

### Historical-HR measurements

The exact Aug-11 read always returned the same 90,018 ordered points:

| Run | Elapsed | Raw-scanned files | Raw-scanned bytes |
| --- | ---: | ---: | ---: |
| Pre-index baseline | 82,969 ms | 8 | 226,354,842 |
| First touch / sidecar construction | 97,853 ms | 8 | 231,685,973 |
| Cold with sealed sidecars | 23,722 ms | 1 | 32,255,602 |
| Cold repeat launch | 30,374 ms | 1 | 32,255,602 |

The sidecar design is correct and should stay:

- `hr-index-v1/` is bound to exact sealed catalog identity: relative path, byte count, SHA-256, and row count.
- Active, corrupt, stale, mismatched, truncated, or otherwise unproven indexes are never trusted.
- Exact-window cache is source-fingerprint and reader-version keyed.
- UI changes to `Preparing recorded history…` after 500 ms.
- Sealed-sidecar and raw readers return identical ordered truth.

The sole remaining file is the mutable UUID catalog active chunk, measured at 30.8 MiB against a 32 MiB cap. Raw parse throughput was about 2.7 MiB/s. This is now a measured archive-layout floor, not a SwiftUI invalidation problem.

### Backlog measurement

The settled 30-minute window proved:

```text
frontier slope: 1.148x
frontier advance: 2,099 s over 1,828 s wall
net lag: 8,563 s -> 8,292 s (-271 s)
post-window lag: 8,131 s and falling
live accepted HR: current
sequenceGap keys: empty
history owners: one
```

That is safe progress, but it is not a satisfying product result. At the measured net rate, a 2.3-hour backlog needs about 15 hours of uninterrupted connected wear to clear. The next pass may make one cadence correction, but only from durable progress evidence.

### Relative-skin pipeline

The producer/store is complete and should stay:

- Exact v24/70-byte/offset-68 sensor authority.
- Same-strap, same-algorithm, same confirmed-sleep revision only.
- Current night persists only after a complete snapshot channel and drain frontier beyond sleep end.
- Prior independently proven nights survive unrelated later gaps.
- Edit/delete/nap reclassification invalidates the exact sleep summary.
- No °C/°F, `skinTemperatureDeviationCelsius`, HealthKit, recovery, widget, report, or export path.

### Integrated notification state

The original notification feature was replayed cleanly onto `7537161c` as `61fec3b1`. It adds 8 files / 1,094 insertions / 38 deletions:

```text
AtriaApp.swift
AtriaEventNotificationScheduler.swift                 (new)
AtriaHapticAlerts.swift
AtriaHomeView.swift
AtriaNotificationCategories.swift                    (new)
Sessions.swift
AtriaEventNotificationPolicyTests.swift              (new)
AtriaNotificationCategoryTests.swift                 (new)
```

The bounded hardening commit `0bc84fdd` adds exact category-to-pending-request ownership, category/master cancellation adapters, fail-closed handling for unknown user-facing kinds, and direct tests. The combined release tip passed:

```text
AtriaTests focused notification matrix: 91/91 passed, 0 failed/skipped/warnings
xcresult: /private/tmp/atria-notifications-integration.wyA4H7/FocusedNotifications.xcresult
simulator Atria build: succeeded, 0 errors
build xcresult: /private/tmp/atria-notifications-integration.wyA4H7/SimulatorBuild.xcresult
```

Do not repeat integration. Preserve these contracts while implementing the remaining checkpoints.

## Fresh physical truth from this handoff

I used Computer Use directly with iPhone Mirroring (`com.apple.ScreenContinuity`) against the installed Handoff-8 build. Taps and scrolling worked in this session; do not claim Mirroring is blocked without retrying both element and coordinate actions. The notification commits are pushed but have not yet had their own signed physical install/Settings inspection.

The currently installed app showed:

```text
strap battery: 56%
live HR: 69–70 bpm
banner: Strap data gap · history incomplete
Recovery: 92%
confirmed sleep: 9 h 12 m
RHR: 52 bpm
HRV: --
Respiration: 9.5/min
Skin temp: -- · Decoder not verified
SpO2: -- · Not available on this strap
```

The experimental `Relative skin signal` row was **absent**. Source confirms why: `AtriaRelativeSkinSignalPresentation.content` returns `nil` for `.incompleteArchive`, `.noCurrentRawEvidence`, no confirmed main sleep, or unknown/mixed authority, and `AtriaRelativeSkinSignalRowView` therefore renders nothing. That invisibility is the remaining product gap; the numeric gate itself is correct.

## Checkpoint 1 (P0): remove the active-chunk historical-HR floor

### Exact source facts

The relevant mutable raw-v2 cap is:

```swift
AtriaHistoricalArchiveCatalogStore.productionMaximumActiveBytes
    = 32 * 1024 * 1024
```

in `Atria/Atria/AtriaHistoricalArchiveCatalog.swift`.

Do **not** confuse or change these unrelated 32/128 MiB constants:

- `AtriaWhoop4HistoricalIngressSpool.productionMaximumBytes`
- recovered-projection/pass byte budgets
- legacy `HistoricalArchive.rotationThresholdBytes = 128 MiB`
- session persistence bounds

`AtriaHistoricalArchiveCatalogStore.writableChunkURL(now:)` seals at a day or size boundary, synchronously records immutable byte count + SHA-256, creates a fresh active chunk, persists the new catalog generation, and never reopens a sealed filename.

The exact-window reader trusts sidecars only for sealed/digested chunks. A sealed chunk without a sidecar is scanned once and gets one. The active chunk is always conservatively scanned.

### Authorized bounded design

Use **smaller raw-v2 active chunks**, not a mutable-prefix index, in this pass.

Target `4 MiB` for `productionMaximumActiveBytes`. This keeps the integrity model simple:

```text
sealed immutable chunk -> exact digest -> trusted HR sidecar
current active chunk <= ~4 MiB -> conservative raw scan
```

Do not add a durable append-prefix index unless the 4-MiB design fails the explicit rotation/continuity gate below. An append-prefix authority has substantially more crash/concurrency surface and is not the shortest safe fix.

Implementation requirements:

1. Lower only the raw-v2 catalog production active limit to 4 MiB.
2. Existing oversized active chunks must seal on the next ordinary append. Never rewrite, truncate, split, or delete the old active bytes.
3. Detect the exact chunk that just became sealed and schedule its HR-sidecar construction on the existing utility historical-consumer lane **after the catalog lock and promotion lock are released**.
4. Sidecar construction is best-effort and derived. It must never delay, authorize, reorder, or fail a raw append, durable flush, ACK, prefix retirement, or live HR ingestion.
5. Coalesce duplicate sidecar builds by exact chunk identity. A query racing an in-flight sidecar build may keep the typed `.preparing` state or conservatively scan; it may not trust a partial file.
6. A sidecar becomes visible only after the existing atomic write + exact binding validation.
7. Keep the result-cache/source-fingerprint invalidation unchanged.
8. Keep all parsing and hashing off MainActor.

### Rotation safety gate

Measure actual production rotation cadence from the physical corpus. Pass when:

- No synchronous append/flush stall attributable to sealing exceeds 100 ms on the device.
- No raw/accepted/durable HR gap reaches 30 seconds.
- No ACK, disconnect, CCCD, process, watchdog, or drain-owner regression occurs.
- Rotation/index work consumes less than 5% of the observed drain window.
- The 4-MiB limit does not produce more than 12 rotations/hour during the active backlog drain.

If the rotation gate fails, stop and report it. Do not silently widen authority to an unsealed prefix. Issue #35 already records the append-prefix alternative for a future dedicated design.

### Required tests

- Catalog store rotates at the configured size boundary and never before it.
- Upgrade fixture: an existing 30+ MiB active file seals intact on the next append under the new limit; catalog/file SHA matches and a new active chunk owns the new line.
- Old sealed chunk is never reopened or modified.
- Seal schedules exactly one coalesced sidecar build outside the catalog critical section.
- A query during build never observes a temporary/partial sidecar.
- Active <=4 MiB remains conservative; sealed sidecar returns byte-equivalent points/empty truth.
- Corrupt/missing sidecar still falls back safely.
- Day A -> day B -> late A cancellation behavior remains unchanged.
- Performance fixture proves bounded raw byte visits: valid sealed sidecars plus at most the active-chunk bound.

### Physical acceptance

For Activity -> `TUE, AUG 11` -> Heart rate:

- Run three cold process launches after the oversized active file has sealed and its sidecar is valid.
- Run three warm exact-window navigations in one process.
- Cold terminal: <=3,000 ms each.
- Warm terminal: <=250 ms each.
- Scanned raw files: at most one active chunk.
- Scanned raw bytes: <=4 MiB plus one record-boundary tolerance.
- Returned points remain exactly 90,018 in the same order for the known fixture/window, or attach the exact source-fingerprint reason if the live corpus has legitimately advanced.
- No MainActor slice >=100 ms from the read.

Close #35 only if the real physical cold criterion passes.

## Checkpoint 2 (P0): accelerate only durably productive backlog slices

### Exact source-backed bottleneck

The connected catch-up path currently applies the same 5-minute interval twice:

1. `automaticConnectedHistoricalHandoffIsEligible` calls `shouldAttemptAutomaticConnectedHistoricalHandoff(... attemptCooldown: automaticConnectedHistoryAttemptCooldown)`.
2. `requestOfflineHistoricalSyncIfNeeded` calls `historicalAttemptMinimumInterval(... connectedHandoffInterval: automaticConnectedHistoryAttemptCooldown)`.

`automaticConnectedHistoryAttemptCooldown` is 300 seconds.

There are already shorter progress-aware constants:

```text
catchUpProductiveRetryInterval = 60 s
rangeLossBackfillProgressChainInterval = 8 s
```

but the exact connected-handoff admission still receives 300 seconds. That matches the observed 4–6 minute idle holds.

Do **not** simply reuse `OfflineSyncDefaults.lastDrainAttemptYieldedRows` as permission to shorten the cooldown. Its current writer in `finishHistoricalDrainTelemetry` sets it from `historicalDrainTelemetry.stream5Received > 0`. Receiving a frame is not the same as durably advancing the verified frontier; parse/persist/flush/authority failure could still follow.

### Authorized bounded correction

Add one exact generation-scoped **durable productive-slice receipt**. It may earn the 60-second connected retry only when all of these are true:

```text
same active history generation
at least one row durably persisted in the exact batch
durable flush receipt succeeded
accepted ACK/durable boundary rules remained satisfied
drainedThroughUnix advanced beyond that attempt's captured start frontier
terminal cleanup restored/retained current live-HR authority
no persist/flush/ACK/owner/stale-generation error
```

Suggested compact receipt fields:

```text
generation
attemptStartedAt
startFrontierUnix
endFrontierUnix
durableRowsDelta
flushSequence/boundary identity
liveRestoredAt
status = productive | noProgress | failed
```

Rules:

1. Persist/replace the receipt only from the exact final durable boundary. Stale callbacks cannot update it.
2. `productive` selects `catchUpProductiveRetryInterval` (60 s) for both the eligibility gate and the later transport-throttle gate.
3. `noProgress`, missing/unreadable/corrupt receipt, any failure, a changed gap fingerprint, disconnect storm, active workout, stale HR, foreground policy, or unresolved owner keeps the existing 300-second connected brake.
4. The same computed interval must feed both gates; do not reintroduce contradictory cooldowns.
5. The 8-second chain remains only its existing scheduling delay. It does not bypass the 60-second durable cadence.
6. Do not change ACK order, exact-boundary retirement, sequence-gap authority, live-HR protection, workout guards, or the global fallback cooldown.
7. If the productive receipt cannot be proved on the present protocol, make no throughput edit and return that exact blocker.

### Required tests

- Stream5 RX without durable frontier advance does not earn a fast retry.
- Durable rows with flush failure do not earn a fast retry.
- Durable flush with unchanged frontier does not earn a fast retry.
- Exact durable frontier advance + live restoration earns 60 seconds.
- Same progress receipt feeds both admission and throttle gates.
- Stale generation, changed gap fingerprint, active workout, disconnect storm, stale accepted HR, and foreground remain blocked.
- Failure/no-progress returns to 300 seconds; no tight loop.
- Repeated productive attempts never create two owners or overlap generations.
- Live raw/accepted/durable journal behavior is byte-for-byte unchanged.

### Physical acceptance

Run one settled 30-minute locked/background window, sampling every 60 seconds. Capture the same fields used in Handoff 8 plus the new productive receipt.

Hard safety pass:

- Maximum live raw/accepted/durable HR gap <30 seconds.
- One process PID and one history owner.
- Zero reconnect/CCCD storm, false Bluetooth-off, watchdog, resource, jetsam, or crash event.
- Exact ACK/prefix retirement and gap truth remain valid.

Throughput goal:

- Target frontier slope >=2.0x with a real backlog.
- Net lag must fall continuously across the settled window.
- If slope remains <1.5x after this one correction, stop. Attach the exact radio/persistence wait anatomy and keep #21 open; do not start tuning more cooldowns.

Do not close #21: whole-day step accuracy remains independently open even if catch-up latency improves.

## Checkpoint 3 (P1): physically close the typed local-notification catalog

Tracking issue: [#36](https://github.com/adidshaft/atria/issues/36).

### Already shipped — do not reimplement

The integration and two source-level safety repairs are complete at `0bc84fdd`:

- One typed catalog owns all 17 user-facing kinds, settings rows, defaults, and descriptions.
- Four new categories remain default off: second-sleep primary choice, learned bedtime wind-down, catch-up complete, and parked/unrecoverable interval.
- Unknown user-facing kinds fail closed and log; only the explicit developer `diagnostic` kind bypasses user-facing category lookup.
- Turning one category off cancels only its exact identifiers/prefixes.
- Turning the master off cancels all known Atria user-facing pending requests, while leaving delivered history, diagnostics, unknown future identifiers, and unrelated requests untouched.
- The event-key dedup ledger stays bounded.
- No push/cloud transport, health-authority mutation, BLE ownership, or archive authority was introduced.

The focused 91-test result and simulator build are already green. Do not spend this pass rewriting tests or scheduler architecture. Re-run notification tests only because later release-tip changes must not regress them.

### Physical verification still required

The intended notification product contract is sound and should remain:

- One typed catalog for all 17 user-facing kinds.
- Four new categories default off: second-sleep primary choice, bedtime wind-down, catch-up complete, parked interval.
- Existing effective defaults preserved.
- On-device `UNUserNotificationCenter` only; no push/cloud transport.
- New events observe already-published state and never drive BLE, archive, sleep, or workout state.
- Bounded event-key dedup ledger.
- Learned bedtime only; no generic invented bedtime.
- Honest sync copy and deep links to existing Atria surfaces.
- Full alert authorization requested only after an explicit user enable.

Inspect the signed device build through Settings and a read-only pending-request dump before changing any preference. Required evidence:

1. All 17 catalog rows are present, readable, and agree with scheduler/category identifiers.
2. The four new categories are off after migration from the user's existing settings.
3. First launch after install triggers no unsolicited full authorization prompt and schedules no default-off category.
4. Existing enabled/disabled choices survive in-place install and container migration.
5. Pending identifiers are owned by the expected categories; no unknown `atria.*` user-facing request bypasses the catalog.
6. Stable PID and live accepted/durable HR throughout navigation.

For cancellation/delivery, do not alter the user's real notification settings without asking. Prefer a DEBUG-only isolated center seam or fixture that demonstrates:

- disabling one category removes only that category's pending identifiers;
- master off removes all known user-facing Atria pending identifiers;
- delivered history, `atria.diagnostic.delivery`, unknown future identifiers, and unrelated requests remain;
- re-enabling does not resurrect an already-cancelled stale request;
- one permitted test event has exact copy, sound/quiet state, deep link, and event-key dedup.

### Regression tests to re-run

- Every scheduler kind maps to exactly one category/toggle/description.
- Unknown user-facing kind fails closed; `diagnostic` remains explicit.
- All four new categories decode/default false across an old settings payload.
- No full authorization request on migration/launch.
- Explicit master/category enable is the only permission-escalation path.
- Category off cancels only its identifiers/prefixes.
- Master off cancels every Atria user-facing pending identifier.
- Same event key schedules at most once across concurrent/replayed passes.
- Resolved second-sleep/parked events remove stale pending requests.
- Bedtime schedule is learned-only, once per target day, and quiet.
- Catch-up completion requires a >=4-hour recorded span and a current frontier.
- Existing notification deep-link, attempt-store, sleep-review debounce, attention-budget, and quiet-hours suites remain green.

Close #36 only after the physical settings/control evidence is attached. The source integration and push alone are already complete and are not sufficient closure.

## Checkpoint 4 (P1): keep relative-skin blockers visible

The numeric authority is correct. Change only presentation.

`AtriaRelativeSkinSignalPresentation.content(for:)` currently renders only:

- `.buildingBaseline`
- fully qualified numeric raw delta

Every other blocker returns `nil`, so the entire row disappears. The validated `Skin temp -- · Decoder not verified` row is useful but does not tell the user whether the experimental personal baseline exists or why it cannot begin.

Render the separate experimental row whenever the strap model exposes the existing skin-signal surface. Use blocker-specific, nonnumeric copy:

| Blocker | Headline | Detail |
| --- | --- | --- |
| `.incompleteArchive` | `Waiting for complete strap history` | `Relative skin signal · Experimental · no value yet` |
| `.noCurrentConfirmedMainSleep` | `Needs a confirmed main sleep` | `Relative skin signal · Experimental` |
| `.noCurrentRawEvidence` | `No usable skin signal for this sleep` | `Experimental · uncalibrated` |
| `.unknownSensorAuthority` | `Sensor identity could not be verified` | `No relative value published` |
| `.mixedSensorAuthority` | `Mixed sensor history` | `No relative value published` |
| `.insufficientRows` | `Not enough skin samples for this sleep` | `Experimental · no value yet` |
| `.insufficientCoveredMinutes` | `Not enough covered sleep time` | `Relative skin signal · Experimental` |
| `.insufficientCoverage` | `Nightly skin coverage is too sparse` | `Experimental · no value yet` |
| `.buildingBaseline` | Existing `Building personal baseline · N of 7 nights` | Existing experimental label |
| `.staleEvidence` | `Sleep evidence changed` | `Recalculating relative skin signal` |
| qualified | Existing signed raw-unit delta | Existing uncalibrated/stillness disclosure |

Use the actual enum cases present in `AtriaRelativeSkinSignalBlocker`; do not invent a new blocker if an existing case already represents the condition.

Rules:

- The validated row remains `Skin temp -- · Decoder not verified` until the external-reference decoder issue passes.
- No numeric raw delta for any blocker.
- No °C/°F, “temperature changed,” fever, illness, recovery, readiness, strain, or coaching claim.
- No HealthKit/widget/report/export/Live Activity wiring.
- Do not hide the row just because the history gap remains open.
- Existing independently proven nights and baseline counts remain untouched.

Required tests:

- Every blocker maps to visible exact copy and no number/degree symbol.
- Building and qualified content remain unchanged.
- Whole-word honesty scan still forbids medical/recovery claims without false substring matches.
- Vitals renders exactly one experimental row beside the validated skin row.
- Relaunch reseed and blocker transition update the row without broad Home/Vitals invalidation.

Physical acceptance through Mirroring:

- Vitals -> Health Monitor visibly shows both the validated skin card and the experimental relative-skin row.
- Current device truth should be a named blocker/progress state, not a number, because the banner still reports `Strap data gap · history incomplete`.
- SpO₂ remains `--` with its existing unavailable copy.

Keep #31 open: this feature is an uncalibrated relative signal, not a validated temperature decoder.

## Focused validation matrix

Use the `AtriaTests` scheme, parallel testing off, one simulator worker. Run changed-file parse and `git diff --check` before Xcode.

Minimum suites:

```text
AtriaHeartRateWindowIndexTests
AtriaHistoricalArchiveCatalogTests
AtriaHistoricalJSONLRecentScannerTests
AtriaHistoricalAggregateReaderMemoryWindowingTests
AtriaActivitySectionsCacheTests
AtriaSwiftUIPerformanceAuditTests

AtriaBLERecoveryCadenceTests
AtriaBackgroundDrainBacklogTests
AtriaBLELiveContinuityPolicyTests

AtriaNotificationCategoryTests
AtriaEventNotificationPolicyTests
AtriaNotificationAttemptStoreTests
AtriaNotificationDeepLinkTests
AtriaSleepReviewNotificationDebounceTests

AtriaRelativeSkinSignalTests
AtriaRelativeSkinProducerTests
AtriaExperimentalSensorCopyTests
```

Add direct catalog-rotation and notification-cancellation tests if they live in new suites. Prefer behavioral tests to source-string scans.

Use a guarded temporary symlink to `<repo-root>/evidence` only when a selected test genuinely needs the gitignored corpus. Hash a null-delimited manifest before and after, prove equality, and remove the exact symlink with a trap.

After focused green:

1. Full changed-file Swift frontend parse.
2. `git diff --check`.
3. Signed Release device build.
4. Provenance identity bound to exact HEAD and executable hash.
5. In-place install and post-install migration audit before explicit launch.
6. One normal launch, no debug arguments for final health/visual acceptance.

Do not weaken archive/data-authority tests to hit a wall-clock target.

## Computer Use / iPhone Mirroring acceptance

Use the Computer Use plugin with app identifier `com.apple.ScreenContinuity`.

In this session:

- Coordinate tap on the Vitals tab routed successfully after a short delay.
- Accessibility exposed only the Mirroring window controls, so coordinate taps were necessary.
- Scrolling worked with the Mirroring window element (`element_index: 0`) and a downward scroll action.

Always fetch fresh state after each action. If a tap appears not to route, wait for the next state before retrying. Do not declare the whole device blocked after one missed synthetic tap.

Final visual/physical checklist:

1. Home: live HR current; banner names history-domain state; no regression to “live HR syncing.”
2. Activity -> Aug 11 -> Heart rate: three cold + three warm terminal timings and receipt pull.
3. Vitals -> Health Monitor: RHR/HRV/respiration truth unchanged; validated skin blank; relative-skin blocker visible; SpO₂ blank.
4. Settings -> notifications: 17 rows, four new categories off, no surprise permission prompt.
5. Observe the 30-minute history window and pull exact productive-receipt/counter evidence.
6. Confirm stable PID, accepted/durable live HR, data container, and no crash/resource/watchdog/jetsam/reconnect/CCCD artifact.

Do not start a workout, force a reconnect, change Bluetooth/radio mode, change system notification preferences, or operate external hardware during this pass. Never open Passwords.

## Commit and push sequence

Prefer three focused commits after the already-shipped notification pair:

1. `Seal smaller history chunks for fast Activity HR reads`
2. `Retry only durably productive history catch-up sooner`
3. `Show relative skin blockers in Vitals`

If Checkpoint 2 cannot prove the durable receipt, omit commit 2 and report the blocker. Do not create a speculative cadence commit.

Do not manufacture a new notification commit merely to touch that subsystem. If physical verification finds a concrete defect, stop, preserve its exact evidence, make the smallest isolated repair, re-run the 91-test notification matrix, and report the additional commit separately.

Author and committer must both be:

```text
adidshaft <adidshaft@gmail.com>
```

No Claude/Codex/AI trailer. Push only as a clean fast-forward from `0bc84fdd` to `origin/dev`. Do not push `claude/notifications-2026-08-13` separately. No TestFlight.

## GitHub issue hygiene

- [#35](https://github.com/adidshaft/atria/issues/35): active-chunk design, threshold/cadence, before/after cold/warm receipts, scan bytes, point equality, rotation overhead. Close only on the physical <=3-second cold pass.
- [#21](https://github.com/adidshaft/atria/issues/21): durable productive-receipt semantics, before/after frontier slope, lag ETA, live-HR/process/connection counters. Keep open for independent whole-day step accuracy.
- [#31](https://github.com/adidshaft/atria/issues/31): visible relative-skin blocker/progress/qualified state. Keep open for validated absolute decoder/reference work.
- [#36](https://github.com/adidshaft/atria/issues/36): source integration/tests/build are already posted. Add migration defaults, settings screenshot, pending identifiers, and delivery/dedup/cancellation evidence. Close only after physical proof.
- [#33](https://github.com/adidshaft/atria/issues/33): add only genuinely new stability evidence from the final soak; do not close unless its own full acceptance is met.

Do not close issues just because a source test passed.

## Final report required from Claude

Return one concise evidence table plus exact artifact paths:

```text
release start/end commit and remote parity
commit list and clean status

Activity HR:
  cold before/after (3 runs)
  warm before/after (3 runs)
  selected/scanned files and bytes
  point count/order/source equality
  active threshold and rotations/hour

History catch-up:
  frontier slope and net lag before/after
  durable productive receipt fields
  raw/accepted/durable HR gaps
  owner/ACK/disconnect/CCCD/PID/resource counters

Notifications:
  integrated commits 61fec3b1 + 0bc84fdd
  category count/defaults
  unknown-kind and toggle-cancel proof
  physical settings/delivery evidence

Relative skin:
  exact visible blocker/progress/value
  baseline count
  confirmation that validated skin + SpO2 remain blank

tests/build/install:
  suite counts and xcresult
  signed executable/provenance hashes
  migration/data-container audit
  screenshots and device evidence paths
```

Explicitly confirm that the dirty main checkout, raw evidence corpus, live HR/journal authority, ACK/prefix retirement, R10/IMU logic, sleep stages, sleep records, SpO₂ decoder, validated Celsius path, HealthKit, widgets, ActivityKit, and TestFlight were untouched except where this handoff explicitly authorizes a read-only acceptance check.
