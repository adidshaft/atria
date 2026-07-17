# CODEX HANDOFF — 2026-07-18 (covers the evening of 2026-07-17)

Authoritative continuation handoff for the Atria strap reliability + metrics-honesty
line of work. Written after the failed gym calibration attempt on the evening of
2026-07-17. Every claim below is tied to pulled device evidence or committed code;
nothing is inferred from memory alone. Read this document fully before editing.

## 0. State fingerprint

- Repo: `/Users/amanpandey/projects/atria`, branch `codex/atria-reliability-widget-steps`
  (pushed; tip at the time of writing `038f9cf8`). `main` carries merge `a269036c`
  (all branch work over remote PR #20). Full 12-suite `AtriaTests` pass and all 180
  static checks were green at `038f9cf8`.
- Installed device build: signed Release, binary SHA-256 `82029ffbe152…`, source
  commit `038f9cf8`, team JP4HU7X6G7. Installed 2026-07-17 ~21:13 IST. This build
  contains the evening's six commits (`2d0fbca2` calibration card redesign,
  `49e6dbe8` BG link audit, `30c64318` honesty hardening, `03e8f20a` partial-day
  wear disclosure, `b949f927` widget strain clock gate, `038f9cf8` suite repair).
- Physical device: iPhone 15 Pro, devicectl/CoreDevice ID
  `3803F5B6-1666-56D3-A71A-62F131F6CE3B`. Bundle `com.adidshaft.atria`.
- Simulator for tests: iPhone 17 Pro `03074F5D-1E2D-4FBF-89E7-94B153C80A33`.
  It hangs xcodebuild unless freshly booted (`simctl shutdown` + `boot` first), and
  THIS MACHINE EXTERNALLY KILLS long background xcodebuild runs — run test batches
  foreground-with-timeout or in small suites, and grep the full stream for
  `** TEST SUCCEEDED **` rather than trusting a piped exit code.
- The worktree may contain uncommitted healthspan/fitness-age edits
  (`AtriaFitnessAge.swift`, `AtriaHealthScreen.swift`, `AtriaHealthspanDetailView.swift`,
  `Sessions.swift`, three test files, `AtriaTempEarlyEstimateRenderTests.swift`,
  `test_handoff_static_checks.py`). Those belong to the parallel Codex healthspan
  session. Finish or commit them deliberately; never reset/checkout them away.

## 1. Proven working — do not regress

1. **Exact workout-start journal ownership** — physically verified in production
   this evening: the pre-workout all-day segment was sealed at 21:58:41 and the
   workout owned samples from 21:58:42 (see §2 session table). The July-15
   F799A190 relabel-corruption class is fixed. Guard rails live in
   `commitWorkoutStartSessionBoundary`, `workoutCheckpointLabel`,
   `checkpointCurrentSession(notBefore:)` (AtriaBLEManager) and are pinned by
   tests in `AtriaWorkoutSaveDurabilityTests`.
2. **Dense R10 transport on a fresh, lease-armed connection** — 100% coverage,
   0 breaks on the 2026-07-16 scoreable window (1784146005–1784146230); dense
   `markLive dense=15-16` all afternoon 2026-07-17. The per-connection full
   bring-up is armed by `workoutMotionLeaseProfileArmed` in `didConnect`.
3. **Gyro-cadence research pedometer** (`AtriaGyroCadenceResearchPedometer`,
   AtriaR10Motion.swift) — LOO mean 3.2% on the shuttle card corpus; passes the
   two-family fitter's training gates in-sample. Research-only; promotion is
   blocked exclusively on an independent counted-walk holdout. The all-day
   research shadow (`gyroCadenceResearchSteps` journal fields, commit `590a9ba7`)
   is live and must never become user-facing without promotion.
4. **Honesty surfaces** — strain confidence discloses `partial-day wear` below
   50% day coverage; the widget withholds its strain clock without credible rest
   evidence; legacy ungated recovery paths are deprecated; production step tuple
   remains `filter 8 / peak 29 / sensitivity 0.06 / confirmation 6 / gain 1.11`
   and the step ledger stays `research_unvalidated`.

