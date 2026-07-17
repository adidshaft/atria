# WHOOP-parity audit — 2026-07-17

Source-derived inventory of Atria against WHOOP's core function set, with
honest status labels. "Shipped" means implemented on this branch with tests;
it does NOT claim physical validation beyond what the evidence ledger shows.
Gates and honesty rules (no invented metrics, research labels until
validated) are binding and unchanged.

| WHOOP function | Atria status | Source anchor | Gap / next step |
|---|---|---|---|
| Continuous HR (all-day) | Shipped, physically proven | AtriaBLEManager (2A37 journal) | — |
| Strain (workout + daily) | Shipped (evidence-labeled confidence) | Metrics, AtriaWorkoutMetricPresentation | Depends on HR coverage only |
| Recovery score | Shipped (learning-phase honest: "Day 1 of 4") | Insights, Dashboard, AtriaTriRing | Longer baseline accrual |
| HRV | Shipped w/ reference validation path | HRV, healthkit.referenceAudit | Keep independent-reference gating |
| Resting HR + trends | Shipped | AtriaTrendChart, DailyRollupStore | — |
| Sleep tracking + stages | Shipped (manual + auto candidates; hours-first display) | Sessions (SleepStageKind), AtriaManualSleepSheet, AtriaSleepWakeResearch | Stage auto-detection stays research-labeled |
| Sleep planner / budget / wake alarm | Shipped | AtriaSleepBudget, AtriaSleepPlanner, AtriaWakeAlarm | — |
| Respiratory rate | Research only (RR presence machinery) | rrPresence keys, HRV | Hard-off until independently validated |
| SpO2 | Deliberately OFF | validatedMetricLayoutVersions empty | Independent validation required |
| Skin temperature | Deliberately OFF | same gate | Independent validation required |
| Steps (strap-native) | Research-labeled; gyro-cadence family passes training gates (2.17% mean on counted card session) | AtriaR10Motion, AtriaStrapStepLedger, tools/fit_step_calibration | Treadmill card session = counted-walk holdout → promotion decision |
| All-day dense motion | Shipped (battery-governed governor) | AtriaBLEManager d603dd6 | Strap-battery drain observation over days |
| Auto workout detection | Shipped + review flow (multi-candidate, reversible dismissal, history discoverability) | AtriaActivityMonitor, Sessions, AtriaHistorySection a82073e | Four-suite re-run over d0a97ce pending |
| Workout tracking (live, zones, route, GPS) | Shipped, physically proven transport | AtriaLiveWorkoutView, AtriaWorkoutRoute | — |
| Strength trainer / set logging | Shipped (basic) | AtriaStrengthLog, AtriaExerciseCatalog | Depth vs WHOOP's library |
| Stress monitor | Shipped | AtriaStressMonitor, AtriaStressDetailView | — |
| Breathwork | Shipped | AtriaBreathworkSession | — |
| Journal / behaviors + impact | Shipped (39 behaviors, correlations) | AtriaJournalTab, AtriaBehaviorImpact | — |
| Healthspan / fitness age | Shipped | AtriaFitnessAge, AtriaHealthspanDetailView | — |
| AI coach | Shipped (local/cloud modes) | AtriaAICoach, AtriaAssistantScreen | — |
| Weekly / monthly reports | Shipped | AtriaWeeklyReport, AtriaMonthlyReport | — |
| Teams / community | Shipped (leaderboard, FaceOff, sparring) | AtriaLeaderboardScreen, AtriaFaceOff, AtriaSparringScreen | — |
| Cycle tracking (women's insights) | Partial | AtriaCycleTracking | Insight depth |
| Nutrition context | Partial | AtriaNutritionContext | Depth |
| Widgets / Live Activity / Island | Shipped; defect backlog worked 07-16/17 | AtriaWidget, AtriaLiveActivityCoordinator | Sim-only stale-accessory bounds check (see d0a97ce note) |
| Strap offline history sync | NOT claimed | offlineSync keys (unvalidated) | Stays unclaimed until independently validated |
| Battery/wear detection | Shipped (honest aging labels) | battery keys, capacitive wear | — |

## Honest bottom line
Function coverage is broad and real; the deliberate deficits are exactly the
honesty-gated ones (SpO2, skin temp, respiratory rate, offline history,
step-count promotion) — each blocked on independent physical validation,
not on missing code. The single highest-leverage unlock remains the
treadmill card session (step promotion holdout).
