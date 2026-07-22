# CODEX HANDOFF — 2026-07-18 · DETECTION & TRUTH phase

Current continuation handoff for Atria. The superseded transport/HR-reliability
handoff is preserved in Git history; that phase is complete and verified. This
document opens the next phase: restore automatic detection so every number shown is real
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
- Confirmed-sleep persistence into daily history (commit `dd100bca`) — persists
  sleep that is CONFIRMED. NOTE (verified): the same commit also TIGHTENED the
  daily pipeline to trust only confirmed sleep (day→night filter requires
  `$0.confirmed`, Sessions.swift:7612; morning-metric HRV returns nil once any
  sleep was ever confirmed but this day's is not, :7985-7995), and `ba6020c8`
  pinned "no recovery on an unconfirmed day" as the test contract. This is
  honest but fails FULLY CLOSED when upstream confirmation is starved — it is
  part of the cascade, not a clean win (see §3).
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

## 3. Root cause — the whole chain is gated on strap-transport EVIDENCE (verified)

This is NOT primarily a sleep-logic problem to loosen. A full code trace (line
refs verified) shows three INDEPENDENT gates that each require evidence the
unreliable strap transport did not deliver through 07-17:

- **Sleep auto-confirm requires validated dense MOTION.**
  `isStrongAutoConfirmableSleepCandidate` (Sessions.swift:16314) guards on
  `candidate.motionEvidenceValidated` (:16320) — true only when the strap
  delivered validated dense R10. The prior-phase transport non-convergence
  (C1: `s5=0 dense=0` for 42 min on a stable link, 0/460 frames) makes it
  false ⇒ sleep is NEVER auto-confirmed. The high-specificity HR-only tiers
  (`isUnambiguousHROnlyMainSleepCandidate` :16339,
  `isDegradedHROnlyOvernightSleepCandidate` :16363) only feed a REVIEW CARD
  (`isReviewWorthySleepCandidate` :7431) — "never sufficient for automatic
  promotion" (:16356). So a night the strap saw all night via HR is shown for
  review and, unless the user taps confirm, never anchors the day or feeds
  recovery.
- **HRV qualification requires standard-2A37 RR provenance.** `session.localRMSSD`
  (Sessions.swift:454) returns nil unless `hasQualifiedStandardRRProvenance`
  (every RR point sourced from 2A37, :447-449). No standard RR overnight ⇒
  localRMSSD nil ⇒ `baseline.learn(hrv: 0)` ⇒ the day's sample has RHR but no
  lnRMSSD ⇒ `freshHRVSampleCount` (Insights.swift:113) does not count it. That
  is the exact HRV 1/14 vs RHR 9/14 shape (RHR needs no RR). NOTE: HRV baseline
  qualification is time-of-day based (`isOvernightHRVWindow`), NOT confirmed-
  sleep based — it needs qualified RR, not a confirmed sleep. (Per-day recovery
  attribution, separately, DOES require confirmed sleep — see the dd100bca note.)
- **Workout readiness requires contact-qualified HR/RR.**
  `workoutReadiness.ready` (Sessions.swift:4419) needs `contactQualified`
  (RR>0 OR zero accepted-HR gaps, :4406) and `!contactCompromised` (:4415). The
  prior-phase 56-min HR hole (C2) ⇒ the 07-17 shoulder workout produced no
  candidate. Workouts are never auto-counted (only `UserConfirmedWorkout`
  counts, :4487) — "auto-detection" means surfacing a review candidate.

Then `dd100bca` correctly TIGHTENED the daily pipeline to trust only CONFIRMED
sleep (§1 note), so the moment upstream confirmation is starved, recovery/HRV
blank fully closed — honest, but brittle.

Cascade (root → the user's EXACT complaints), all verified:

```
STRAP TRANSPORT not delivering validated motion + standard 2A37 RR (prior C1/C2)
 ├ no validated motion → isStrongAutoConfirmableSleepCandidate=false → sleep NEVER auto-confirmed
 │    ├ cachedConfirmedSleeps empty → AtriaPhysiologicalCycle → .initialFallback 6AM civil
 │    │     → currentPhysiologicalMainSleep=nil        ⇒ "day not starting/ending on sleep"
 │    └ makeMorningFrozenDailyMetric else{nil} (dd100bca) → hrv/recovery nil ⇒ "recovery stuck"
 └ no standard-2A37 RR → session.localRMSSD=nil → baseline sample has RHR, no lnRMSSD
      ├ freshHRVSampleCount 1/14 vs RHR 9/14           ⇒ "HRV stuck / recovery unverified"
      └ workoutReadiness.contactQualified=false        ⇒ "workouts not detected"
```

The prior-phase transport fix (`566a6c24`, HR-first convergent bring-up) targets
the root. The FIRST job of this phase is to VERIFY on real overnight data whether
it now delivers the evidence — because if it does, most of this cascade
self-heals, and the remaining work is the code-level gates that make detection
invisible when evidence is only PARTIAL.

## 4. Priorities (RESTORE detection on real EVIDENCE; NEVER loosen a gate in a way
that fabricates sleep, a workout, or a metric)

- **P0 — VERIFY THE TRANSPORT FIX ON REAL DATA (pull-only, do first).** On the
  morning pull determine whether the `566a6c24` build now delivers, overnight:
  (a) validated dense R10 motion (⇒ `motionEvidenceValidated` true on the night's
  sessions), and (b) standard-2A37 RR provenance (⇒ `session.localRMSSD`
  non-nil). If yes, confirm sleep auto-confirmed, the day anchored on it,
  recovery populated, and an HRV distinct-day accrued. This is the linchpin —
  report it plainly before touching code.
- **P1 — Sleep detection when motion is legitimately down.** If transport now
  delivers evidence, verify `isStrongAutoConfirmableSleepCandidate` /
  `buildAutoConfirmedSleep` fire. If the strap delivers HR but motion is still
  intermittently absent, allow the UNAMBIGUOUS HR-only overnight tier
  (`isUnambiguousHROnlyMainSleepCandidate`, Sessions.swift:16339) to ANCHOR the
  day/recovery — not merely surface a review card — gated to high specificity
  (sustained low HR + low motion across a real overnight window). NEVER
  auto-promote the ambiguous/degraded tier. The discriminator must be
  physiological, never a wall-clock assumption.
- **P2 — Make the HR-only review actually reach the user.** For a night the
  auto-gate legitimately can't clear, ensure the review card / notification
  surfaces (the `a82073e` flow, `AtriaManualSleepSheet.swift`) so the user can
  confirm it. A detected night must never silently vanish.
- **P3 — Historical recoverability, honestly.** Check whether the stored
  07-15…18 sessions actually carry `motionEvidenceValidated` / 2A37 RR. If they
  do, the recompute should re-confirm those nights — prove it on the pull. If
  they DON'T, those nights are honestly UNRECOVERABLE (the evidence was never
  captured); say so and do NOT backfill or fabricate them.
