# CODEX HANDOFF — 2026-07-18 · DETECTION & TRUTH phase

Continuation handoff for Atria. The transport/HR-reliability phase
(`docs/CODEX_HANDOFF_2026-07-18.md`) is COMPLETE and verified. This document
opens the next phase: restore automatic detection so every number shown is real
or honestly absent — never hardcoded, never fabricated. Written from a
device-evidence audit (pull `logs/live-device/detection-audit-20260718T*/`).
Read it fully before editing. Intended to run as autonomous OVERNIGHT night runs
(see §7 discipline: pull-only, NO device installs while the user sleeps).

## 0. State fingerprint

- Repo `/Users/amanpandey/projects/atria`, branch
  `codex/atria-reliability-widget-steps`. Installed device build: signed Release,
  source `ba6020c8388ee222f0a6c9897aab4eb58ba4192f`, executable SHA-256
  `b37170cea73dedf396a473ccbc29a9729f2a1af7760e3793ffcac7293d689bc8`. Developer
  mode is durable until 2026-07-25 00:57 IST.
- Device iPhone 15 Pro `3803F5B6-1666-56D3-A71A-62F131F6CE3B`, bundle
  `com.adidshaft.atria`. Sim iPhone 17 Pro
  `03074F5D-1E2D-4FBF-89E7-94B153C80A33` (fresh-boot before xcodebuild).
- THIS MACHINE EXTERNALLY KILLS long background xcodebuild runs — run tests in
  small foreground batches with a timeout, grep the full stream for
  `** TEST SUCCEEDED **`; never trust a piped exit code.
- Dirty worktree = the parallel healthspan/fitness-age session's UNCOMMITTED
  edits (AtriaFitnessAge.swift, AtriaHealthScreen.swift,
  AtriaHealthspanDetailView.swift, a small display-only hunk in Sessions.swift,
  healthspan test files, AtriaTempEarlyEstimateRenderTests.swift,
  test_handoff_static_checks.py). PRESERVE all of it. Never reset/checkout/revert/
  stash/rewrite files you did not change.

## 1. Proven working this cycle — DO NOT regress

- Durable developer mode (survives an arg-less relaunch; 7-day expiry; explicit
  exit). Commit `c515b693`.
- HR-first, per-epoch bounded dense bring-up with `connectedAt` guards and
  reconnect convergence. Commit `566a6c24`. Desk-proven during a Yoga workout
  (evidence `logs/live-device/desk-p0b-explicit-workout-forced-reconnect-20260717T192831Z`):
  boundary preserved, BT off/on, 2A37 HR restored+accepted FIRST, CRC-valid
  dense R10 through bounded reconnect.
- Exact workout-start journal ownership (unchanged, still verified).
- Confirmed-sleep persistence into daily history (commit `dd100bca`) — this
  persists sleep that is CONFIRMED; it does not fix detection (see §3).
- Residual, honestly NOT claimed fixed: the strap still has short natural
  transport drops after dense activation; recovery is HR-first + per-epoch
  re-establish, not a claim the hardware link is stable.

## 2. Evidence from the detection-audit pull (all IST)

Daily rollups (`daily-rollups.json`) — recovery/sleep/HRV persist through
07-14 then STOP:

| day | recovery | sleepSec | lnRMSSD | rhr | strain |
|---|---|---|---|---|---|
| 07-13 | 69 | 28114 | 4.159 | 52 | 6.3 |
| 07-14 | 66 | 28080 | 4.007 | 55 | 7.9 |
| 07-15 | None | None | None | 58 | 7.3 |
| 07-16 | None | None | None | 66 | 8.1 |
| 07-17 | None | None | 4.143 | 61 | 4.1 |
| 07-18 | None | None | None | 81 | 0.9 |

- `atria.confirmedSleeps.v1`: 7 entries, newest **07-14 03:50→11:38**. NONE for
  07-15/16/17/18.
- `atria.detections.ring.v1` (revision **3417** — the engine is ALIVE) records
  why recent sleep candidates were skipped:
  `"Trimmed wake-boundary candidate did not clear the strong-confirm gates"`,
  `"N candidate(s), all already saved or overlapping"`,
  `"Before the learned/fallback wake boundary"`, `"No sleep candidates found"`.
- `atria.notification.sleepEvent.lastDay = 2026-07-10`; the user has entries in
  `atria.sleepReview.dismissedWindows.v1`.
- Workout detection is ALIVE: `atria.confirmedWorkouts.v1` has 29 entries incl.
  **07-17 23:21 Strength p95HR=160** (the shoulder workout WAS detected) — but
  `observedDuration=882s` of ~4380 real seconds because HR was dead 56 min (the
  now-fixed P0b hole); `reason` fields (`stream_gaps`, `hr_below_threshold`,
  `duration_below_10m`, `no_strap_hr_samples`) are quality annotations, NOT
  rejections.
- Steps: ledger stays `research_unvalidated` (correct; needs the treadmill
  session). Not in scope to "fix" here.