## 2. Immutable evidence from the failed 2026-07-17 evening session

Pull (copy-only, immediate): `logs/live-device/postgym-immediate-20260717T*/`
with `USER_GROUND_TRUTH.txt` inside. Strap battery 46%. Never delete or rewrite
these; they stay failed evidence even after fixes land.

User's physical ground truth (self-reported, recorded in the pull):
- Walking workout **21:58–22:06 IST**, route `1784305722-1784306182-live_workout_window`
  (route JSON in the pull's `authoritative-runtime-state/atria-workout-routes/`).
  Inside it: 60 s stand → 100 slow → 100 normal → 100 brisk → 200 normal → 60 s
  stand = **500 counted steps**. No per-stage manifest exists (dev card was
  unavailable, §3-D1), so this window is a whole-window diagnostic ONLY — never
  stage-fit material.
- Shoulder workout (hard) **~22:07–23:20 IST**, then home.

Saved HR sessions around the window (from `sessions.json` in the pull; Foundation
epochs, IST rendered):

| start | end | label | samples | counters |
|---|---|---|---|---|
| 21:53:36 | 21:58:41 | All-day wear | 318 | raw=318 accepted=318 zero=0 gaps=0 |
| 21:58:42 | 22:35:41 | All-day wear | 2310 | raw=2310 accepted=2310 zero=0 gaps=0, maxAcceptedGap=0 |
| — 56-minute hole — | | | | **no session at all 22:35:41→23:31:24** |
| 23:31:24 | 23:34:45 | All-day wear | 210 | (post-return) |

Motion lease trace (`atria.workoutMotion.evaluationTrace` in the pull's
`preferences.plist`) for the walking window:

```
t=1784305741 action=none conn=1 connAt=1784305415 s5flag=0 s5proven=0 hr=1 lastFrame=0 dense=0 attemptConn=1784235652 reason=workout_start
t=1784306202 action=none conn=1 connAt=1784305415 s5flag=0 s5proven=0 hr=1 lastFrame=0 dense=0 attemptConn=1784235652 reason=all_day_post_lease_release
```

Strict replay of the walking window (tool build line in §8):

```
/tmp/replay_step_calibration <pull>/atria-step-calibration 1784305722000 1784306182000 500
→ archive_rows=0 decoded_unique_frames=0/460 coverage_pct=0.0 evidence_scoreable=0
```

(Zero archive rows is partly expected — the calibration ARCHIVE only records
while the card's capture lease is armed, and the card was unreachable — but the
trace above independently proves the dense stream itself never started.)

Motion lease persisted state at pull time:
`workoutMotion.firstLiveFrameAt=1784307960` (**22:36:00 IST**),
`lastLiveFrameAt=1784311528` (**23:35:28 IST**),
`backfillReason=r10_range_unrecovered:1784310361-1784310362`, status `live`.

Daily rollups (`daily-rollups.json`): 11 entries spanning **2026-07-06 →
2026-07-16 only**; the newest (07-16) has `recovery=None, sleepSeconds=None,
lnRMSSD=None, rhr=66`. Every entry in the file has `recovery=None` and
`sleepSeconds=None`.

## 3. Root causes — three isolated defects, one systemic gap

### D1 — Developer mode is volatile by design and died on a background relaunch

`AtriaDeveloperMode` (Atria/Atria/AtriaDeveloperMode.swift) is launch-arg-only,
and `isEnabled` actively **deletes** any persisted `atria.developerMode.enabled`
flag when the argument is absent. The app is *designed* to be relaunched by
CoreBluetooth state restoration without launch arguments, so any background
termination (the phone rode to the gym locked) silently strips dev mode. That is
exactly what happened: dev mode was launched at ~21:15, the process was
relaunched en route, and the Settings → Developer section was gone at the gym.

**Required fix**: make dev mode durable-with-honesty. The launch argument writes
a persisted enable with an explicit expiry (suggest 7 days, mirroring the
calibration capture lease) plus a visible "Exit developer mode" row in the
Developer page; `isEnabled` honors argument OR unexpired persisted flag; expiry
or explicit exit clears it. Mind two existing guards when you touch this:
- `AtriaSettingsOnboardingCompactionTests` forbids a **UserDefaults-mutating**
  developer-mode check on the Settings first frame (the current `isEnabled`
  mutates defaults — do not move that mutation into view bodies).
- Static checks pin literal snippets; migrate any moved pins in the same commit
  with a dated comment.

### D2 — The workout motion lease is inert on an already-connected link

The walking workout started at 21:58:42 on a link connected at 21:53:35
(`connAt=1784305415`). Stream-5 was never confirmed on that link
(`s5flag=0 s5proven=0`), and:
- `workoutMotionLeaseAction` returns `.none` whenever `stream5Confirmed` is
  false, and `.none` only records a gap;
- the full proven bring-up (`workoutMotionLeaseProfileArmed` →
  `protectedLaunchPending` → ordered CCCD + 3F/01→6A/01) is armed **only in
  `didConnect`** — no new connection happened after the lease began, so nothing
  ever ran. Result: `dense=0` for the entire workout, 0/460 frames.

**Required fix**: when an active lease evaluates a *connected* link whose
stream-5 is unconfirmed and no dense frames belong to this connection, drive the
proven fresh-link bring-up exactly once per connection epoch. Two candidate
mechanisms — decide with evidence, not preference:
  (a) run the initial-profile subscribe sequence on the existing link (stream-5
      was never enabled this link, so this is a first enable, not a mid-link
      toggle — but the repo's hard rule "no mid-link CCCD on a protected link"
      exists because past attempts caused rapid disconnects; treat this as
      unproven until physically verified);
  (b) one bounded, lease-scoped app-driven reconnect (cancel + connect) so the
      standard `didConnect` bring-up runs on a fresh link — matches the proven
      "link provenance" finding of 2026-07-16 (dense mode only sustains on
      links brought up with the complete launch-style sequence).
Constraints either way: at most one attempt per connection epoch, persisted
attempt accounting (`WorkoutMotionDefaults`), full trace lines, never while the
boundary fence or a save transaction is active, and **standard HR must remain
alive throughout** (see D3 — this is now the twice-burned requirement).

### D3 — The lease-armed reconnect bring-up starves standard HR (NEW, worst)

At 22:35:41 the link dropped mid-shoulder-workout. The reconnect at ~22:36:00
ran the lease-armed full bring-up and dense R10 flowed continuously
(firstLiveFrameAt 22:36:00 → lastLiveFrameAt 23:35:28). But **accepted 2A37 HR
was zero for 56 minutes** (no session, no samples, until 23:31:24 when the user
returned/foregrounded). The prior segment's counters (2310/2310, zero gaps,
zero artifacts) rule out sensor-contact degradation before the cut; a sharp cut
with an instant dense start is a reconnect signature, not a wear problem.

