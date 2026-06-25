# Codex Handoff — Beyond WHOOP: performance + 4 flagship features

Date: 2026-06-25
Goal: make Atria do everything WHOOP does and **more**, while staying smooth as the
native app, local-first (no cloud/account/subscription), and honest (no fabricated
physiology — see docs/18). This runs unattended overnight: hold the four operating
principles in docs/18 §"OVERNIGHT OPERATING PRINCIPLES" above all.

Build order is deliberate: **Phase 0 (perf foundation) FIRST**, because every
feature below adds data processing, and the recurring lag comes from heavy compute
on the render path. Don't start a feature until Phase 0's pattern exists.

## Atria's edge over WHOOP (preserve these in every change)
- No subscription, ever; reads the strap the user already owns.
- Data stays on device; exports to Apple Health; no account/cloud.
- User-customizable Today (shipped: `AtriaTodayMetric` + Settings → Today screen).
- Native Liquid Glass on floating chrome/controls; calm surfaces for content.

---

## Phase 0 — Performance / data-processing foundation (do this first)

**Root cause of the lag (confirmed this session):** heavy synchronous work runs
inside SwiftUI view bodies and computed properties, so it re-runs on every render
(BLE tick, tab switch, theme switch). Examples found: `restingTrendValues`
(sort+reduce over all sessions), `DailyEvidenceCard.makeSummary` (sort + per-session
`detectedActivity` + workout/sleep analysis), the IMU/probe reduces in
`AtriaVitalsCollectionSections`. Some were patched (glance `==`, 45-day trend bound,
`drawingGroup` on the glance, deferred tab reconfig), but the pattern must become
systemic.

**The rule:** view bodies must be O(1). All derived metrics are computed ONCE when
their inputs change, off the render path, and read as plain stored values.

1. **Derived-metrics cache.** Add a `DerivedMetricsStore` (ObservableObject) that
   owns precomputed outputs: resting trend series, daily rollups, evidence summary,
   strain/HRV/recovery snapshots, IMU/probe aggregates. Recompute only on
   `store.$sessions` changes (debounced ~250ms) on a background queue, then publish
   the result on the main actor. Views read `derived.restingTrend` etc. — never
   compute in `body`.
2. **Move BLE→metric math off the main actor.** Parsing, artifact filtering, RR/HRV,
   TRIMP/strain, calories already run hot. Ensure the per-sample math runs on the
   BLE queue and only the final published snapshot hops to main. Throttle UI
   publishes (the code already has `throttledCoreLiveChanges` — extend it).
3. **Every list cell `Equatable` with a tight `==`** comparing only displayed
   fields (the glance pattern). Audit Vitals/Data cards for auto-synthesized
   Equatable over whole store states.
4. **Tab content stays cheap to build.** Heavy tabs (Data) should read cached
   derived values, not compute on appear. Keep `drawingGroup()` on the heaviest
   static cards (glance done); add to Vitals HR/HRV cards only if they prove heavy.
5. **Theme switch** must not recompute data — once Phase 0 caches outputs, a
   colorScheme change only re-renders styling, not data. Verify the switch is
   instant after Phase 0.
6. **Static gate:** extend `test_handoff_static_checks.py` to forbid `.sorted(`,
   `.reduce(`, `.compactMap(`, `detectedActivity(` inside `var body` / computed
   view properties in the section files (allow them only in stores/`*Store`).

Definition of done for Phase 0: scrolling Today/Vitals/Data and switching tabs +
theme are visibly smooth on the cabled iPhone; no data math runs in any `body`.

---

## Feature 1 — Widgets + Lock Screen (highest "what people want")

WHOOP's widgets are thin; make Atria glanceable everywhere without opening the app.
- **WidgetKit target** (`WhoopWidget` scaffold exists). Share a small snapshot via
  an **App Group** (`group.com.adidshaft.atria`): Recovery %, Strain, live/last HR,
  Steps, battery+charging, last-updated. The app writes the snapshot on each
  meaningful update (reuse the derived store); the widget reads it.
- Families: `.systemSmall` (Recovery ring), `.systemMedium` (Recovery + Strain +
  HR + Steps), **Lock Screen** `.accessoryCircular` (Recovery ring) +
  `.accessoryRectangular` (Recovery/Strain/HR), **StandBy**. Use the same
  `AtriaMetricRing` look (render a lightweight ring in the widget).
- TimelineProvider: refresh on app writes + a modest schedule; never imply live
  realtime (battery). Honest "as of HH:MM".
- Deep-link widget taps to the matching tab.
- No network; all from the App Group snapshot. Keep the widget render trivial.

## Feature 2 — Live workout mode

A real-time during-workout view WHOOP gates behind subscription.
- **Start/Stop a workout** (button on Today + a Shortcut/intent — `AtriaAppIntents`
  exists). On start, mark a live workout window; show a dedicated full-screen-ish
  view: large live HR, **HR zone bar** (reuse the existing zones: rest→max), live
  **strain building toward a target** (existing TRIMP/strain), elapsed time, live
  **active calories** (Keytel, already implemented), avg/peak HR.
- Keep recording in the existing session pipeline; on stop, save as a confirmed
  workout (existing workout-readiness/confirm flow) + HealthKit workout export
  (already gated). Optional auto-detect prompt ("Looks like a workout — start
  tracking?") from the existing activity-candidate signals.
- Haptics on zone changes (existing `AtriaHapticAlertSettings`).
- Make it a togglable Today metric/section so it fits the customization model.

## Feature 3 — Smart insights (actionable, not a passive journal)

WHOOP's Journal is passive logging. Make Atria tell the user what to change.
- Build on the existing **behavior tags + correlation** scaffold. Once enough
  matched days exist, surface plain findings: "Alcohol days: recovery ~12% lower
  (8 days)", "You recover best on ~7.5h sleep", "High-strain days → next-day HRV
  down ~X". Compute in the derived store (Phase 0), not in `body`.
- Confidence-gated: only show a finding with enough samples; label sample size;
  never medical. Rank by effect size. One-line, visual (up/down chip + magnitude).
- A "this week" summary card (togglable on Today): strain load, sleep consistency,
  recovery trend — from the daily rollups.

## Feature 4 — Advanced metrics (per docs/18, research-honest)

Execute docs/18 in its priority order: profile fields → phone steps (shipped) →
calories (shipped) → VO₂ → IMU decode → sleep/wake → skin-temp/SpO₂ probes. Keep
every metric in its tier (ship / baseline-only / research-gated / do-not-ship) and
gate on the detected model. All new metrics flow through the Phase 0 derived store.

---

## Cross-cutting
- **Liquid Glass** on floating controls only (status chip, toolbar, tab bar,
  buttons, segmented control, sheets/modals are fine); calm opaque surfaces for
  scrolling content. Never put `.glassEffect`/blur on list cells.
- **Light + dark** both legible (light-mode border fix shipped; keep auditing new
  views — no `Color.white` borders/text on light).
- Verify each phase on the cabled iPhone (`devicectl … capture screenshot`); keep
  the static suite green; commit small.

## Suggested sequence for the overnight run
Phase 0 → Feature 1 (Widgets) → Feature 2 (Live workout) → Feature 3 (Insights) →
Feature 4 (continue docs/18). Stop and log status in this doc after each, like
docs/18's status block.
