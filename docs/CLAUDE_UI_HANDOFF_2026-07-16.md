# Atria UI / Consistency Handoff — 2026-07-16

For the next Claude loop. Transport reliability is DONE and committed
(`a9093c7`, local); this handoff covers what is NOT implemented yet, with a
UI/consistency focus, plus the screen inventory for design work.

## Binding context
- Design system: TWO card systems and Radius/Spacing tokens exist
  (`AtriaDesignTokens.swift`); Liquid Glass is deliberately subtle. Check the
  design-system memory/docs before restyling anything.
- Honesty rules apply to UI copy: no invented metrics, aged/qualified claims
  only (e.g. "Live · 3 s ago", never a fresh-looking stale value).
- Codex previously iterated on: workout activity-selector UI, Dynamic
  Island/home safe-area layout, share-card layout, generated share
  backgrounds. Diff those areas before editing; two widget-layout test scans
  currently fail against its WIP
  (`testLiveActivityMetricsStaySingleLineWithThreeDigitHeartRate`,
  `testLiveWorkoutHeartRateNeverWrapsAcrossAppAccessoryAndLockScreen`).

## Known UI defects (user-reported, unfixed)
1. **Lock-screen Live Activity is cropped** — metrics truncated on the
   notification-bar presentation; not all info legible. Owner: widget target
   (`AtriaWidget/AtriaWidget.swift`, `AtriaLiveActivityLockScreenView`).
2. **Start-workout perceived latency (4–5 s)** — user asks: if the wait can't
   shrink, add motion/haptic feedback ("something creative") between the
   Start tap and the live screen. A start-confirmation haptic can reuse the
   zone-haptics path (`configureWorkoutZoneHaptics` / `runHapticsPattern` is
   the sole permitted strap write); visual treatment is open design work.
3. **Lock-screen End button lag** — End from the Live Activity works but the
   presentation stays "running" long after; needs a forced content update on
   the terminal transition (`AtriaLiveActivityCoordinator.swift`).
4. **Dynamic Island creative space** — user invites bolder use of the area
   around the island during workouts.

## Detected-workout review flow (user-demanded, 2026-07-17)
CORRECTED after code reading — the machinery is stronger than first
described. `makeWorkoutReviewCandidateForCache` (Sessions.swift ~12600)
already recomputes the review candidate deterministically from saved journal
sessions over a 24 h horizon (`workoutReviewStaleAfter`), excluding
confirmed (`atria.confirmedWorkouts.v1` — that store holds CONFIRMED
workouts with quality annotations, NOT rejected candidates) and dismissed
windows. The 2026-07-16 "vanished" prompt was the transport collapse
starving the window of HR samples (fixed at the transport layer), not an
expiry bug. What is actually missing:
1. SINGLE-candidate ceiling: only `bestSource` surfaces. A day with two
   unconfirmed efforts (e.g. morning run + evening gym) can only ever offer
   one. Needs a small variant returning all qualifying windows, and a
   "Detected activities" list row in history feeding the existing review
   sheet (`AtriaWorkoutReviewDraft` in AtriaHomeView.swift).
2. Dismissal is irreversible and invisible: `dismissedWorkoutCandidates`
   has no UI to view/undo. An accidental swipe permanently buries a workout.
3. Discoverability: the candidate renders only on the Home surface; nothing
   in history hints an unconfirmed detection exists.
- Honesty rules for any UI: HR-only windows are "activity candidates", never
  "Workout found" (see the comment block at Sessions.swift ~12643); no
  synthesized strain/calories for windows without evidence.

## Not yet implemented (product scope)
- Step counts in production UI: blocked on the guided calibration + fitter
  gates (see goal file). UI must keep research labels until a tuple passes.
- Missing-range recovery surfacing: `atria.workoutMotion.backfillReason`
  records honest unrecovered gaps; no UI shows them yet.
- Start-boundary/lease telemetry has no user-facing status ("motion live /
  reconnecting / gap") on the live workout screen — worth a subtle indicator.

## Screen-by-screen inventory (source-derived)
| Screen / surface | Source | Notes for design |
|---|---|---|
| Home shell + tabs | `AtriaHomeView.swift`, `AtriaHomeShellSupport.swift`, `AtriaHomeLayoutConfig.swift` | Root nav, tab accessory during live workout |
| Today screen | `AtriaTodayScreen.swift` | Primary daily dashboard; hours-first sleep, essentials visible |
| Overview sections | `AtriaOverviewSections.swift`, `AtriaHeroConnectionSections.swift` | Hero + connection status cards |
| Live workout | `AtriaLiveWorkoutView.swift` | HR block, strain guidance, pause/end; heavy concurrent WIP |
| Activity list/detail (sessions) | `Sessions.swift`, `AtriaHistorySection.swift` | Saved workouts, edit/relabel flows |
| Workout share card | `AtriaShareCard.swift`, `AtriaRingShare.swift` | Route map, stat tiles, GPX share |
| Insights | `Insights.swift`, `AtriaHighlights.swift`, `AtriaExpandedChart.swift` | Charts, trends |
| Health screen | `AtriaHealthScreen.swift`, `AtriaHealthspanDetailView.swift`, `AtriaFitnessAge.swift` | Longevity metrics |
| Journal | `AtriaJournalTab.swift`, `AtriaJournalInsights.swift` | Behaviors, deep link target |
| Plan tab | `AtriaPlanTab.swift` | Programs/targets |
| Sleep | `AtriaManualSleepSheet.swift`, sleep sections in Sessions | Manual save, review |
| Breathwork | `AtriaBreathworkSession.swift` | Guided session UI |
| AI coach | `AtriaAICoach.swift`, `AtriaAICoachCard.swift`, `AtriaAssistantScreen.swift` | Card + full screen |
| Leaderboard / FaceOff | `AtriaLeaderboardScreen.swift`, `AtriaFaceOff.swift` | Social surfaces |
| Onboarding | `AtriaOnboardingFlow.swift` | First-run |
| Settings | `AtriaSettingsView.swift`, `AtriaCustomizeSheet.swift` | Includes developer/calibration cards |
| Cycle / nutrition context | `AtriaCycleTracking.swift`, `AtriaNutritionContext.swift` | Secondary inputs |
| Widgets + Live Activity + Island | `AtriaWidget/AtriaWidget.swift`, `AtriaLiveActivityAttributes.swift`, `WidgetSnapshot.swift` | CROPPING BUGS HERE; compact/expanded island, lock screen |
| Lock-screen controls | `AtriaShared/AtriaLiveWorkoutControlIntent.swift`, `AtriaWidget/AtriaControlIntents.swift` | Start/pause/end intents |
| Monthly report | `AtriaMonthlyReport.swift` | Periodic summary |

## Verification for any UI change
Focused suite + `python3 test_handoff_static_checks.py` (365+ checks include
copy/consistency rules), `git diff --check`, then the sim fixture screenshot
loop from the verification-protocols memory. Never claim a visual fix without
a screenshot.