This is the **inverse of July 15** (then: HR alive, motion dead; now: motion
alive, HR dead) and violates the standing requirement "standard HR remains
enabled throughout." Suspected mechanism (verify before fixing): with
`workoutMotionLeaseProfileArmed`, `didConnect` routes discovery strap-service-
first (`protectedLaunchPending`), and the heart-rate service discovery /
2A37 notify re-enable (`heartRateNotificationEnableGate`) never completes on
that path. Falsification steps: read the `didConnect` +
`discoveryServicesForCurrentMode` + `beginProtectedR10LaunchConnectionCutoverIfNeeded`
flow under the armed flag; check whether `heartRateCharacteristic` was ever
rediscovered/subscribed on that link; look for `hr_continuity_watchdog` action
lines 22:36–23:31 in any console/log evidence; reproduce at the desk with a
forced disconnect during an active lease and watch both streams' trace.

**Required fix**: the lease-armed bring-up must subscribe/retain standard HR
(2A37) with the same priority as the motion profile — HR first or interleaved,
never displaced. The HR continuity watchdog must treat "dense alive + HR absent"
as an actionable stall (today its guards may skip when the link looks healthy).
Consequences to also verify after the fix: workout auto-detection for the
22:07–23:20 window was correctly *withheld* (no HR evidence — honest), strain
3.4 was honest-but-starved, and both should recover organically once HR
survives reconnects.