- **P4 — Recovery attribution honesty (the `dd100bca` `else { nil }` branch,
  Sessions.swift:7985-7995).** Only if a day has a clean overnight low-HR wear
  window WITH qualified 2A37 RR but no confirmed sleep should you consider a
  reduced-confidence recovery from it; otherwise keep nil. Re-examine whether
  `ba6020c8`'s pinned "no recovery on an unconfirmed day" contract should stand.
  Do NOT relax this into fabricating recovery from a wear window lacking
  qualified RR.
- **P5 — HRV maturation.** Confirm standard-2A37 RR overnight is what unblocks
  HRV qualification (Insights.swift `PersonalBaseline`, `freshHRVSampleCount`).
  Report the user's ACTUAL distinct-day RHR/HRV counts and the honest ETA to
  `.personalBaseline`/`.validated`. Never relax a trust gate to make a number
  appear.
- **P6 — Workout/activity surfacing.** Verify detected workouts (the 07-17
  Strength) surface in the review UI (`AtriaHistorySection`, `a82073e`) with
  honest, legible confidence and reversible dismissal; HR-covered detections are
  now complete post-transport-fix. Never fabricate a no-HR workout
  (`no_strap_hr_samples` stays honestly excluded).

TRUTH AUDIT (already run — NO fabrication found): every recovery/sleep literal in
the codebase is a `#if DEBUG` fixture unreachable in Release (AtriaTodayScreen
`debugHighlightRollups`, LocalNotificationScheduler debug summaries, the
detected-activities fixture gated by a non-DEBUG `false`); the manual-sleep
sheet's 8h is a user-editable default; steps are honestly labeled unvalidated
estimates (`AtriaStrapStepResearch.validatedDecoderAvailable=false`); "unverified/
provisional" is the honest confidence tier. The user's "sleep is hardcoded" fear
is UNFOUNDED — the values are honestly absent (nil/learning), not faked. Keep it
that way; if you touch display code, re-verify no fixture leaks into Release.

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