## 3. Root cause — one failure, whole cascade

Automatic **sleep confirmation stopped after 07-14**. The wake-boundary
finalizer `commitPreparedWakeBoundarySleepIfUseful` (Sessions.swift:16206) and
its upstream candidate/anchor logic reject recent nights with blockers
`no_night_anchor` ("No overnight-started session found for the wake-boundary
check"), `tail_not_awake`, and the default strong-confirm-gate failure
(Sessions.swift:16220–16240; the closed-candidate "all already saved or
overlapping" path is ~15873). This approach landed in `29e804c4` ("Accuracy
wave 2: wake-boundary sleep finalize") — likely the regression relative to the
pre-07-14 behavior. The overnight transport churn of 07-15…17 fragmented each
night into many short sessions, so there is no single "overnight-started"
anchor session and the strong-confirm gates never clear — even though the user
demonstrably slept.

Cascade (this is the user's ENTIRE complaint list, one cause):

```
sleep NOT confirmed
  → AtriaPhysiologicalCycle can't anchor the day on sleep (falls to
    noSleepFallback / civil)                → "day not starting/ending on sleep"
  → recovery is gated on sleep evidence     → recovery shows None / stuck
    (the sleep-missing recovery path needs BOTH trusted baselines, and the
     HRV baseline is not trusted, so no recovery is produced)
  → no overnight window                      → HRV sample rarely qualifies
    → HRV baseline stuck 1/14 (RHR is 9/14)  → recovery confidence never leaves
      "unverified/provisional"
```

Workout/activity detection is largely working; its visible weakness this cycle
was the HR hole (fixed) and possibly surfacing/confidence presentation.

## 4. Priorities (all under the honesty rules of §8 — RESTORE detection on real
data; NEVER relax a gate in a way that fabricates a night, a workout, or a metric)

- **P0 — Restore sleep detection/confirmation for real, churn-fragmented nights.**
  Make the wake-boundary + anchor logic tolerant of a night split across
  multiple sessions by reconnect churn: find the overnight anchor across a
  fragmented set (not a single "overnight-started" session), and let a genuine
  night clear confirmation without requiring perfect continuity. Distinguish
  "real night with gappy transport" (confirm) from "no sleep evidence"
  (skip) — the discriminator must be physiological (sustained low HR + low
  motion across the window), never a wall-clock assumption. Verify
  `buildAutoConfirmedSleep` actually fires for such nights. Ensure a user-facing
  confirm/add-sleep fallback exists and reaches the user for a night the
  auto-gate legitimately can't clear (the review flow from `a82073e`;
  `AtriaManualSleepSheet.swift`), so a rejected-but-real night is recoverable
  without fabrication. CRITICAL VERIFICATION: the detection engine recomputes
  over history, so after the fix the stored 07-15…18 all-day sessions should
  re-confirm those nights from data already on device — prove it on the pull,
  do not just unit-test.
- **P1 — Sleep-anchored day boundary.** With sleep confirmed, verify
  `AtriaPhysiologicalCycle.current(...)` re-derives wake-to-wake `boundaryKind
  == .mainSleep` for recent days and that Home/rollups/notifications all read
  the same boundary. No civil/noSleepFallback when a real sleep exists.
- **P2 — Recovery + HRV maturation.** With sleep back, verify recovery
  populates for those days and that the overnight HRV qualification keys off the
  confirmed sleep window (Insights.swift `PersonalBaseline`,
  `freshHRVSampleCount`/distinct-day counting, `overnightHRVPreferenceMinimum`).
  Report the user's ACTUAL distinct-day RHR/HRV counts and the honest ETA to
  `.personalBaseline`/`.validated`. Never relax a trust gate to make a number
  appear — if HRV genuinely needs more nights, say so, and make sure the fixed
  sleep detection is what unblocks the accrual.
- **P3 — Workout/activity detection surfacing.** Verify detected workouts (e.g.
  the 07-17 Strength) surface in the detected-activity review UI
  (`AtriaHistorySection`, the `a82073e` multi-candidate flow) with honest,
  legible confidence and reversible dismissal, and that HR-covered detections
  going forward (now that the HR hole is fixed) are complete. Do not fabricate a
  workout with no HR evidence (`no_strap_hr_samples` stays honestly excluded).
- **P4 — No-hardcoding truth audit.** Sweep the sleep/recovery/strain/steps
  DISPLAY paths for any placeholder, fixed fallback, or fixture value that could
  render as if real (default sleep hours, a constant recovery %, seeded-fixture
  leakage). Every surface must show a real value or an honest learning/absent
  state. Report each finding with file:line; fix or gate each.

## 5. Required deterministic tests (plus keep ALL existing suites green)

- Wake-boundary/anchor: a fragmented overnight (N short sessions from reconnect
  churn spanning a real sleep) CONFIRMS; a genuinely sleepless window does NOT;
  the "no_night_anchor" blocker no longer fires when the night exists but is
  split.
- Day boundary: with a confirmed sleep, `boundaryKind == .mainSleep` and the day
  spans wake-to-wake; with none, the documented fallback — pinned either way.
- Recovery: a day with confirmed sleep + qualifying HRV yields a recovery
  number; the honesty tiers are unchanged; no fabricated recovery without
  evidence.
- HRV qualification: an overnight HRV sample inside a confirmed sleep window
  increments the distinct-day count; outside one, it does not spuriously.
- Truth audit: a regression test for any hardcoded value P4 removes.

## 6. Gates (unchanged discipline)

Focused suites → FULL AtriaTests (fresh-boot sim; small batches) →
`python3 test_handoff_static_checks.py` ends OK → `git diff --check` → signed
Release build + `codesign --verify`. Commit per-defect after unit/static gates.
Pushing the feature branch is allowed; DO NOT merge to main. Migrate any pinned
source snippets in the same commit with a dated comment.

## 7. NIGHT-RUN DISCIPLINE (this phase runs while the user sleeps)

- **PULL-ONLY on the device. NO installs, launches, or terminates overnight** —
  the user is wearing the strap and generating the very sleep data we need; an
  install/relaunch would break tonight's capture and destroy the evidence.
- Do all verification in code + unit/static + the simulator + copy-only pulls.
- In the MORNING (or when the user is up and confirms), take a fresh copy-only
  pull and prove the fix on that night's REAL data: did last night confirm as
  sleep? did the day anchor on it? did recovery populate? Report it plainly.
- If a change genuinely requires a device install to verify, STOP and stage it
  for the user with the exact reason — do not install autonomously overnight.

## 8. Non-negotiable honesty rules (verbatim carry-over)

Never invent sleep, steps, strain, calories, SpO2, skin temperature, offline
history, or recovery. Restore detection on REAL data only; a rescued gate must
confirm a genuine night, never manufacture one. Never infer missing stage
boundaries from motion peaks; never fit from unscoreable coverage; the
2026-07-15 and 2026-07-17 walking windows stay FAILED forever. Keep SpO2 /
skin-temp / proprietary realtime-RR / historical-metric-layout gates hard-off
(`validatedMetricLayoutVersions` empty;
`AtriaStrapStepResearch.validatedDecoderAvailable` false until the fitter
promotion contract passes). Preserve failed evidence and report it as failed.
UI/status claims must be honest and aged. Report the honest baseline ETA rather
than relaxing a trust gate.

## 9. Command crib

```sh
# Copy-only pull (the ONLY device action allowed overnight)
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  ./pull_atria_state.sh --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --evidence-dir logs/live-device/<label>-$(date -u +%Y%m%dT%H%M%SZ)

# Inspect detection state in a pull
#   preferences.plist keys: atria.confirmedSleeps.v1, atria.confirmedWorkouts.v1,
#   atria.detections.ring.v1, atria.detections.revision, atria.sleepReview.*
#   daily-rollups.json: per-day recovery / sleepSeconds / lnRMSSD / rhr / strain

# Tests (fresh-boot sim; small batches; grep for the success marker)
xcrun simctl shutdown 03074F5D-1E2D-4FBF-89E7-94B153C80A33; sleep 3
xcrun simctl boot 03074F5D-1E2D-4FBF-89E7-94B153C80A33; sleep 8
xcodebuild test -project Atria/Atria.xcodeproj -scheme AtriaTests \
  -destination 'id=03074F5D-1E2D-4FBF-89E7-94B153C80A33' \
  -derivedDataPath /tmp/atria-dd [-only-testing:AtriaTests/<Suite>]
python3 test_handoff_static_checks.py   # must end OK
```

## 10. Key code anchors (grep-stable)

- Sleep detection / wake boundary: `commitPreparedWakeBoundarySleepIfUseful`,
  `buildAutoConfirmedSleep`, `ForegroundSleepSettlementProposal` (Sessions.swift
  ~15800–16260); blocker strings quoted in §2.
- Sleep files: `AtriaCycleTracking.swift`, `AtriaSleepPlanner.swift`,
  `AtriaSleepWakeResearch.swift`, `AtriaManualSleepSheet.swift`,
  `AtriaDetectionLog.swift`.
- Day boundary: `AtriaPhysiologicalCycle` (search `boundaryKind`, `.mainSleep`,
  `.noSleepFallback`).
- Recovery/baseline: `AtriaAnalytics.Recovery.estimate` (AtriaAnalytics.swift),
  `PersonalBaseline` (Insights.swift, `trustedMinimumSamples=14`).
- Detected-activity review UI: `AtriaHistorySection.swift`, commit `a82073e4`.
- Suspected regression to study first: `29e804c4` (Accuracy wave 2 —
  wake-boundary finalize). Compare its gate against the pre-07-14 confirm path.

STOP after P0–P4 are implemented, gated, and morning-pull-verified on real data,
with an honest report of what confirmed, what remains genuinely evidence-limited
(HRV baseline days), and anything you could only characterize. Gym calibration
and physical step qualification remain separately user-pending.