### D4 — Systemic: daily rollups have never persisted recovery/sleep/lnRMSSD

`daily-rollups.json` spans only 07-06→07-16 with `recovery=None`,
`sleepSeconds=None`, `lnRMSSD=None` on **every** entry (rhr populates). This is
the likely common cause behind the user-visible complaints "sleep is
hard-coded / never detected," "recovery shows unverified/provisional forever,"
and frozen-target/attribution oddities: `storedCycleRecovery`,
`sleepHistory`, and HRV-trust displays all read this store. Sleep-shaped
all-day sessions clearly exist (e.g. 02:31–05:31 + 05:31–06:05 on 07-17,
11k+ samples), so evidence is being captured but the rollup/sleep-save pipeline
is not landing it. Investigate: who writes `DailyRollupStoreEntry` (reconcile
path pinned by `AtriaDailyRollupStoreTests`), whether sleep save requires a
user confirmation that never fires (check `confirmedSleeps` in the pull), why
07-17 has no entry at all, and whether the 14-distinct-day HRV/RHR trust
window (`PersonalBaseline.trustedMinimumSamples=14`, `staleAfter=21d`,
Insights.swift) can EVER be satisfied while lnRMSSD is never persisted. Report
the user's actual distinct-day baseline counts and the honest ETA to
`.personalBaseline`/`.validated` — do not quietly relax any trust gate.

## 4. Priorities

- **P0a (D1)** durable developer mode with expiry + explicit exit; migrate pins.
- **P0b (D2+D3 together)** lease bring-up on pre-connected links AND
  HR-preserving bring-up on lease-armed reconnects. These are one subsystem;
  fix and physically verify them as one change with the desk repro
  (forced disconnect + already-connected start) before any gym retry.
- **P1 (D4)** rollup/sleep/recovery persistence investigation and fix.
- **P2** re-verify downstream honesty after P0/P1: auto-detection surfaces the
  next HR-covered strength session; strain reflects HR-covered work; recovery
  confidence progresses as real baseline days accumulate.

## 5. Required deterministic tests (new, beyond keeping all suites green)

- Dev mode: persisted-flag honored across a relaunch WITHOUT the argument;
  expiry clears it; explicit exit clears it; no defaults mutation on the
  Settings first frame; static-check pins migrated.
- Lease policy: connected + lease + stream-5 unconfirmed + no current-connection
  frames → exactly one bring-up per connection epoch (new connection ⇒ one new
  attempt; repeated evaluations/foreground cycles ⇒ none).
- Bring-up ordering: source-scan that the lease-armed `didConnect` path
  subscribes/retains 2A37 (or interleaves it before the motion pair), and that
  no lease path ever disables an active HR subscription (extend the existing
  "never toggle a healthy HR subscription" scans).
- HR watchdog: "dense fresh + accepted HR stale ≥ timeout on a connected link"
  produces an action, not observation.
- Rollups: whatever D4's cause is, pin it with a regression test in
  `AtriaDailyRollupStoreTests` / sleep-save tests.

## 6. Verification gates (unchanged discipline)

1. Focused suites for touched areas, then the FULL `AtriaTests` suite (fresh-boot
   the sim; beware external kills), `python3 test_handoff_static_checks.py`
   (must end OK), `git diff --check`, signed Release build + `codesign --verify`.
2. Desk physical verification for P0b BEFORE any gym session: start a workout on
   an already-connected link (repro of tonight) and force a disconnect mid-
   workout; require current-link standard HR AND dense CRC-valid R10 across
   both events, via trace + a copy-only pull.
3. Install on device only after 1–2 pass. Record binary SHA + source commit.
4. Gym calibration retry only after dev mode is durable AND P0b is desk-proven.
   The treadmill card session remains the promotion arbiter for the step
   families (two-family fitter, counted-walk holdout, zero-step negatives,
   ≥95% per-second coverage, delayed pull ≥1 h after the last window).
