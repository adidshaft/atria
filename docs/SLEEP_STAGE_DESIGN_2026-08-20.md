# Implementation Design — Sleep-Stage Detection Strengthening + WHOOP-Style Sleep Detail UI

All paths under `/Users/amanpandey/projects/atria/Atria/Atria/` unless noted. Line refs from the maps (2026-08-20). Test scheme is **AtriaTests**; all new fixtures use post-2026-08-06 time bases.

---

## TRACK 1 — Strengthen sleep-stage detection

### 1.0 Governing invariants (what must NOT change, stated once)

- `motionBacked || allowHROnlyEstimate` gate at AtriaSleepWakeResearch.swift:304 and the opt-in-false default (deadline lanes budget the cheap `[]` return, :298-304). Never flip the default; never add a third escape.
- Duration-credit fence: `effectiveSleepDuration` skips `allHREstimateProvenance` sets (Sessions.swift:3385-3399). All new estimate tiers must route through `allHREstimateProvenance` so the fence extends automatically.
- No interpolation, ever: zero-HR epochs stay unscored (:448-451), conflicting motion projections withhold the epoch (:707-711). RR gets the identical rule — an epoch without local RR beats has no RR features, and RR is never borrowed across epochs.
- 90s unified gap tolerance (:135, :146, comment :137-145). Any RR gap/coverage concept reuses 90s; no divergent tolerance.
- `AtriaSleepStageIntegrity.validates` (Sessions.swift:3689-3733), `reconcilesForPresentation` (:3804-3812), quorum `max(8, epochCount/3)` (:360), timeline 0.85/90s (:573-600), `heartRateEvidenceIsDense` thresholds (:602-632), duration≥20min && restingHR>0 (:269-270) — all untouched.
- The 0.60 RR/HR coverage floors (Sessions.swift:5083, 45206-45207, 45236-45237, 38538-38541, 46098, 46134) and `isStrongAutoConfirmableSleepCandidate` (:38524-38560) untouched — the new 0.90 tier layers **above** 0.60, is display-confidence only, and never grants auto-confirm or validated authority.
- HealthKit stage export stays dormant: never mint source `"validated_sleep_stages"` (HealthKitExporter.swift:2280-2293, pinned by AtriaSleepStageIntegrityTests:377-391).
- Source-scan pins: do not rename/reorder `backfillConfirmedSleepStagesFromSessions`, `refreshedUserAdjustedSleepEvidenceIfNeeded`, `confirmSleepWindow` regions in Sessions.swift (pins at AtriaSleepStageIntegrityTests:105-171).
- `FallbackStageDiagnostics` sampleVisits accounting (AtriaSleepWakeResearch.swift:114-129) — the RR loop gets its **own** counter field; existing counters' semantics unchanged (AtriaSleepStageFallbackPerformanceTests pin).
- Taxonomy: `SleepStageKind` stays awake/light/rem/sws/deep with sws→deep display fold (Sessions.swift:3233). No N1/N2 — "light" already complies with the brief.
- Provenance lives only in segment id prefixes (Sessions.swift:53809-53817). New tiers = new prefixes, never record-level flags.

### 1.1 True RR tachogram features (currently unimplemented — classifier is 1Hz HR + motion only)

**Data already exists**: `SavedSession.rrPoints` (Sessions.swift:1294, `RRPoint` :1390-1404), live 2A37 + beat-exact drained V24 via `AtriaRecoveredRRProjection` (AtriaRecoveredRRProjection.swift:54-149). It is simply never fed to the engine.

**Functions to modify:**

