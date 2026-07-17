# Claude handoff — Atria workout R10 continuity, exact save boundary, and step calibration

## Mission

Work only in `/Users/amanpandey/projects/atria` on branch
`codex/atria-reliability-widget-steps`.

Fix the release-blocking Atria strap-motion failure proven by the July 15 physical
Walking workout. This scope is only:

1. continuous CRC-valid R10 motion during an explicit workout, including background,
   foreground, reconnect, and relaunch recovery;
2. exact workout-start/end journal ownership so a pre-workout all-day journal cannot be
   relabelled or saved as the workout;
3. honest step-calibration evidence capture and evaluation after transport is fixed.

Do not work on the workout activity-selector UI, Dynamic Island/home safe-area layout,
share-card layout, or generated share backgrounds. Codex is continuing those separately.
Do not work on another app. Do not introduce CI/CD. Do not commit or push until every
physical gate below passes.

The worktree is intentionally very dirty from the larger Atria goal. Preserve all
existing changes. Never reset, checkout, revert, or rewrite unrelated files.

## User's correct physical workout

The user's screenshot is:

`/var/folders/l9/3shhw7rn0nq9g4f07h5rs50m0000gn/T/codex-clipboard-1d2aa1e0-5e2f-4dd2-8efb-1c98cc1ebfc3.png`

It proves the intended saved activity is Walking, shown as July 15, 2026,
6:37 PM–6:44 PM IST, with a 50 m route, strain 0.2, duration 7 m, average HR 93,
peak HR 109, and calories 35.

The authoritative saved route provides the exact interval:

- start: `2026-07-15T13:07:29Z` = 18:37:29 IST
- end: `2026-07-15T13:14:13Z` = 18:44:13 IST
- route ID: `1784120850-1784121254-live_workout_window`
- route artifact:
  `logs/live-device/guided-calibration-immediate-20260715T132123Z/authoritative-runtime-state/atria-workout-routes/1784120850-1784121254-live_workout_window.json`

The user performed the requested total sequence inside this workout:
rest, 100 slow, 100 normal, 100 brisk, 200 normal, rest. The total expected count is
500 only as a whole-window diagnostic. No guided-stage manifest or exact internal stage
boundaries were recorded, so this workout must never be used to fit slow/normal/brisk
parameters or promoted into a calibration set.

## Immutable failure evidence

Immediate copy-only pull:

`logs/live-device/guided-calibration-immediate-20260715T132123Z`

Preserved reports:

- `saved-live-workout-coverage.txt`
  SHA-256 `8b9a82bb3eb6ff99358982960674ff5161b115d5f349ddd42f4b89d64cb40665`
- `atria-step-calibration.sha256`
  SHA-256 `ef9945584dfa33a8fd09d57ff1368f6882a5c50f9d9e0fad68256c125fab8e3a`

The full copied archive contains 25,040/25,040 CRC-valid rows, zero CRC-invalid rows,
842 duplicate device timestamps, and 24,198 unique frames. Packet bytes and the fixed
R10 decoder are therefore not the immediate failure.

Strict replay of the correct route-backed workout window:

- duration: 404 seconds
- unique R10 frames: 41/404
- acceleration samples: 4,100
- coverage: 10.149%
- continuity breaks: 30
- longest contiguous run: 2 seconds / 0.495%
- maximum missing device-time gap: 23 seconds
- production detector: 0 steps
- evidence scoreable: false
- expected total: 500 only as an unscoreable diagnostic

Reproduce it with:

```sh
swiftc -O tools/replay_step_calibration.swift \
  Atria/Atria/AtriaR10Motion.swift \
  Atria/Atria/FrameParser.swift \
  -o /tmp/replay_step_calibration

/tmp/replay_step_calibration \
  logs/live-device/guided-calibration-immediate-20260715T132123Z/atria-step-calibration \
  1784120849000 1784121253000 500
```

Do not tune the production tuple from this output. Production currently remains
`filter 8 / peak 29 / sensitivity 0.06 g / confirmation 6 / gain 1.11`.

## Separate save-boundary corruption

`sessions.json` incorrectly contains one recent `Live workout` using the older all-day
journal envelope:

- ID `F799A190-1CA8-426A-8174-08E93E580DB9`
- start 17:28:04.979 IST
- end 18:44:13.061 IST
- 4,568.082 seconds
- 712 HR points
- label `Live workout`

The active journal segments with the same ID correctly show that this was an
`All-day wear` journal started at Foundation time `805809484.978906`. At workout save,
the code sliced the visible workout/route to 18:37–18:44, but also changed the full
pre-existing journal envelope into a saved `Live workout`. Fix this transactionally:
the all-day segment before workout start must retain its own label/window, while the
workout owns only samples at or after its persisted exact `startedAt`.

The app must remain correct if workout start happens during an incremental journal save,
if HR/R10 arrives while the boundary is committing, if the app backgrounds immediately,
or if the process relaunches before workout completion.

## Root cause already isolated

The installed build uses the protected minimal standard-HR profile. After the
calibration-triggered reconnect around 17:31 IST, Atria restored the stream-5 notify
subscription but did not restore the dense motion epoch:

- `reassertR10NotificationIfConnected` and
  `requestBoundedR10ActivationForSilentStream` intentionally take no action for an already
  qualified protected-v9 owner (`action=no_mid_link_cccd_or_epoch_reset`);
- `sendProtectedR10ActivationIfReady` also excludes qualified protected v9;
- the R10 watchdog waits about 60 seconds and observes rather than restoring the
  validated motion-start sequence;
- result: HR remains alive and occasional CRC-valid passive R10 frames arrive, but the
  expected dense 1 Hz device-second motion epoch is absent.

Pulled state corroborates this:

- `radio_recorded_runtime_mode=protected_r10_minimal`
- `radio_effective_mode=standard_hr_only`
- `radio_protected_r10_active=0`
- passive R10 subscribed/waiting
- step ledger state `research_unvalidated`, 0 steps
- connection counters were extremely churned, but do not infer a new reconnect policy
  without separating historical cumulative counters from this exact workout.

## Partial edit at handoff

The interrupted implementation added only the unused `WorkoutMotionDefaults` key names
near `AtriaBLEManager.swift:1514`. No functional motion lease, command, boundary, or test
was completed. Treat it as scaffolding that may be kept, changed, or removed. Do not
claim it fixes anything.

## Required implementation properties

1. Give each explicit workout a persisted, exact-start motion ownership lease tied to
   the pending-workout intent and current peripheral connection epoch.
2. On workout start/recovery, allow a short passive grace period. If no fresh dense R10
   epoch appears, issue at most one already-validated motion-start command pair for that
   connection. Reuse the repository's proven command path; do not invent protocol bytes.
3. Do not toggle stream-5 CCCD mid-link, reconnect repeatedly, stop 2A37 HR, read a
   proprietary battery value, start historical sync, or reset an active epoch merely to
   create motion.
4. Persist activation attempt time, connection epoch, first/last live frame, gap start,
   gap status, and release status. UI/status claims must be honest and aged.
5. Restore the lease after background/foreground and CoreBluetooth/process restoration.
   A connection change may receive one new bounded attempt; repeated lifecycle callbacks
   on the same connection may not resend it.
6. Release/cancel the lease on successful workout stop or transactional cancellation.
7. Record missing ranges for later recovery, but do not claim the strap stores arbitrary
   offline R10 or metrics unless the repository's verified history capability proves it.
8. Phone motion may remain optional activity context, but it cannot be required for strap
   steps or used to fabricate missing strap motion.
9. Create an exact session boundary at persisted workout start before the workout can
   relabel or save samples. Preserve FIFO ordering and the existing R10 boundary fence.
10. If exact boundary persistence fails, fail closed and retain the original all-day
    journal; never silently merge it into the workout.

## Required deterministic tests

Add focused tests covering at least:

- qualified-v9 + silent R10 + active workout -> one bounded validated activation;
- fresh dense R10 during grace -> no activation;
- repeat foreground/background on same connection -> no duplicate activation;
- disconnect/new connection during active workout -> one new connection-scoped attempt;
- workout end/cancel -> lease released and tasks cancelled;
- standard HR remains enabled throughout;
- stale sparse passive frames do not mark workout motion live;
- all-day journal is transactionally cut at workout start;
- pre-workout samples keep `All-day wear`, workout samples get `Live workout`/selected
  activity only;
- boundary/save failure cannot relabel the old journal;
- background/relaunch recovery uses the persisted workout `startedAt`;
- raw range-loss/backfill status remains honest and never claims unavailable metric
  history.

Relevant files include:

- `Atria/Atria/AtriaBLEManager.swift`
- `Atria/Atria/AtriaWorkoutRuntime.swift`
- `Atria/Atria/AtriaLiveWorkoutView.swift` (pending intent/store only; coordinate with
  concurrent UI edits before changing presentation code)
- `Atria/Atria/ActiveSessionJournal.swift`
- `Atria/Atria/Sessions.swift`
- `Atria/AtriaTests/AtriaBLERecoveryCadenceTests.swift`
- `Atria/AtriaTests/AtriaWorkoutRuntimeTests.swift`
- `Atria/AtriaTests/AtriaWorkoutSaveDurabilityTests.swift`
- `Atria/AtriaTests/ActiveSessionJournalCacheTests.swift`

## Physical/evidence acceptance gates

Do not call the transport or step engine fixed from unit tests alone.

1. Before installing or changing phone state, make the delayed copy-only pull if it has
   not already been taken. It is valid after 19:44:13 IST on July 15 and should be made
   promptly while the phone remains connected. Compare late R10 coverage with the
   immutable immediate pull. Late frames cannot create missing stage labels.
2. Run focused Swift tests, the complete explicitly serial Swift suite, all Python/static
   checks, Release build, codesign verification, and `git diff --check`.
3. Install the new signed Release only after those pass.
4. Physically verify a foreground/background/reconnect workout with exact route and save
   boundaries. Require current-link standard HR plus dense CRC-valid R10 throughout.
5. Require >=95% per-second R10 coverage, no uncovered boundaries, and no unexplained
   device-time discontinuity for every scored calibration/holdout window.
6. Capture a true guided developer calibration manifest, not an ordinary workout:
   Rest before 0 -> Slow 100 -> Normal 100 -> Brisk 100 -> Normal 200 -> Rest after 0.
7. Pull again at least one hour after the last scored window, then use the strict fitter
   with independent positive and zero-step holdouts. Do not promote any tuple unless all
   calibration, holdout, and negative-control gates pass.
8. Complete the build-bound physical verifier in
   `tools/verify_physical_qualification.py`; it intentionally blocks completion without
   hashed evidence for calibration, holdout, negatives, route/pause/GPX/share/relaunch,
   haptics 1/3/2/1, background recovery, Live Activity, Activity CRUD, journal deep link,
   sleep save, battery/charging/reconnect, and responsiveness.

## Non-negotiable honesty rules

- Never infer missing stage boundaries from motion peaks.
- Never fit from incomplete/unscoreable coverage.
- Never invent steps, strain, calories, SpO2, skin temperature, offline history, or
  recovery.
- Keep production SpO2, skin-temperature, proprietary realtime-RR, and historical metric
  layout gates hard-off until independently validated.
- Preserve the failed evidence and report it as failed even after a later build passes.
- Work only on Atria.
