# Codex Combined Handoff — remaining work (single entry point)

Date: 2026-06-25
This is the master to-do. Detail lives in **docs/18** (advanced metrics, honest
tiers) and **docs/19** (perf foundation + flagship features). Read the
"OVERNIGHT OPERATING PRINCIPLES" in docs/18 first — they govern everything.

Non-negotiables on every change: **no lag** (no heavy compute in `body`; no
`.glassEffect`/blur on scrolling cells), **local-first** (no cloud/account/network;
keep `test_handoff_static_checks.py` green, no `https://`), **honest metrics** (tiers
in docs/18; never fabricate from HR/HRV), **light + dark both legible**, and
**Liquid Glass on floating controls only**. Build → static-green → install on the
cabled iPhone (`devicectl … capture screenshot`) → commit small.

## Done already (don't redo — verify)
- **Live Workout mode** — `AtriaLiveWorkoutView` (zones, strain, calories, elapsed,
  zone bar), started from the figure.run toolbar button. ✅ shipped.
- **Today customization** — `AtriaTodayMetric` + Settings → Today screen. ✅
- **Phase 0 started** — `SessionStore.restingTrend14` cached in `sessions.didSet`;
  glance reads it O(1). The pattern to extend. ✅
- **Perf passes** — glance `==`, `drawingGroup` on the glance, dark-mode overdraw
  layer removed, deferred tab-switch reconfig. ✅
- **Genuine Liquid Glass** — status chip (`.glassEffect`), Today segmented control,
  all buttons (`.glass`/`.glassProminent`/`atriaGlassSelectable`). ✅
- **Fixes** — stuck-"Connecting" self-heal (promote on live HR), charging inference
  (gradual rise), **light-mode borders** (white→black separators). ✅
- **Steps/Calories/VO₂/model gates/HealthKit scaffolds** — per docs/18 status block. ✅

## Remaining grunt work (in priority order)

### A. Finish Phase 0 — perf foundation (docs/19 §Phase 0)
The lag root is heavy compute in view bodies. Extend the `restingTrend14` pattern:
1. Build a full **`DerivedMetricsStore`** (or grow `SessionStore`'s cached set):
   daily rollups, evidence summary, 7/30/90-day trend summaries, IMU/probe
   aggregates — all recomputed only on `store.$sessions` change (debounce ~250ms,
   background queue, publish on main).
2. Move remaining `.sorted/.reduce/.compactMap/detectedActivity` OUT of view bodies
   and computed view properties into that store. Known offenders: the Journal
   correlations sort, the Vitals/Data IMU+probe reduces, any `make*()` in `body`.
3. Add a **static gate** to `test_handoff_static_checks.py`: forbid
   `.sorted(`/`.reduce(`/`.compactMap(`/`detectedActivity(` inside `var body` and
   computed `some View` properties in the section files (allow in `*Store`).
4. Ensure BLE→metric math runs off the main actor; extend `throttledCoreLiveChanges`.
5. DoD: scroll Today/Vitals/Data + tab-switch + theme-switch are visibly smooth on
   device; no data math in any `body`.

### B. Widgets + Lock Screen (docs/19 §Feature 1)
WidgetKit target (`WhoopWidget` scaffold exists) + **App Group**
`group.com.adidshaft.atria`. App writes a small snapshot (Recovery, Strain, HR,
Steps, battery+charging, updatedAt) from the derived store; widget reads it.
Families: systemSmall/medium, accessoryCircular/Rectangular (Lock Screen), StandBy.
Reuse the `AtriaMetricRing` look. Deep-link taps to the matching tab. No network.

### C. Live Workout — round it out (build on the shipped HUD)
- On **End workout**, save the window as a **confirmed workout** (reuse the existing
  workout-readiness/confirm flow) + HealthKit workout + active-energy export
  (already gated). Persist per-zone time + avg/peak HR + total strain/calories.
- Optional **auto-detect prompt** ("Looks like a workout — track it?") from the
  existing activity-candidate signals.
- Haptics on zone change (`AtriaHapticAlertSettings`). Make it a togglable Today
  entry so it fits customization.

### D. Smart Insights (docs/19 §Feature 3)
From the existing behavior-tags + correlation scaffold, compute (in the derived
store) effect-size-ranked, confidence-gated findings: "Alcohol days: recovery ~12%
lower (n=8)", "Best recovery ~7.5h sleep". One-line, visual (up/down chip +
magnitude), never medical. Plus a togglable "this week" summary card.

### E. Advanced metrics (docs/18, in its order)
VO₂ polish → IMU decode (gravity-validated) → strap steps (vs CMPedometer) →
sleep/wake → skin-temp & SpO₂ probes (4.0 sensors exist; research-gated, sleep-only,
no absolute units without a reference). All flow through the derived store. Keep
each in its tier; gate on detected model; never write SpO₂/BP/ECG to HealthKit.

### F. Polish sweep
- Audit any new view for light-mode `Color.white` borders/text (use black
  separators in light; the design tokens already adapt).
- Glass only on floating controls; sheets/modals may use `.glassEffect`. Never on
  list cells.
- Keep text non-clipping (`lineLimit` + `minimumScaleFactor`).

## Suggested overnight sequence
A (perf) → B (widgets) → C (workout save) → D (insights) → E (metrics) → F (polish).
Log a status block at the end of each, like docs/18.