1. `SessionStore.sleepStageResearchSegmentsCore` — Sessions.swift:40115-40190. Beside the HR flatten at :40136-40149, gather `rrSamples` from in-window sessions **filtered by `hasQualifiedRRProvenance`** (Sessions.swift:1426-1432; deadline twin :1434-1449 in checked callers). 2A37 and verifiedWhoop4HistoricalV24 only; V24 never promoted (Sessions.swift:1423-1425). ms clamp 300–2000 (same bound as `confirmedSleepRespiratoryRateCore` :39846). Also compute `qualifiedRRCoverageFraction` for the window here (same samples-per-second convention as Sessions.swift:45156-45174) and pass it down.
2. `AtriaSleepWakeResearch` — new `RRSample { t: Date, ms: Double }` beside `HeartSample` (:109). Extend both public entries `stageSegments(...)` (:212-229, :234-254) and `stageSegmentsCore` (:256) with `rrSamples: [RRSample] = []` and `qualifiedRRCoverageFraction: Double = 0` **defaulted**, so all existing callers (the 4 estimate lanes at Sessions.swift:39123, 39443, 41704, 41913 and every hot lane) compile and behave identically until deliberately wired.
3. `epochFeatures()` (:372) / `EpochFeature` (:149-161) — add optional RR fields: `rrMedianMs`, `rrRMSSDLocal` (successive differences within epoch), `rrShortSmooth`/`rrLongSmooth` (reuse the Gaussian machinery :461-470, same 120s/600s sigmas), `rrDoG`, and `rrEpochValid: Bool`. `rrEpochValid` requires ≥15 qualified beats inside the exact 30s epoch (≈0.5 in-epoch coverage) — below that, RR fields are nil and HR-only rules apply for that epoch. This is the per-epoch-validity rule extended to RR.
4. `stage(feature:restingHR:isNap:)` (:504-529) — RR branches gated on `rrEpochValid`, refinement-only (Phase 3, after Phase 1/2 land inert):
   - **REM (strengthen — HR-only REM is the strongest call per brief)**: keep the existing band (:523-525); when RR valid, additionally admit REM at the band edges when `rrRMSSDLocal` is elevated relative to the night's median RMSSD (REM autonomic variability signature), i.e. RR can widen REM recall slightly, never override the awake rules.
   - **Deep (hedge — least reliable HR-only)**: on the estimate lane (`motionMeasurementValidated == false`), tighten :526 (e.g. var ≤3.0, DoG ≤1.0) and additionally require `rrRMSSDLocal` below night median when RR is valid. Failed deep calls fall to light. **This is reconcile-neutral by construction**: deep→light shifts stay inside non-awake, so `reconcilesForPresentation` totals are unchanged; only awake-calling affects reconcile, and awake rules are untouched.
5. `merge()` (:871-920) — unchanged logic; prefix minting per 1.2.

**Pure-logic test strategy** (new file `AtriaTests/AtriaSleepStageRRFeatureTests.swift`):
- **Parity pin first (Phase 0)**: for a fixed synthetic night, `stageSegmentsCore(rrSamples: [])` output is element-identical to today's output. This test is the regression fence for the whole track.
- RR features computed only for epochs with ≥15 local beats; sparse-RR epoch → nil RR fields, HR rule applies (no borrowing).
- Unqualified provenance excluded: mixed-source rrPoints through the gather produce features from qualified beats only (test the pure core, not multi-save store state).
- Deep-hedge: synthetic HR-only night where current engine emits deep → new engine emits light for the hedged epochs; awake seconds identical; `reconcilesForPresentation` still passes.
- REM refinement recall case + a guard test that RR never converts an awake-rule epoch to REM.
- Diagnostics: existing sampleVisits values unchanged for rr-empty input; new rrVisits counter monotonic.

### 1.2 The ≥0.90 RR-coverage confidence tier (does not exist today; 0.60 is the only bar)

Per the constraint, a tier is an **id prefix**, not a flag.

- New prefix on `SleepStageSegment` (Sessions.swift:3270-3300): `hrEstimateStrongRRIDPrefix = "research-hr-estimate-rr90-v1-"` beside `hrEstimateIDPrefix` (:3291). Minted in `merge()`/`stageSegmentsCore` when lane == estimate **and** window `qualifiedRRCoverageFraction ≥ 0.90`. The motion lane keeps `"research-motion-v2-"` unchanged — no bump, so `hasTimeAlignedResearchStageReceipt` (Sessions.swift:53770-53774) is untouched.
- `allHREstimateProvenance` (:3296-3299) becomes prefix-set based: true if **all** ids carry either estimate prefix; mixed rr90+v1 sets and mixed estimate+motion sets keep failing toward stricter handling. This single choke point automatically extends: the duration-credit fence (:3393-3398), the backfill hygiene that must not strip estimate segments (Sessions.swift:41872-41889), and the Night downgrade gates (:53787-53817).
- New helper `allStrongRREstimateProvenance(_:)` (true only if all ids are rr90) for UI.
- `SleepHistorySnapshot.Night.init` (:53709): derive `estimateConfidenceTier` (`.strongRR` / `.standard`) from segment prefixes near the existing evidence derivation (:53787-53817) — no stored flag. `reconciledHROnlyDisplaySegments` (:53948-54056) must preserve the incoming prefix when republishing folded display segments (audit its id handling; folded segments must not silently re-mint plain-v1 ids for an rr90 night).
- Tier bands: ≥0.90 → "strong" caption; 0.60–0.90 → extra-hedged caption; <0.60 → no staged timeline (unchanged), but the UI adds the brief's coarse sleep/wake-totals + "why tonight is an estimate" line (Track 2, Phase 8). Engine admission is not relaxed.

**Tests**: rr90 minted iff coverage ≥0.90 (boundary at exactly 0.90 inclusive, matching the ≥0.60 grammar); `allHREstimateProvenance` true for pure rr90; `effectiveSleepDuration` skips rr90 sets; mixed rr90+v1 → `allStrongRREstimateProvenance` false; backfill hygiene retains rr90 segments; Night derives `.strongRR` and `stageDisplayLabel` still returns the estimate label (label mandatory regardless of tier).