- Sleep auto-confirm gate (VERIFIED): `isStrongAutoConfirmableSleepCandidate`
  (Sessions.swift:16314, motion guard :16320); HR-only tiers
  `isUnambiguousHROnlyMainSleepCandidate` (:16339),
  `isDegradedHROnlyOvernightSleepCandidate` (:16363), review-only at :16356;
  `isReviewWorthySleepCandidate` (:7431); scheduler
  `autoConfirmSleepOnForegroundIfUseful` (:15611), `resident_morning_checkpoint`
  (:10770); commit `autoConfirmStrongSleepCandidates` (:15800),
  `buildAutoConfirmedSleep`; `motionEvidenceValidated` set/forced-false at
  :342-343/:10347/:11750.
- HRV/RR provenance (VERIFIED): `session.localRMSSD` (:454),
  `hasQualifiedStandardRRProvenance` (:447-449); `learnBaselineIfEligible`
  (:10568-10604); `PersonalBaseline` (Insights.swift `freshHRVSampleCount` :113,
  `trustedMinimumSamples=14` :19, `isOvernightHRVWindow` Sessions.swift:4557).
- Workout readiness (VERIFIED): `workoutReadiness` (:4380-4470, `ready` :4419,
  `contactQualified` :4406, `contactCompromised` :4415); `detectedActivities`
  (:18975); review UI `AtriaHistorySection.swift:260/862`.
- Day boundary (VERIFIED): `AtriaPhysiologicalCycle.current` (Sessions.swift:113,
  `.initialFallback` 6AM :127-137, `.mainSleep` :146, `.noSleepFallback` :162);
  `currentPhysiologicalMainSleep` (:8535).
- Recovery attribution (VERIFIED): `makeMorningFrozenDailyMetric` (:7942,
  HRV `else{nil}` :7985-7995), day→night filter `$0.confirmed` (:7612).
- Sleep files: `AtriaCycleTracking.swift`, `AtriaSleepPlanner.swift`,
  `AtriaSleepWakeResearch.swift`, `AtriaManualSleepSheet.swift`,
  `AtriaDetectionLog.swift`.
- VERIFIED regressions: `dd100bca` (daily-pipeline confirmed-only tightening +
  `else{nil}` HRV branch — the behavioral change) and `ba6020c8` (test that pins
  "no recovery on an unconfirmed day"). The transport fix `566a6c24` targets the
  upstream cause.

STOP after P0–P6 are implemented, gated, and morning-pull-verified on real data,
with an honest report of what confirmed, what remains genuinely evidence-limited
(HRV baseline days), and anything you could only characterize. Gym calibration
and physical step qualification remain separately user-pending.
