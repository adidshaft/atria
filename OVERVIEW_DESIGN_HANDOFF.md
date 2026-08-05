# Overview-side design hand-off (for the parallel session)

Read-only audit of the three files owned by the parallel session, scoped to the
design language established on the UI branch this session:

- `.contentTransition(.numericText())` on live/changing numbers, **reduceMotion-guarded**
- plain-text `AtriaTextSelector` instead of congested `.segmented` `Picker`s
- fewer nested boxes / more width; `AtriaDesignTokens` Spacing & Radius
- the "always-a-graph, only the **line** carries range color" idiom
- strict honesty (never fabricate; `--` / "learning"; lines break at day gaps)

`AtriaTextSelector` init (already shipped, `AtriaSharedUIComponents.swift:977`):
`AtriaTextSelector(items: [Item], title: { … }, selection: $binding)` — `Item: Hashable`.
The established rolling-digit form: add `@Environment(\.accessibilityReduceMotion) private var reduceMotion`
to the struct, then `.contentTransition(reduceMotion ? .identity : .numericText())`
+ `.animation(reduceMotion ? nil : .snappy(…), value: <the value>)`.

> `AtriaSharedChrome.swift` audited **already strong** — no changes recommended.

---

## AtriaHomeView.swift

| # | Pri | Effort | Change |
|---|-----|--------|--------|
| H1 | **High** | S | **Live-workout pill rolls its digits.** `AtriaLiveWorkoutTabAccessory` (struct ~8018): the elapsed MM:SS (~8036), live HR (~8044), and `%.1f strain` (~8052) all use `.monospacedDigit()` but hard-cut. Add `reduceMotion` + `.contentTransition(.numericText())` + guarded `.animation(value:)` to each — `value: context.date` / `pulseStore.state.heartRate` / `strain`. Mirror the StandBy hero HR at 8099–8105. **Highest-visibility omission** (on-screen the whole workout). |
| H2 | **High** | S | **StandBy metric column rolls.** `AtriaStandByMetric` (~8161): value `Text` (~8172) hard-cuts while the sibling hero HR in the same overlay rolls. Add `reduceMotion` + numericText + `.animation(value: value)`. |
| H3 | Med | S | **Detection-banner evidence numbers roll.** `AtriaWorkoutDetectionBanner` (~5863): the evidence bar fill animates but its readout (`valueText`, strain `%.1f`, ~5959) hard-cuts — bar and number disagree in motion. Add numericText keyed on `prompt.heartRate` / `prompt.strain`. |
| H4 | Med | M | **Snap drifted corner-radius literals to `AtriaDesignTokens.Radius`.** Inset panels drift across 13/14/15/16/17 (≈ 5950, 6166, 6306, 6371, 6554, 6589, 6628, 6784, 7182, 7295, 7324, 7416, 7478, 7505, 7689, 7719, 8187…). Sweep 14–17 → `.inset` (18), 12–13 chips → `.chip` (12); where an inset sits inside an `.atriaCard`, prefer `Radius.concentric(parent:inset:)`. Leave capsules + the already-tokenized 12169. Eyeball once (a few nudge 2–4pt — that's the token system's intent). |
| — | Low | — | **Battery-% status chip** (`AtriaTopStatusChip`, ~11901): label alternates numeric ("80%") and non-numeric ("Searching"), so a blanket numericText would interpolate wrongly. Safe default: **leave as-is** (only a scoped percentage-branch split would be correct, low payoff). |

## AtriaOverviewSections.swift

| # | Pri | Effort | Change |
|---|-----|--------|--------|
| O1 | **High** | S | **Metric-detail range `Picker(.segmented)` → `AtriaTextSelector`** (`AtriaMetricDetailSheet.chartSlot`, ~9590). The range switch shown above **every** metric chart — the last prominent segmented control on the primary surface. `AtriaTextSelector(items: metric == .fitnessAge ? [.week,.month] : AtriaTrendRange.primarySegments, title: { $0.menuLabel }, selection: $range)`. Keep `menuLabel` (Day/Week/Month). Mirrors `AtriaTrendChart.swift:114`. |
| O2 | **High** | S | **Tri-ring live HR rolls.** `AtriaTriRingLiveStatusStrip` (`View, Equatable`): `Text(pulse.heartRateText)` (~4941) hard-snaps ~1 Hz. Add `reduceMotion` (precedent: `AtriaGlanceMetricCard:6179` is also `View, Equatable` and carries it fine) + guarded numericText keyed on `pulse.heartRateText`. Optional: battery `Text` (~4982). |
| O3 | **High** | S | **Chart Options sheet Pickers → `AtriaTextSelector`** (`AtriaChartOptionsSheet`). Window is a **6-segment** `.segmented` (~15828) — the textbook congestion case → `title: { $0.segmentedLabel }` (short W/M/3M/6M/1Y/All). Bucket (~15841) labels truncate → `title: { $0.label }`. Both enums are Hashable/CaseIterable; draft/Apply flow untouched. |
| O4 | **High** | S | **Sleep-plan Pickers → `AtriaTextSelector`** (`AtriaSleepPlanCard`). Wake-mode (~13496, 3 long titles) + sleep-goal (~13445). Wrap the `@AtriaDefault(String)` values in a get/set `Binding` exactly as the current sleep-goal Picker already does (13446); keep the `.onChange` that reschedules the alarm. |
| O5 | **High** | S | **Strap-steps sheet live count rolls.** `AtriaStrapStepsDetailSheet` (~6067): 30pt step total inside a 15s `TimelineView` hard-cuts. Add `reduceMotion` + numericText keyed on `presentation.valueText`. |
| O6 | **High** | S | **Report-period Week/Month `Picker(.segmented)` → `AtriaTextSelector`** (`AtriaOverviewReadinessSection`, ~2994). Two-item swap; `AtriaReportPeriod` already Hashable. After this, **no stock segmented control remains on Overview.** |
| O7 | Med | S | **Strain-band gauge value rolls.** `AtriaStrainBandGauge` center readout (~13620, `%.1f`). Add `reduceMotion` + numericText keyed on `strain` (Double). NB: defined here but rendered from `AtriaVitalsCollectionSections.swift:5304`. |
| O8 | Med | M | **Let the metric-detail chart LINE carry the range color.** `AtriaPreparedMetricChart` (~10793): the `LineMark` is a flat `tint` while the `PointMark`s already grade per value (`point.tint`) — the house idiom inverted. Give the `LineMark` a value-domain gradient from the same value→color map. **Keep `points.contiguousDayRuns()` so the line still breaks at day gaps** (do not merge runs). Value-graded metrics only; stress has no daily chart. |
| O9 | Low | M | **De-nest the Sleep-plan card** (~13418): `.atriaInsetCard` → two inner filled sub-boxes (13459/13536) = triple nest. Either drop the inner `.background` fills (divide with spacing) or drop the outer inset. Judgment call — the two boxes do group distinct controls. |

---

### Suggested order
Do the **six S/High** items first (H1, H2, O1–O6) — all follow shipped patterns and
build-verify; the selectors are sim-verifiable. Then the Med items (H3, H4, O7, O8).
O9 and the battery chip are judgment calls, safe to defer.

### Verification
Rolling-digit changes are animations → **build-verification** is the right bar
(they don't show in a static screenshot). Selector swaps **are** sim-verifiable —
screenshot the metric-detail sheet / chart-options sheet after. The O8 line-gradient
is sim-verifiable on any metric with history.