### 1.3 Per-epoch validity / unscored gaps

Already implemented for HR and motion (:448-451, :487, :751; gaps left unscored, no interpolation). Work here is **preservation plus extension**: RR validity per 1.1, and a new test that a night with a mid-window 10-minute HR hole yields absent segments over the hole and integrity's 90s-gap rule behaves exactly as the behavioral pins say (AtriaSleepStageIntegrityTests :236-245). No engine change.

### 1.4 Stage-specific confidence surfacing (REM strong / deep hedged)

Engine side is 1.1's deep hedge. Presentation side: extend `AtriaSleepStageEstimateLabel` (Sessions.swift:3265-3268) with tier-aware caption plus per-stage hedge copy consumed by Track 2 rows — e.g. Deep row caption on estimate nights: "Hardest to detect from HR alone"; REM row: none. **Do not** edit strings pinned by AtriaSleepDetailLegibilityTests:49-62 (`unavailableStagesDetail`); new copy gets new strings + new pins.

---

## TRACK 2 — WHOOP-style sleep detail UI

### 2.0 Data + honesty rules for every new surface

- Consume only `night.displayStageSegments`, `night.stageEvidence`, `night.stageDuration(_:)` (Sessions.swift:53819-53841, 54183-54189) — never raw `stageSegments`.
- `isEstimatedStageDisplay` (:53879) ⇒ `AtriaSleepStageEstimateLabel.title` visibly co-rendered with any stage-derived pixels (rows, strips, colored trace). Evidence `.none` ⇒ honest building state (`AtriaSleepStageBuildingSummary` precedent, AtriaVitalsCollectionSections.swift:6760-6811), never blank.
- Percent authority: `AtriaSleepStagePresentation.shares` (AtriaManualSleepSheet.swift:14-42) via `AtriaSleepHypnogramPresentation.legend` (AtriaSleepHypnogram.swift:76-89). This **replaces** the review sheet's fraction-of-span basis (AtriaActivityMonitor.swift:5247, 5262) — decision made explicitly per the convergence constraint. Displayed percents will rise slightly on gap-y nights (unscored time no longer dilutes); durations are real minutes, never re-derived from percent.
- Drawing grammar: `AtriaSleepStageTimelineChart` (AtriaSleepHypnogram.swift:656-867) remains the only multi-lane hypnogram. The per-stage occurrence strip is a single-lane legend affordance rendered from the **same pure math** (`spans(for:)` :56-71), not a second grammar. HR-trace coloring extends `AtriaSleepStressCard`, not the timeline chart.
- Colors: consolidate on the design palette `AtriaSleepHypnogramCard.color(for:)` (#FFB340/#64D2FF/#4C8DFF/#7B6CF0, AtriaSleepHypnogram.swift:392-399), hoisted to a shared `AtriaSleepStagePalette` token. Migrate `AtriaSleepStageSummary.color` (AtriaVitalsCollectionSections.swift:6729-6737 — the known Vitals chip/plot mismatch). **Leave `AtriaSleepStageGlyph` and AtriaManualSleepSheet.swift alone** — source-scanned by AtriaSleepStageIntegrityTests:313-342.
- Containers: `atriaInsetCard(tint: Metrics.electricSleep)`, `AtriaDesignTokens` Spacing/Radius only.

### 2.1 Component inventory

**NEW**
- `AtriaSleepStageRowStrip` (new file `AtriaSleepStageRows.swift`): for each stage in `displayOrder [awake, light, rem, deep]` — color dot, name, largest-remainder %, real duration, and a 1-lane occurrence strip of capsules at `spans(for: stage)` fractions with clock-edge context; per-stage hedge caption slot (estimate nights: deep hedged); optional typical-range sub-strip (2.3). Inputs: `[SleepStageSegment]`, window start/end, `isEstimated`, tier.
- `AtriaStageTypicalRange` (pure, in AtriaSleepBudget.swift beside `AtriaOvernightTypical` :151-169): per display stage, mean±1SD of per-night `stageDuration(stage)` over `nights.suffix(30)` filtered `.confirmed && !isNapEvidence && hasValidatedMotionEvidence` (Sessions.swift:53856-53861). **HR-only estimate nights never seed the baseline.** Hidden below `minimumQualifiedNights = 14` (copies AtriaSleepBudget.swift:153). ±1SD chosen to match the sleep-surface precedent (restingBand) over the vitals ±1.5SD grammar; document at the definition. Does not touch frozen sleep-need receipts (Sessions.swift:54990-54995).
- `AtriaSleepStagePalette` shared color token (hoist of :392-399).

**EXTENDED**
- `AtriaSleepActivityReviewSheet.stageBreakdown` (AtriaActivityMonitor.swift:5238-5275) → replaced by `AtriaSleepStageRowStrip`; `stageRows` (:5113-5121) switches to `legend()`/shares basis.
- `AtriaSleepStressCard` (AtriaHealthScreen.swift:2730+) → optional `stageRuns: [AtriaSleepHypnogramPresentation.Run]` input; each 5-minute bucket colored by the run containing its Date (pure `stageAtDate` join — Runs carry wall-clock :144-157, buckets carry real Dates :2617-2633). Buckets outside any run render neutral (unscored gap); missing buckets stay gaps (:2614-2616); no bridging (:2535-2539). Legend gains "· Estimated stages" when estimated.
- `AtriaMetricDetailSheet` case .sleep (AtriaOverviewSections.swift:9504-9546) → mount `AtriaSleepStageRowStrip` after the hypnogram card (:9512-9513), before `AtriaSleepPlanCard` (:9514). Do not touch the pinned `sleepDisturbanceDirection` region (AtriaSleepStageIntegrityTests:362-375).
- `AtriaSleepStageSummary` (AtriaVitalsCollectionSections.swift:6571-6757) → palette fix only (chips 6626-6650 recolor via shared token).
- `AtriaSleepStageEstimateLabel` → tier captions; plus the sub-0.60 coarse fallback: extend `AtriaSleepHypnogramCard`'s existing generic estimated-asleep capsule state (:507-545) with sleep/wake totals + a "why tonight is an estimate" line (new copy, new pins).

**Insertion points**: review sheet AtriaActivityMonitor.swift:5238 (rows), :5195-5197 (stage runs → stress card; typical band already computed at :1609-1613); detail sheet AtriaOverviewSections.swift:9513/9514; Vitals AtriaHealthScreen.swift:1122-1130 (palette + optional compact rows); History day sheet (AtriaHistorySection.swift:1403) unchanged this pass.

### 2.2 Test strategy

New files (never edit pinned ones): `AtriaStageTypicalRangeTests` (14-night gate; estimate-night exclusion; mean±SD math; empty-history nil), `AtriaSleepStageRowStripTests` (row percents == shares, sum 100; occurrence spans == spans(for:) filtered; awake row present per displayOrder), `AtriaSleepStressStageColorTests` (pure stageAtDate join: bucket inside run → stage, in gap → nil; no bridging), honesty tests in the AtriaSleepEstimateReconcileTests style (estimate night ⇒ label rendered with rows/trace; .none ⇒ building state). Respect: shared process/defaults (no multi-save integration tests), AtriaSleepHypnogramPresentationTests semantics (lane order, wall-clock spans, real-minute legends, SWS→deep fold at run level) are consumed, not modified.

---

## Phased order of work (each phase builds green on scheme AtriaTests before the next)

1. **P0 — parity fence**: add defaulted `rrSamples`/coverage params through stageSegments/stageSegmentsCore + the element-identical regression test. Zero behavior change.
2. **P1 — RR plumbing**: qualified-RR gather in `sleepStageResearchSegmentsCore`, `EpochFeature` RR fields + per-epoch RR validity, rrVisits counter. Features computed, unused. Tests from 1.1.
3. **P2 — rr90 tier**: new prefix, prefix-set `allHREstimateProvenance`, Night tier derivation, tier captions. Duration-fence + hygiene + mixed-set tests.
4. **P3 — decision refinements**: deep hedge (estimate lane) + RR-assisted REM/deep rules; reconcile-neutrality tests; fixture nights compared before/after.
5. **P4 — UI ground-truthing**: percent-basis unification in the review sheet + palette consolidation (small, visually verifiable via `--atria-ui-fixture sleep-detail`).
6. **P5 — `AtriaSleepStageRowStrip`** with occurrence strips + hedge captions; mount review sheet, then detail sheet.
7. **P6 — stage-colored HR trace** in `AtriaSleepStressCard` (review sheet first, where hypnogram + trace already co-locate).
8. **P7 — `AtriaStageTypicalRange`** + typical strips under rows (validated-nights-only baseline, 14-night gate).
9. **P8 — sub-0.60 coarse fallback** + "why tonight is an estimate" copy, with new legibility pins.

Key files: AtriaSleepWakeResearch.swift, Sessions.swift (:40115, :3270-3299, :53709+), AtriaSleepHypnogram.swift, AtriaActivityMonitor.swift (:5084-5306), AtriaHealthScreen.swift (:2469-2740), AtriaOverviewSections.swift (:9504-9546), AtriaVitalsCollectionSections.swift (:6571-6757), AtriaSleepBudget.swift (:151-169), new AtriaSleepStageRows.swift.