5. `tools/verify_physical_qualification.py` remains the completion gate and is
   bound to the installed binary SHA.

## 7. Non-negotiable honesty rules (verbatim carry-over)

- Never infer missing stage boundaries from motion peaks. Never fit from
  incomplete/unscoreable coverage. The 2026-07-15 and 2026-07-17 walking
  windows stay failed diagnostics forever.
- Never invent steps, strain, calories, SpO2, skin temperature, sleep, offline
  history, or recovery. Keep SpO2 / skin-temp / proprietary realtime-RR /
  historical metric layout gates hard-off (`validatedMetricLayoutVersions`
  stays empty; `AtriaStrapStepResearch.validatedDecoderAvailable` stays false
  until the fitter promotion contract passes).
- Preserve failed evidence and report it as failed even after later builds pass.
- Phone motion may remain optional context; it never substitutes for strap
  motion.
- UI/status claims must be honest and aged (existing `workoutMotion` status +
  `r10_range_unrecovered` accounting pattern).

## 8. Command crib sheet

```sh
# Copy-only device pull (non-disruptive; safe while connected)
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  ./pull_atria_state.sh --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --evidence-dir logs/live-device/<label>-$(date -u +%Y%m%dT%H%M%SZ)

# Strict step replay (build once)
swiftc -O tools/replay_step_calibration.swift Atria/Atria/AtriaR10Motion.swift \
  Atria/Atria/FrameParser.swift -o /tmp/replay_step_calibration
/tmp/replay_step_calibration <pull>/atria-step-calibration <start_ms> <end_ms> <expected>

# Two-family fitter (needs manifest + holdout when the day comes)
swiftc -O tools/fit_step_calibration.swift Atria/Atria/AtriaR10Motion.swift \
  Atria/Atria/FrameParser.swift -o /tmp/fit_step_calibration

# Tests (fresh-boot the sim first or xcodebuild hangs)
xcrun simctl shutdown 03074F5D-1E2D-4FBF-89E7-94B153C80A33; sleep 3
xcrun simctl boot 03074F5D-1E2D-4FBF-89E7-94B153C80A33; sleep 8
xcodebuild test -project Atria/Atria.xcodeproj -scheme AtriaTests \
  -destination 'id=03074F5D-1E2D-4FBF-89E7-94B153C80A33' \
  -derivedDataPath /tmp/atria-dd [-only-testing:AtriaTests/<Suite>]
python3 test_handoff_static_checks.py   # must end OK

# Signed Release build+install+launch (leaves app running)
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  bash live_device_debug.sh --release --seconds 5 --leave-running

# Dev-mode launch — the `--` separator is MANDATORY or args are swallowed
xcrun devicectl device process launch --terminate-existing \
  --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B com.adidshaft.atria \
  -- --atria-developer-mode
```

## 9. Context you should not rediscover the hard way

- Two card systems and two Today-layout systems exist; static checks pin literal
  source snippets (migrate pins in the same commit, dated).
- `simctl` cannot scroll; below-the-fold UI is verified via a TEMPORARY XCTest
  rendering the view through UIHostingController+drawHierarchy to PNG (delete
  the test after reading the screenshot).
- devicectl night screenshots photograph the Always-On Display — never diagnose
  colors from them.
- The connection counters in pulls are cumulative and historically churned;
  never infer a reconnect policy from totals — use the per-window trace.
- July-14 `redp2` diagnostic (motionHandshake keys) is the canonical proof that
  dense+stable requires the complete launch-style bring-up on a fresh link.
- Prior handoffs: `docs/CLAUDE_R10_WORKOUT_HANDOFF_2026-07-15.md` (transport
  spec + gates), `docs/CLAUDE_UI_HANDOFF_2026-07-16.md` (detected-workout
  review, multi-candidate spec), `docs/GYM_CALIBRATION_RUNBOOK_2026-07-15.md`
  (calibration procedure). This document supersedes their "current state"
  sections where they conflict.
